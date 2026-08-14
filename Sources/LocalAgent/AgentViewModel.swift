import Foundation
import Observation
import AppKit

@MainActor @Observable
final class AgentViewModel {
    var store = ThreadStore()
    var llama = LlamaService()
    var permissions = PermissionStore()
    var input = ""
    var errorMessage: String?
    var pendingCall: PendingToolCall?
    var attachments: [MessageAttachment] = []
    var liveMetrics = GenerationMetrics()
    var activeChangeStats: [FileChangeStat] = []
    var activities: [AgentActivity] = []
    var inlineActivity: AgentActivity?
    var resources = ResourceMonitor()
    var plugins = PluginStore()
    private var activeChanges: [String] = []

    init() {
        llama.discoverModels()
        resources.start { [weak llama] in llama?.processID }
    }

    func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !attachments.isEmpty), !llama.isGenerating, !llama.isStarting else { return }
        let sentAttachments = attachments
        activeChanges = []
        activeChangeStats = []
        setActivity("요청 분석 중", symbol: "brain.head.profile", active: true)
        input = ""
        attachments = []
        store.append(ChatMessage(
            role: .user,
            content: prompt.isEmpty ? "첨부 파일을 분석해줘." : prompt,
            attachments: sentAttachments
        ))
        if !llama.isRunning {
            setActivity("모델 로드 중", detail: llama.selectedModel?.displayName, symbol: "cpu", active: true)
            await startModel()
            guard llama.isRunning else { return }
        }
        await generate()
    }

    func generate() async {
        guard llama.isRunning, let messages = store.selected?.messages else {
            errorMessage = "먼저 모델을 시작하세요."
            return
        }
        llama.isGenerating = true
        setActivity("모델이 응답을 생성 중", detail: llama.selectedModel?.displayName, symbol: "sparkles", active: true)
        liveMetrics = GenerationMetrics()
        let startedAt = ContinuousClock.now
        var answerStarted = false
        var issuedToolCall = false
        var stepProgress = ""
        store.append(ChatMessage(role: .assistant, content: ""))
        var automaticCall: PendingToolCall?
        do {
            for try await event in llama.stream(messages: messages, workspacePath: store.selectedWorkspacePath,
                                                pluginInstructions: plugins.enabledInstructions) {
                switch event {
                case .text(let text):
                    stepProgress += text
                    if !answerStarted {
                        answerStarted = true
                        liveMetrics.thinkingSeconds = startedAt.duration(to: .now).seconds
                    }
                    store.updateLastAssistant(text: text, persist: false)
                    updateEstimatedMetrics(startedAt: startedAt)
                case .reasoning(let text):
                    store.updateLastAssistant(reasoning: text, persist: false)
                    updateEstimatedMetrics(startedAt: startedAt)
                case .usage(let metrics):
                    var finalMetrics = metrics
                    finalMetrics.thinkingSeconds = liveMetrics.thinkingSeconds
                    liveMetrics = finalMetrics
                    store.updateLastAssistant(metrics: finalMetrics)
                case .toolCall(let id, let name, let arguments):
                    issuedToolCall = true
                    let visibleProgress = stepProgress.trimmingCharacters(in: .whitespacesAndNewlines)
                    let call = PendingToolCall(
                        id: id, name: name, arguments: arguments,
                        progress: visibleProgress.isEmpty ? progressFallback(for: name) : String(visibleProgress.prefix(240)),
                        metrics: liveMetrics.completionTokens > 0 ? liveMetrics : nil
                    )
                    setActivity(activityTitle(for: name), detail: FileTools.presentation(for: call).target,
                                symbol: activitySymbol(for: name), active: false)
                    if permissions.allows(call, workspace: store.selectedWorkspacePath) { automaticCall = call }
                    else { pendingCall = call }
                case .completed: break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        llama.isGenerating = false
        store.flush()
        if issuedToolCall { store.discardLastAssistantDraft() }
        else if liveMetrics.completionTokens > 0 { store.updateLastAssistant(metrics: liveMetrics) }
        if let automaticCall {
            do { try await execute(automaticCall) } catch { errorMessage = error.localizedDescription }
        } else if pendingCall == nil {
            if !activeChanges.isEmpty {
                store.updateLastAssistant(changedFiles: activeChanges, changeStats: activeChangeStats)
            }
            await updateTitleIfNeeded()
            setActivity("작업 완료", symbol: "checkmark.circle.fill", active: false)
        }
    }

    func startModel() async {
        do { try await llama.start() } catch { errorMessage = error.localizedDescription }
    }

    func selectModel(_ item: LocalModel) async {
        guard llama.selectedModel != item, !llama.isGenerating else { return }
        let restart = llama.isRunning
        if restart { llama.stop() }
        llama.selectedModel = item
        if restart { await startModel() }
    }

    func approve() async {
        guard let call = pendingCall else { return }
        pendingCall = nil
        do { try await execute(call) } catch { errorMessage = error.localizedDescription }
    }

    func approveAlways() async {
        guard let call = pendingCall else { return }
        permissions.trustFolder(for: call)
        pendingCall = nil
        do { try await execute(call) } catch { errorMessage = error.localizedDescription }
    }

    func reject() {
        guard let call = pendingCall else { return }
        pendingCall = nil
        store.append(ChatMessage(role: .tool, content: "사용자가 \(call.name) 실행을 거절했습니다."))
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "텍스트 또는 코드 파일을 첨부하세요 (파일당 최대 1 MB)"
        guard panel.runModal() == .OK else { return }

        do {
            for url in panel.urls where !attachments.contains(where: { $0.path == url.path }) {
                guard attachments.count < 5 else { throw AgentError.message("첨부 파일은 최대 5개입니다.") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 1_000_000 else { throw AgentError.message("\(url.lastPathComponent)은 1 MB를 넘습니다.") }
                guard let content = String(data: data, encoding: .utf8) else {
                    throw AgentError.message("\(url.lastPathComponent)은 아직 지원하지 않는 바이너리 파일입니다.")
                }
                attachments.append(MessageAttachment(name: url.lastPathComponent, path: url.path, size: data.count, content: content))
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func removeAttachment(_ attachment: MessageAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    private func updateEstimatedMetrics(startedAt: ContinuousClock.Instant) {
        liveMetrics.elapsedSeconds = startedAt.duration(to: .now).seconds
    }

    private func execute(_ call: PendingToolCall) async throws {
        let workspace = store.selectedWorkspacePath
        if let progress = call.progress, !progress.isEmpty {
            store.append(ChatMessage(role: .assistant, content: progress, metrics: call.metrics, isProgress: true))
        }
        setActivity(activityTitle(for: call.name), detail: FileTools.presentation(for: call).target,
                    symbol: activitySymbol(for: call.name), active: true)
        inlineActivity = AgentActivity(title: activityTitle(for: call.name),
                                       detail: FileTools.presentation(for: call).target,
                                       symbol: activitySymbol(for: call.name), isActive: true)
        let changeStat = FileTools.changeStat(for: call, workspace: workspace)
        let result: String
        do { result = try await Task.detached { try FileTools.run(call, workspace: workspace) }.value }
        catch { inlineActivity = nil; throw error }
        try? await Task.sleep(for: .milliseconds(350))
        inlineActivity = nil
        if let changeStat {
            activeChangeStats.removeAll { $0.path == changeStat.path }
            activeChangeStats.append(changeStat)
        }
        if FileTools.requiresApproval(call.name), call.name != "run_command" {
            for path in FileTools.paths(in: call, workspace: workspace) where !activeChanges.contains(path) { activeChanges.append(path) }
        }
        store.append(ChatMessage(role: .tool, content: "[\(call.name)]\n\(result)",
                                 reasoning: call.progress,
                                 toolCallID: call.id, toolName: call.name, toolArguments: call.arguments))
        await generate()
    }

    private func progressFallback(for tool: String) -> String {
        ["read_file": "파일 내용을 확인하고 다음 단계를 결정합니다.",
         "list_files": "폴더 구성을 확인하고 필요한 작업을 정리합니다.",
         "search_files": "관련 파일을 찾아 변경 범위를 좁힙니다.",
         "write_file": "정리한 변경 내용을 파일에 적용합니다.",
         "create_directory": "작업에 필요한 폴더 구조를 준비합니다.",
         "move_file": "파일을 요청한 위치로 정리합니다.",
         "trash_file": "요청한 파일을 복구 가능한 휴지통으로 옮깁니다.",
         "run_command": "변경 결과를 실행해 오류와 누락을 검증합니다.",
         "search_mail": "관련 메일을 찾아 필요한 내용을 확인합니다.",
         "fetch_url": "웹페이지 내용을 확인해 작업에 반영합니다."][tool] ?? "다음 작업에 필요한 정보를 확인합니다."
    }

    private func setActivity(_ title: String, detail: String? = nil, symbol: String, active: Bool) {
        activities.indices.forEach { activities[$0].isActive = false }
        activities.append(AgentActivity(title: title, detail: detail, symbol: symbol, isActive: active))
        if activities.count > 40 { activities.removeFirst(activities.count - 40) }
    }

    private func activityTitle(for tool: String) -> String {
        ["read_file": "파일 읽는 중", "list_files": "폴더 확인 중", "search_files": "파일 검색 중",
         "write_file": "파일 수정 중", "create_directory": "폴더 생성 중", "move_file": "파일 이동 중",
         "trash_file": "휴지통으로 이동 중", "run_command": "명령 실행 중", "search_mail": "메일 검색 중",
         "fetch_url": "웹페이지 확인 중"][tool] ?? "도구 실행 중"
    }

    private func activitySymbol(for tool: String) -> String {
        ["read_file": "doc.text", "list_files": "folder", "search_files": "magnifyingglass",
         "write_file": "square.and.pencil", "create_directory": "folder.badge.plus", "move_file": "arrow.right",
         "trash_file": "trash", "run_command": "terminal", "search_mail": "envelope", "fetch_url": "globe"][tool] ?? "wrench"
    }

    private func updateTitleIfNeeded() async {
        guard let thread = store.selected,
              let firstUser = thread.messages.first(where: { $0.role == .user }),
              thread.title == "새 작업" || thread.title == String(firstUser.content.prefix(28)),
              thread.messages.filter({ $0.role == .user }).count >= 2 else { return }
        do {
            let title = try await llama.title(for: Array(thread.messages.prefix(8)))
            store.setTitle(title, for: thread.id)
        } catch { /* A title is optional; keep the neutral placeholder on failure. */ }
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

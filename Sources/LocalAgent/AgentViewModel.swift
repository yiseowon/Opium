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
    var pendingQuestion: AgentQuestion?
    var attachments: [MessageAttachment] = []
    var liveMetrics = GenerationMetrics()
    var turnMetrics = GenerationMetrics()
    var activeChangeStats: [FileChangeStat] = []
    var activities: [AgentActivity] = []
    var inlineActivity: AgentActivity?
    var resources = ResourceMonitor()
    var plugins = PluginStore()
    var downloader = ModelDownloader()
    private var activeChanges: [String] = []
    private var completedStepMetrics = GenerationMetrics()
    private var queuedPrompt: String?
    private var queuedAttachments: [MessageAttachment] = []
    private var stopRequested = false

    var hasQueuedFollowUp: Bool { queuedPrompt != nil || !queuedAttachments.isEmpty }

    init() {
        llama.discoverModels()
        llama.lowPowerMode = plugins.isEnabled("melatonin-kit")
        resources.start { [weak llama] in llama?.processID }
        llama.onFatalError = { [weak self] message in self?.errorMessage = message }
        downloader.onModelInstalled = { [weak self] in self?.llama.discoverModels() }
    }

    func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        if llama.isGenerating || llama.isStarting {
            queuedPrompt = prompt
            queuedAttachments = attachments
            input = ""
            attachments = []
            return
        }
        let sentAttachments = attachments
        llama.lowPowerMode = plugins.isEnabled("melatonin-kit")
        activeChanges = []
        activeChangeStats = []
        liveMetrics = GenerationMetrics()
        turnMetrics = GenerationMetrics()
        completedStepMetrics = GenerationMetrics()
        stopRequested = false
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
                                                pluginInstructions: plugins.enabledInstructions,
                                                computerUseEnabled: permissions.computerUseEnabled) {
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
                    turnMetrics = completedStepMetrics.adding(finalMetrics)
                    store.updateLastAssistant(metrics: turnMetrics)
                case .toolCallProgress(let name, let arguments):
                    guard name == "write_file",
                          let stat = FileTools.liveChangeStat(arguments: arguments,
                                                             workspace: store.selectedWorkspacePath) else { break }
                    activeChangeStats.removeAll { $0.path == stat.path }
                    activeChangeStats.append(stat)
                case .toolCall(let id, let name, let arguments):
                    issuedToolCall = true
                    let visibleProgress = stepProgress.trimmingCharacters(in: .whitespacesAndNewlines)
                    let call = PendingToolCall(
                        id: id, name: name, arguments: arguments,
                        progress: visibleProgress.isEmpty ? progressFallback(for: name) : String(visibleProgress.prefix(240)),
                        metrics: nil
                    )
                    if name == "ask_user", let question = Self.question(from: call) {
                        pendingQuestion = question
                    } else if permissions.allows(call, workspace: store.selectedWorkspacePath) { automaticCall = call }
                    else { pendingCall = call }
                case .completed: break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        llama.isGenerating = false
        completedStepMetrics = turnMetrics
        store.flush()
        if issuedToolCall { store.discardLastAssistantDraft() }
        else if turnMetrics.completionTokens > 0 { store.updateLastAssistant(metrics: turnMetrics) }
        if stopRequested {
            stopRequested = false
            store.fillEmptyLastAssistant(with: "응답이 중단되었습니다.")
            setActivity("응답 중단됨", symbol: "stop.circle", active: false)
            await sendQueuedFollowUpIfNeeded()
            return
        }
        if let automaticCall {
            do { try await execute(automaticCall) } catch { errorMessage = error.localizedDescription }
        } else if pendingCall == nil && pendingQuestion == nil {
            store.fillEmptyLastAssistant(with: "모델이 답변을 생성하지 못했습니다. 다시 시도해 주세요.")
            if !activeChanges.isEmpty {
                store.updateLastAssistant(changedFiles: activeChanges, changeStats: activeChangeStats)
            }
            await updateTitleIfNeeded()
            setActivity("작업 완료", symbol: "checkmark.circle.fill", active: false)
            await sendQueuedFollowUpIfNeeded()
        }
    }

    func stopGeneration() {
        guard llama.isGenerating || llama.isStarting else { return }
        stopRequested = true
        llama.stopGeneration()
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

    func setPluginEnabled(_ enabled: Bool, for plugin: InstalledPlugin) async {
        plugins.setEnabled(enabled, for: plugin)
        guard plugin.manifest.name == "melatonin-kit" else { return }
        let shouldUseLowPower = plugins.isEnabled("melatonin-kit")
        guard llama.lowPowerMode != shouldUseLowPower else { return }
        llama.lowPowerMode = shouldUseLowPower
        if llama.isRunning && !llama.isGenerating {
            llama.stop()
            await startModel()
        }
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

    func answerQuestion(_ answer: String) async {
        guard let question = pendingQuestion else { return }
        pendingQuestion = nil
        store.append(ChatMessage(role: .tool, content: "사용자 선택: \(answer)",
                                 toolCallID: question.id, toolName: "ask_user",
                                 toolArguments: "{}"))
        await generate()
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
        turnMetrics = completedStepMetrics.adding(liveMetrics)
    }

    private func sendQueuedFollowUpIfNeeded() async {
        guard queuedPrompt != nil || !queuedAttachments.isEmpty else { return }
        let queuedPrompt = queuedPrompt ?? ""
        self.queuedPrompt = nil
        input = queuedPrompt
        attachments = queuedAttachments
        queuedAttachments = []
        await send()
    }

    private func execute(_ call: PendingToolCall) async throws {
        let workspace = store.selectedWorkspacePath
        if let progress = call.progress, !progress.isEmpty {
            store.append(ChatMessage(role: .assistant, content: progress, metrics: call.metrics, isProgress: true))
        }
        let activityID = beginToolActivity(call, workspace: workspace)
        inlineActivity = AgentActivity(title: FileTools.liveTitle(for: call),
                                       detail: FileTools.presentation(for: call).target,
                                       symbol: activitySymbol(for: call.name), isActive: true)
        let changeStat = FileTools.changeStat(for: call, workspace: workspace)
        let result: String
        var resultImage: String?
        do {
            if ComputerUse.toolNames.contains(call.name) {
                let outcome = try await ComputerUse.run(call)
                result = outcome.text
                resultImage = outcome.imageBase64
            } else {
                result = try await Task.detached { try await FileTools.runAsync(call, workspace: workspace) }.value
            }
        } catch {
            // A dangling tool_call with no matching tool response breaks every
            // later request in this thread (the API contract requires one), so the
            // model still needs to see *something* back — even a failure — instead
            // of the turn just dead-ending here.
            inlineActivity = nil
            completeToolActivity(activityID, outcome: "실패: \(error.localizedDescription)")
            store.append(ChatMessage(role: .tool, content: "[\(call.name)] 실패: \(error.localizedDescription)",
                                     reasoning: call.progress, metrics: call.metrics,
                                     toolCallID: call.id, toolName: call.name, toolArguments: call.arguments))
            await generate()
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        inlineActivity = nil
        if let changeStat {
            activeChangeStats.removeAll { $0.path == changeStat.path }
            activeChangeStats.append(changeStat)
        }
        if FileTools.requiresApproval(call.name), call.name != "run_command" {
            for path in FileTools.paths(in: call, workspace: workspace) where !activeChanges.contains(path) { activeChanges.append(path) }
        }
        completeToolActivity(activityID, outcome: result.components(separatedBy: .newlines).first)
        store.append(ChatMessage(role: .tool, content: "[\(call.name)]\n\(result)",
                                 reasoning: call.progress, metrics: call.metrics,
                                 toolCallID: call.id, toolName: call.name, toolArguments: call.arguments,
                                 imageBase64: resultImage))
        await generate()
    }

    private func beginToolActivity(_ call: PendingToolCall, workspace: String) -> UUID {
        activities.indices.forEach { activities[$0].isActive = false }
        let activity = AgentActivity(title: FileTools.liveTitle(for: call),
                                     detail: FileTools.presentation(for: call).target,
                                     symbol: activitySymbol(for: call.name), isActive: true,
                                     securityLevel: FileTools.securityLevel(for: call, workspace: workspace))
        activities.append(activity)
        if activities.count > 80 { activities.removeFirst(activities.count - 80) }
        return activity.id
    }

    private func completeToolActivity(_ id: UUID, outcome: String?) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].isActive = false
        activities[index].outcome = outcome
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
         "fetch_url": "웹페이지 내용을 확인해 작업에 반영합니다.",
         "web_search": "웹에서 관련 정보를 찾아 확인할 출처를 고릅니다.",
         "list_ui_elements": "화면에 있는 클릭 가능한 요소를 확인합니다.",
         "click_ui_element": "화면의 요소를 클릭해 다음 단계로 진행합니다.",
         "take_screenshot": "현재 화면을 캡처해 상태를 확인합니다.",
         "click_at": "지정한 좌표를 클릭합니다.",
         "type_text": "필요한 텍스트를 입력합니다.",
         "press_key": "키를 눌러 조작을 완료합니다."][tool] ?? "다음 작업에 필요한 정보를 확인합니다."
    }

    private func setActivity(_ title: String, detail: String? = nil, symbol: String, active: Bool) {
        activities.indices.forEach { activities[$0].isActive = false }
        activities.append(AgentActivity(title: title, detail: detail, symbol: symbol, isActive: active))
        if activities.count > 40 { activities.removeFirst(activities.count - 40) }
    }

    private func activitySymbol(for tool: String) -> String {
        ["read_file": "doc.text", "list_files": "folder", "search_files": "magnifyingglass",
         "write_file": "square.and.pencil", "create_directory": "folder.badge.plus", "move_file": "arrow.right",
         "trash_file": "trash", "run_command": "terminal", "search_mail": "envelope", "fetch_url": "globe",
         "web_search": "magnifyingglass.circle", "list_ui_elements": "rectangle.on.rectangle",
         "click_ui_element": "cursorarrow.click", "take_screenshot": "camera.viewfinder",
         "click_at": "cursorarrow.click.2", "type_text": "keyboard", "press_key": "keyboard.badge.ellipsis"][tool] ?? "wrench"
    }

    /// Runs as soon as a thread has one complete exchange. Waiting for a second user
    /// message (as this used to) meant one-shot threads — most of them — kept their
    /// default name forever, leaving the sidebar a wall of identical "새 작업" rows.
    private func updateTitleIfNeeded() async {
        guard let thread = store.selected,
              let firstUser = thread.messages.first(where: { $0.role == .user }),
              WorkKind.isPlaceholderTitle(thread.title)
                  || thread.title == String(firstUser.content.prefix(28)),
              thread.messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty })
        else { return }
        do {
            let title = try await llama.title(for: Array(thread.messages.prefix(8)))
            store.setTitle(title, for: thread.id)
        } catch { /* A title is optional; keep the neutral placeholder on failure. */ }
    }

    private static func question(from call: PendingToolCall) -> AgentQuestion? {
        guard let data = call.arguments.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let question = values["question"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else { return nil }
        let options = (values["options"] ?? "").split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (2...4).contains(options.count) else { return nil }
        return AgentQuestion(id: call.id, question: question, detail: values["detail"], options: options)
    }
}

extension GenerationMetrics {
    func adding(_ other: Self) -> Self {
        Self(promptTokens: promptTokens + other.promptTokens,
             completionTokens: completionTokens + other.completionTokens,
             tokensPerSecond: other.tokensPerSecond,
             elapsedSeconds: elapsedSeconds + other.elapsedSeconds,
             thinkingSeconds: thinkingSeconds ?? other.thinkingSeconds)
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

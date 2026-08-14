import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var service: LlamaService?
    func applicationWillTerminate(_ notification: Notification) { service?.stop() }
}

@main struct LocalAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AgentViewModel()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            do { try SelfTest.run(); exit(EXIT_SUCCESS) }
            catch { fputs("Self-test failed: \(error)\n", stderr); exit(EXIT_FAILURE) }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model).frame(minWidth: 1_140, minHeight: 650)
                .onAppear { appDelegate.service = model.llama }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) { Button("새 작업") { model.store.newThread() }.keyboardShortcut("n") } }
    }
}

struct ContentView: View {
    @Bindable var model: AgentViewModel
    @State private var showingPermissions = false
    @State private var showingPlugins = false
    @State private var sidebarVisible = true
    @State private var inspectorVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar.frame(width: 258)
                Divider()
            }
            VStack(spacing: 0) {
                header
                messages
                if let call = model.pendingCall { approval(call) }
                composer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
            if inspectorVisible {
                Divider()
                ActivityInspector(model: model).frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showingPermissions) {
            PermissionSettingsView(store: model.permissions, usage: model.store.totalUsage,
                                   modelName: model.llama.selectedModel?.name ?? "모델 없음")
        }
        .sheet(isPresented: $showingPlugins) { PluginDirectoryView(store: model.plugins) }
        .alert("오류", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                OpiumMark().stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 19, height: 19).accessibilityHidden(true)
                Text("Opium").font(.title3.weight(.semibold))
                Spacer()
                Button(action: model.store.newThread) { Image(systemName: "square.and.pencil") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
            Button(action: model.store.newThread) {
                Label("새 작업", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .buttonStyle(.plain).background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 10)
            List(selection: $model.store.selectedID) {
                Section("최근 작업") {
                    ForEach(model.store.threads) { Text($0.title).lineLimit(1).tag($0.id) }
                        .onDelete { offsets in model.store.delete(Set(offsets.map { model.store.threads[$0].id })) }
                }
            }
            .font(.system(size: 14))
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            Button { showingPlugins = true } label: {
                HStack {
                    Image(systemName: "puzzlepiece.extension")
                    Text("플러그인")
                    Spacer()
                    Text("\(model.plugins.plugins.filter(\.isEnabled).count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.horizontal, 14).padding(.vertical, 11)
            }.buttonStyle(.plain)
            Divider().opacity(0.5)
            Button { showingPermissions = true } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("권한 및 설정")
                    Spacer()
                    Text(model.permissions.policy.title).font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(14)
            }.buttonStyle(.plain)
        }.background(Color(nsColor: .windowBackgroundColor).opacity(0.68))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain).help(sidebarVisible ? "사이드바 닫기" : "사이드바 열기")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.store.selected?.title ?? "새 작업").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(model.llama.selectedModel?.name ?? "모델을 선택하세요").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.llama.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                Text(model.llama.status).font(.caption)
            }.padding(.horizontal, 10).padding(.vertical, 6).background(.secondary.opacity(0.09), in: Capsule())
            Button { showingPermissions = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { inspectorVisible.toggle() }
            } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.plain).help(inspectorVisible ? "활동 패널 닫기" : "활동 패널 열기")
        }.padding(.horizontal, 24).frame(height: 64).background(.bar)
    }

    private var messages: some View {
        let visibleMessages = ChatMessage.visibleConversation(model.store.selected?.messages ?? [],
                                                              condenseCurrentTurn: !model.llama.isGenerating)
        return ScrollViewReader { proxy in
            ScrollView {
                if model.store.selected?.messages.isEmpty != false {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("무엇을 함께 해볼까요?").font(.title2.weight(.medium))
                        Text("대화하거나, 파일을 첨부하거나, Mac의 작업을 맡겨보세요.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 380)
                } else {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                            if index > 0, message.role == .user {
                                Divider().opacity(0.45).padding(.vertical, 6)
                            }
                            MessageView(message: message).id(message.id)
                        }
                        if model.llama.isStarting {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("모델 로드 중").font(.system(size: 15, weight: .medium))
                                    Text(model.llama.selectedModel?.displayName ?? "로컬 모델")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .transition(.opacity)
                        }
                        if let activity = model.inlineActivity {
                            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Image(systemName: activity.symbol).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(activity.title)  ·  \(context.date.timeIntervalSince(activity.date), format: .number.precision(.fractionLength(1)))초")
                                            .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                                        if let detail = activity.detail, !detail.isEmpty {
                                            Text(detail).font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.llama.isGenerating, model.inlineActivity == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                MetricsView(metrics: model.liveMetrics)
                                if !model.activeChangeStats.isEmpty { ChangeCountView(stats: model.activeChangeStats) }
                            }
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .padding(.vertical, 28)
                    .frame(maxWidth: 1_020)
                    .padding(.horizontal, 36)
                    .frame(maxWidth: .infinity)
                }
            }.onChange(of: model.store.selected?.messages.count) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }.onChange(of: model.store.selected?.messages.last?.content) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }.onChange(of: model.store.selected?.messages.last?.reasoning) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }.onChange(of: model.inlineActivity?.id) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }.frame(maxWidth: .infinity)
    }

    private func approval(_ call: PendingToolCall) -> some View {
        let paths = FileTools.paths(in: call)
        let presentation = FileTools.presentation(for: call)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(presentation.title).font(.headline)
                Text(presentation.target).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text(presentation.impact).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                HStack {
                    Button("거절", role: .cancel, action: model.reject)
                    Spacer()
                    if call.name != "run_command", !paths.isEmpty {
                        Button("이 폴더 항상 허용") { Task { await model.approveAlways() } }
                    }
                    Button("이번만 허용") { Task { await model.approve() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(15).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.22)))
        .frame(maxWidth: 760).padding(.horizontal, 24).padding(.bottom, 8)
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if !model.attachments.isEmpty { attachmentStrip }
            TextField("무엇이든 요청하세요", text: $model.input, axis: .vertical)
                .font(.system(size: 17)).lineLimit(2...12).textFieldStyle(.plain)
                .frame(minHeight: 76, alignment: .topLeading)
                .onSubmit { Task { await model.send() } }
            HStack {
                Menu {
                    Button("파일 첨부", systemImage: "paperclip", action: model.chooseFiles)
                    Button("메일 찾아보기", systemImage: "envelope") { model.input = "Apple Mail에서 다음 메일을 찾아 요약해줘: " }
                    Button("웹사이트 만들기", systemImage: "globe") { model.input = "현재 작업 폴더에 다음 웹사이트를 완성하고 실행까지 확인해줘: " }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).help("도구 및 첨부")
                Button { showingPermissions = true } label: {
                    Label(model.permissions.policy.title, systemImage: "shield.lefthalf.filled")
                        .foregroundStyle(model.permissions.policy == .fullAccess ? .orange : .secondary)
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    ForEach(model.llama.models) { item in
                        Button { Task { await model.selectModel(item) } } label: {
                            if model.llama.selectedModel == item { Label(item.displayName, systemImage: "checkmark") }
                            else { Text(item.displayName) }
                        }
                    }
                    Divider(); Button("모델 다시 찾기", action: model.llama.discoverModels)
                } label: { Text(model.llama.selectedModel?.displayName ?? "모델 선택").lineLimit(1) }
                    .disabled(model.llama.isGenerating)
                Menu {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Button { model.llama.effort = effort } label: {
                            if model.llama.effort == effort { Label(effort.rawValue, systemImage: "checkmark") }
                            else { Text(effort.rawValue) }
                        }
                    }
                } label: { Text(model.llama.effort.rawValue) }
                Button { Task { await model.send() } } label: {
                    if model.llama.isStarting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up").fontWeight(.semibold) }
                }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .disabled((model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty)
                              || model.llama.selectedModel == nil || model.llama.isStarting || model.llama.isGenerating)
            }
        }
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 6).frame(maxWidth: 880).padding(.horizontal, 24).padding(.bottom, 18)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text"); Text(attachment.name).lineLimit(1)
                        Button { model.removeAttachment(attachment) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }.font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }
}

private struct OpiumMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 25, sy = rect.height / 25
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var path = Path()
        path.move(to: point(12.5, 23))
        path.addCurve(to: point(5.5, 3), control1: point(5, 18), control2: point(3, 8))
        path.addCurve(to: point(12.5, 23), control1: point(13, 8), control2: point(14, 17))
        path.move(to: point(12.5, 23))
        path.addCurve(to: point(18, 5), control1: point(13, 16), control2: point(14, 9))
        path.addCurve(to: point(12.5, 23), control1: point(23, 12), control2: point(19, 19))
        path.move(to: point(12.5, 23))
        path.addCurve(to: point(23, 12), control1: point(17, 19), control2: point(21, 15))
        path.addCurve(to: point(12.5, 23), control1: point(23, 19), control2: point(18, 22))
        return path
    }
}

private struct ActivityInspector: View {
    @Bindable var model: AgentViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("보안 활동").font(.headline)
                    Text("모델이 이 Mac에서 수행한 작업").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.llama.isGenerating { ProgressView().controlSize(.small) }
            }.padding(16)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.activities.isEmpty {
                        ContentUnavailableView("활동 없음", systemImage: "waveform.path",
                                               description: Text("모델이 작업을 시작하면 여기에 표시됩니다."))
                            .frame(minHeight: 220)
                    } else {
                        ForEach(model.activities.reversed()) { activity in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: activity.securityLevel == nil ? activity.symbol : "shield.fill")
                                    .foregroundStyle(activity.securityLevel.map(securityColor) ?? (activity.isActive ? Color.accentColor : Color.secondary))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(activity.title).font(.system(size: 15, weight: .medium))
                                        if let level = activity.securityLevel {
                                            Text(level.title).font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(securityColor(level))
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(securityColor(level).opacity(0.12), in: Capsule())
                                        }
                                    }
                                    if let detail = activity.detail, !detail.isEmpty {
                                        Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                                            .lineLimit(2).truncationMode(.middle)
                                    }
                                    if let outcome = activity.outcome, !outcome.isEmpty {
                                        Text(outcome).font(.system(size: 12)).foregroundStyle(.secondary)
                                            .lineLimit(2).truncationMode(.middle)
                                    }
                                    Text(activity.date, style: .time).font(.system(size: 12)).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                if activity.isActive { Circle().fill(.green).frame(width: 6, height: 6).padding(.top, 5) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            Divider().opacity(0.25).padding(.leading, 44)
                        }
                    }
                }
            }
            Divider()
            ResourcePanel(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }

    private func securityColor(_ level: SecurityLevel) -> Color {
        switch level {
        case .normal: .green
        case .sensitive: .orange
        case .critical: .red
        }
    }
}

private struct ResourcePanel: View {
    @Bindable var model: AgentViewModel
    private var snapshot: ResourceSnapshot { model.resources.snapshot }
    private var totalUsage: UInt64 { snapshot.systemUsedBytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("메모리").font(.headline)
                Spacer()
                Text("\(bytes(totalUsage)) / \(bytes(snapshot.physicalBytes))")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
            }
            MemoryGraph(values: snapshot.history)
                .frame(height: 42)
            HStack(spacing: 18) {
                utilization("CPU", snapshot.cpuUsage, .blue)
                utilization("GPU", snapshot.gpuUsage, .purple)
            }
            HStack {
                Label("온도 상태", systemImage: "thermometer.medium").foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.thermalState).foregroundStyle(snapshot.thermalState == "정상" ? Color.secondary : .orange)
            }.font(.system(size: 13))
            VStack(spacing: 7) {
                resourceRow("모델 프로세스", snapshot.modelBytes, .purple)
                resourceRow("Opium", snapshot.appBytes, .blue)
                if let selected = model.llama.selectedModel {
                    HStack {
                        Text("모델 파일").foregroundStyle(.secondary)
                        Spacer(); Text(bytes(selected.fileSize)).monospacedDigit()
                    }
                    HStack {
                        Text("양자화").foregroundStyle(.secondary)
                        Spacer(); Text("\(selected.quantization) · BF16 대비 약 \(quantRatio(selected.quantization))")
                    }
                }
                HStack {
                    Text("컨텍스트").foregroundStyle(.secondary)
                    Spacer(); Text("\(model.liveMetrics.promptTokens.formatted()) / 32K").monospacedDigit()
                }
                HStack {
                    Text("생성 속도").foregroundStyle(.secondary)
                    Spacer(); Text(String(format: "%.1f tok/s", model.liveMetrics.tokensPerSecond)).monospacedDigit()
                }
            }.font(.system(size: 13))
            if model.llama.isRunning {
                Button { model.llama.stop() } label: {
                    Label("모델 언로드", systemImage: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                .disabled(model.llama.isGenerating)
            }
        }
        .padding(16)
    }

    private func utilization(_ title: String, _ value: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value.map { "\(Int($0 * 100))%" } ?? "—").monospacedDigit()
            }
            ProgressView(value: value ?? 0).tint(color)
        }.font(.system(size: 13)).frame(maxWidth: .infinity)
    }

    private func resourceRow(_ title: String, _ value: UInt64, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer(); Text(bytes(value)).monospacedDigit()
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func quantRatio(_ quant: String) -> String {
        if quant.hasPrefix("Q4") { return "25%" }
        if quant.hasPrefix("Q5") { return "31%" }
        if quant.hasPrefix("Q6") { return "38%" }
        if quant.hasPrefix("Q8") { return "50%" }
        return "—"
    }
}

private struct MemoryGraph: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("시스템 메모리 사용량 그래프")
    }
}

private struct MessageView: View {
    let message: ChatMessage
    var body: some View {
        if message.role == .tool { ToolMessageView(message: message) }
        else {
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if message.content.isEmpty, let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("생각 과정") { Text(reasoning).foregroundStyle(.secondary).textSelection(.enabled) }.font(.caption)
                }
                MarkdownMessageView(markdown: message.content.isEmpty ? " " : message.content)
                    .padding(.horizontal, message.role == .user ? 16 : 0)
                    .padding(.vertical, message.role == .user ? 13 : 0)
                    .background(message.role == .user ? Color(red: 0.48, green: 0.38, blue: 0.96).opacity(0.17) : .clear,
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(message.role == .user ? Color(red: 0.55, green: 0.45, blue: 1).opacity(0.22) : .clear))
                    .frame(maxWidth: message.role == .user ? 720 : .infinity,
                           alignment: message.role == .user ? .trailing : .leading)
                if let attachments = message.attachments, !attachments.isEmpty {
                    HStack { ForEach(attachments) { Label("\($0.name) · \($0.formattedSize)", systemImage: "doc.text").font(.caption) } }
                }
                if let metrics = message.metrics, message.role == .assistant { MetricsView(metrics: metrics) }
                if let files = message.changedFiles, !files.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("변경한 항목 \(files.count)개", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.green)
                        if let stats = message.changeStats, !stats.isEmpty {
                            ForEach(stats) { stat in
                                HStack {
                                    Text(stat.path).font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    ChangeCountView(stats: [stat])
                                }
                            }
                        } else {
                            ForEach(files, id: \.self) { path in
                                Text(path).font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .padding(10).background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        }
    }
}

private struct MarkdownMessageView: View {
    let markdown: String
    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(.system(size: level == 1 ? 22 : level == 2 ? 19 : 17, weight: .semibold))
                        .padding(.top, level == 1 ? 5 : 2)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(.secondary).frame(width: 5, height: 5)
                        inline(text)
                    }.padding(.leading, 4)
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number).").foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                        inline(text)
                    }
                case .paragraph(let text):
                    inline(text)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
        .font(.system(size: 16.5)).lineSpacing(6).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ source: String) -> Text {
        let value = (try? AttributedString(markdown: source,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        return Text(value)
    }
}

private enum MarkdownBlock {
    case heading(Int, String), bullet(String), numbered(Int, String), paragraph(String), code(String, String)

    static func parse(_ source: String) -> [Self] {
        var result: [Self] = []
        var paragraph: [String] = []
        var code: [String] = []
        var language = ""
        var inCode = false
        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll() }
        }
        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if inCode { result.append(.code(language, code.joined(separator: "\n"))); code.removeAll() }
                else { flushParagraph(); language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                inCode.toggle(); continue
            }
            if inCode { code.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushParagraph(); continue }
            if let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flushParagraph(); result.append(.heading(match.1.count, String(match.2))); continue
            }
            if let match = line.firstMatch(of: /^\s*[-*•]\s+(.+)$/) {
                flushParagraph(); result.append(.bullet(String(match.1))); continue
            }
            if let match = line.firstMatch(of: /^\s*(\d+)\.\s+(.+)$/), let number = Int(match.1) {
                flushParagraph(); result.append(.numbered(number, String(match.2))); continue
            }
            paragraph.append(line)
        }
        if inCode { result.append(.code(language, code.joined(separator: "\n"))) }
        flushParagraph()
        return result
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "코드" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                } label: {
                    Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.secondary.opacity(0.08))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 14, design: .monospaced)).lineSpacing(3)
                    .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.1)))
    }
}

private struct ChangeCountView: View {
    let stats: [FileChangeStat]
    private var additions: Int { stats.reduce(0) { $0 + $1.additions } }
    private var deletions: Int { stats.reduce(0) { $0 + $1.deletions } }

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("-\(deletions)").foregroundStyle(.red)
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .contentTransition(.numericText())
        .animation(.snappy, value: additions + deletions)
    }
}

private struct ToolMessageView: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup {
                Text(message.content).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Label(toolTitle + " 완료", systemImage: "checkmark.circle").font(.caption.weight(.medium))
                    if let metrics = message.metrics { MetricsView(metrics: metrics) }
                }
            }
        }.foregroundStyle(.secondary).padding(11).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var toolTitle: String {
        let name = message.content.components(separatedBy: "\n").first ?? ""
        return [
            "[read_file]": "파일 읽음", "[list_files]": "폴더 확인",
            "[search_files]": "파일 검색", "[write_file]": "파일 수정",
            "[create_directory]": "폴더 생성", "[move_file]": "파일 이동",
            "[trash_file]": "휴지통으로 이동", "[run_command]": "명령 실행",
            "[search_mail]": "메일 검색", "[fetch_url]": "웹페이지 확인"
        ][name] ?? "도구 실행"
    }
}

private struct MetricsView: View {
    let metrics: GenerationMetrics
    var body: some View {
        Text(metricText)
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            .help("입력 \(metrics.promptTokens) 토큰 · 출력 \(metrics.completionTokens) 토큰")
    }

    private var metricText: String {
        if metrics.completionTokens == 0, metrics.elapsedSeconds > 0 {
            return "응답 작성 중  ·  \(String(format: "%.1f", metrics.elapsedSeconds))초"
        }
        let thinking = metrics.thinkingSeconds.map { String(format: "%.1f초 생각  ·  ", $0) } ?? ""
        return "\(thinking)입력 \(metrics.promptTokens.formatted())  ·  출력 \(metrics.completionTokens.formatted())  ·  \(String(format: "%.1f", metrics.tokensPerSecond)) tok/s  ·  \(String(format: "%.1f", metrics.elapsedSeconds))초"
    }
}

private struct PermissionSettingsView: View {
    @Bindable var store: PermissionStore
    let usage: GenerationMetrics
    let modelName: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("권한 및 설정").font(.title2.weight(.semibold))
                    Text("사용량, 실행 권한, 연결된 도구를 관리합니다.").foregroundStyle(.secondary)
                }
                Spacer(); Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 10) {
                usageCard("입력 토큰", usage.promptTokens)
                usageCard("출력 토큰", usage.completionTokens)
                usageCard("전체 토큰", usage.promptTokens + usage.completionTokens)
            }
            Text(modelName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            VStack(alignment: .leading, spacing: 8) {
                Text("실행 권한").font(.headline)
                ForEach(ToolPolicy.allCases) { policy in
                    Button { store.policy = policy } label: {
                        HStack(spacing: 10) {
                            Image(systemName: store.policy == policy ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(store.policy == policy ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(policy.title).foregroundStyle(.primary)
                                Text(policy.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("신뢰하는 폴더").font(.headline); Spacer(); Button("폴더 추가", action: store.chooseFolder) }
                if store.trustedFolders.isEmpty {
                    Text("등록된 폴더가 없습니다. 변경 작업은 항상 확인을 요청합니다.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ForEach(store.trustedFolders, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(path).lineLimit(1).truncationMode(.middle); Spacer()
                            Button { store.remove(path) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }.padding(10).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            HStack(spacing: 16) {
                Label("파일", systemImage: "folder").foregroundStyle(.green)
                Label("Apple Mail", systemImage: "envelope").foregroundStyle(.blue)
                Label("웹 읽기/제작", systemImage: "globe").foregroundStyle(.purple)
            }.font(.caption)
        }.padding(26).frame(width: 600, height: 620)
    }

    private func usageCard(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title3.monospacedDigit().weight(.semibold))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PluginDirectoryView: View {
    @Bindable var store: PluginStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("플러그인").font(.title2.weight(.semibold))
                    Text("스킬과 도구를 하나의 번들로 설치하고 관리합니다.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("플러그인 추가", systemImage: "plus") { store.chooseAndInstall() }
                    .buttonStyle(.borderedProminent)
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Divider()
            if store.plugins.isEmpty {
                ContentUnavailableView {
                    Label("설치된 플러그인이 없습니다", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("`.codex-plugin/plugin.json`이 있는 Codex 형식의 플러그인 폴더를 추가하세요.")
                } actions: {
                    Button("플러그인 폴더 선택", action: store.chooseAndInstall)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.plugins) { plugin in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top, spacing: 12) {
                                    RoundedRectangle(cornerRadius: 10).fill(.purple.opacity(0.14))
                                        .overlay(Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.purple))
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(plugin.displayName).font(.headline)
                                        Text(plugin.summary).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                                        HStack(spacing: 6) {
                                            capability("Skill \(plugin.skillURLs.count)", active: !plugin.skillURLs.isEmpty)
                                            capability("MCP", active: plugin.hasMCP)
                                            capability("Hooks", active: plugin.hasHooks)
                                            if let version = plugin.manifest.version { capability("v\(version)", active: true) }
                                        }
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(get: { plugin.isEnabled },
                                                             set: { store.setEnabled($0, for: plugin) }))
                                        .labelsHidden().toggleStyle(.switch)
                                    Menu {
                                        Button("폴더에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([plugin.rootURL]) }
                                        Divider()
                                        Button("삭제", role: .destructive) { store.uninstall(plugin) }
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                                }
                                if plugin.hasMCP || plugin.hasHooks {
                                    Label("MCP와 Hooks는 현재 자동 실행되지 않습니다.", systemImage: "shield.lefthalf.filled")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(16).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.07)))
                        }
                    }.padding(20)
                }
            }
        }
        .frame(width: 720, height: 620)
        .alert("플러그인 오류", isPresented: Binding(get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(store.errorMessage ?? "") }
    }

    private func capability(_ title: String, active: Bool) -> some View {
        Text(title).font(.caption2.weight(.medium)).foregroundStyle(active ? .primary : .tertiary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.secondary.opacity(active ? 0.12 : 0.05), in: Capsule())
    }
}

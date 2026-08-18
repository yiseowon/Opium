import AppKit
import SwiftUI

extension Color {
    static let opiumPurple = Color(red: 0.48, green: 0.38, blue: 0.96)
    static let opiumPurpleSoft = opiumPurple.opacity(0.14)
    static let opiumPurpleMuted = opiumPurple.opacity(0.07)
}

/// A small type scale shared by the sidebar, message stream, inspector, and composer
/// so panel-to-panel text doesn't drift to arbitrary point sizes.
enum AppFont {
    static let panelTitle = Font.system(size: 18, weight: .semibold)
    static let heading = Font.system(size: 16, weight: .semibold)
    static let body = Font.system(size: 15)
    static let bodyEmphasis = Font.system(size: 15, weight: .medium)
    static let secondary = Font.system(size: 14)
    static let secondaryEmphasis = Font.system(size: 14, weight: .medium)
    static let caption = Font.system(size: 13)
    static let mono = Font.system(size: 13, design: .monospaced)
    static let micro = Font.system(size: 11, weight: .semibold)
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var service: LlamaService?
    weak var resourceMonitor: ResourceMonitor?
    func applicationWillTerminate(_ notification: Notification) {
        resourceMonitor?.stop()
        service?.stop()
    }
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
                .onAppear {
                    appDelegate.service = model.llama
                    appDelegate.resourceMonitor = model.resources
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { CommandGroup(replacing: .newItem) { Button("새 작업") { model.store.newThread() }.keyboardShortcut("n") } }
    }
}

struct ContentView: View {
    @Bindable var model: AgentViewModel
    @State private var showingPermissions = false
    @State private var showingPlugins = false
    @State private var showingModelDownloads = false
    @State private var composerHeight: CGFloat = 22
    @State private var sidebarVisible = true
    @State private var inspectorVisible = true
    @State private var renamingThread: ChatThread?
    @State private var renameText = ""
    @State private var deletingThread: ChatThread?
    @State private var newWorkKind: WorkKind?

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
                if let question = model.pendingQuestion { AgentQuestionCard(question: question, model: model) }
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
        .sheet(isPresented: $showingPlugins) { PluginDirectoryView(model: model) }
        .sheet(isPresented: $showingModelDownloads) { ModelDownloadView(model: model) }
        .sheet(item: $newWorkKind) { kind in NewWorkView(kind: kind, store: model.store) }
        .alert("오류", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
        .alert("작업 이름 변경", isPresented: Binding(get: { renamingThread != nil }, set: { if !$0 { renamingThread = nil } })) {
            TextField("작업 이름", text: $renameText)
            Button("취소", role: .cancel) { renamingThread = nil }
            Button("저장") {
                if let thread = renamingThread { model.store.setTitle(renameText, for: thread.id) }
                renamingThread = nil
            }
        }
        .alert("작업을 삭제할까요?", isPresented: Binding(get: { deletingThread != nil }, set: { if !$0 { deletingThread = nil } })) {
            Button("취소", role: .cancel) { deletingThread = nil }
            Button("삭제", role: .destructive) {
                if let thread = deletingThread { model.store.delete(Set([thread.id])) }
                deletingThread = nil
            }
        } message: { Text("대화 기록만 삭제하며 작업 폴더의 파일은 유지합니다.") }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { withAnimation(.easeInOut(duration: 0.16)) { sidebarVisible.toggle() } } label: {
                    Image(systemName: "sidebar.left")
                }.help(sidebarVisible ? "사이드바 닫기" : "사이드바 열기")
                Button { withAnimation(.easeInOut(duration: 0.18)) { inspectorVisible.toggle() } } label: {
                    Image(systemName: "sidebar.right")
                }.help(inspectorVisible ? "활동 패널 닫기" : "활동 패널 열기")
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                OpiumMark().stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 19, height: 19).accessibilityHidden(true)
                Text("Opium").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
            VStack(spacing: 3) {
                ForEach(WorkKind.allCases) { kind in
                    Button {
                        if kind == .task { model.store.newThread() } else { newWorkKind = kind }
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                    }
                    .buttonStyle(OpiumHoverButtonStyle())
                }
            }
            .font(AppFont.bodyEmphasis)
            .padding(5).background(Color.opiumPurpleMuted, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 10)
            List(selection: $model.store.selectedID) {
                Section("최근 작업") {
                    ForEach(model.store.threads) { thread in
                        Text(thread.displayTitle)
                            .lineLimit(1).tag(thread.id)
                            .contextMenu {
                                Button("이름 변경", systemImage: "pencil") {
                                    renameText = thread.displayTitle; renamingThread = thread
                                }
                                Button("Finder에서 작업 폴더 보기", systemImage: "folder") {
                                    if let path = thread.workspacePath {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    }
                                }
                                Divider()
                                Button("작업 삭제", systemImage: "trash", role: .destructive) { deletingThread = thread }
                            }
                    }
                        .onDelete { offsets in model.store.delete(Set(offsets.map { model.store.threads[$0].id })) }
                }
            }
            .font(AppFont.body)
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            Button { showingPlugins = true } label: {
                HStack {
                    Image(systemName: "puzzlepiece.extension").frame(width: 18, alignment: .center)
                    Text("플러그인")
                    Spacer()
                    Text("\(model.plugins.plugins.filter(\.isEnabled).count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.horizontal, 14).padding(.vertical, 11)
            }.buttonStyle(OpiumHoverButtonStyle())
            Button { showingModelDownloads = true } label: {
                HStack {
                    Image(systemName: "arrow.down.circle").frame(width: 18, alignment: .center)
                    Text("모델 관리")
                    Spacer()
                    Text("\(model.llama.models.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.horizontal, 14).padding(.vertical, 11)
            }.buttonStyle(OpiumHoverButtonStyle())
            Divider().opacity(0.5)
            Button { showingPermissions = true } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3").frame(width: 18, alignment: .center)
                    Text("권한 및 설정")
                    Spacer()
                    Text(model.permissions.policy.title).font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.horizontal, 14).padding(.vertical, 11)
            }.buttonStyle(OpiumHoverButtonStyle())
        }.background(Color(nsColor: .windowBackgroundColor).opacity(0.68))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.store.selected?.displayTitle ?? "새 작업").font(AppFont.heading).lineLimit(1)
                Text(model.llama.selectedModel?.name ?? "모델을 선택하세요").font(AppFont.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.llama.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                Text(model.llama.status).font(.caption)
            }.padding(.horizontal, 10).padding(.vertical, 6).background(.secondary.opacity(0.09), in: Capsule())
            Button { showingPermissions = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(OpiumHoverButtonStyle(compact: true)).help("권한 및 설정")
        }.padding(.horizontal, 24).frame(height: 56).background(.bar)
    }

    private var messages: some View {
        let visibleMessages = ChatMessage.visibleConversation(model.store.selected?.messages ?? [],
                                                              condenseCurrentTurn: !model.llama.isGenerating)
        return ScrollViewReader { proxy in
            ScrollView {
                if model.store.selected?.messages.isEmpty != false {
                    VStack(spacing: 12) {
                        OpiumMark().stroke(Color.opiumPurple.opacity(0.72), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 34, height: 34)
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
                                OpiumLoader()
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("모델 로드 중").font(AppFont.bodyEmphasis)
                                    Text(model.llama.selectedModel?.displayName ?? "로컬 모델")
                                        .font(AppFont.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .transition(.opacity)
                        }
                        if let activity = model.inlineActivity {
                            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                                HStack(spacing: 10) {
                                    OpiumLoader()
                                    Image(systemName: activity.symbol).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(activity.title)  ·  \(context.date.timeIntervalSince(activity.date), format: .number.precision(.fractionLength(1)))초")
                                            .font(AppFont.secondaryEmphasis).foregroundStyle(.secondary)
                                        if let detail = activity.detail, !detail.isEmpty {
                                            Text(detail).font(AppFont.mono)
                                                .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    if !model.activeChangeStats.isEmpty { ChangeCountView(stats: model.activeChangeStats) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.llama.isGenerating, model.inlineActivity == nil {
                            HStack(spacing: 8) {
                                OpiumLoader()
                                Text("응답 작성 중").font(AppFont.mono).foregroundStyle(.secondary)
                                if !model.activeChangeStats.isEmpty { ChangeCountView(stats: model.activeChangeStats) }
                            }
                        }
                        if turnIsActive || turnFooterMetrics.completionTokens > 0 {
                            MetricsView(metrics: turnIsActive ? model.turnMetrics : turnFooterMetrics)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
            }.onChange(of: model.inlineActivity?.id) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }.onChange(of: model.activeChangeStats) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }.frame(maxWidth: .infinity)
    }

    private var turnFooterMetrics: GenerationMetrics {
        model.store.selected?.messages.last(where: {
            $0.role == .assistant && $0.isProgress != true && $0.metrics != nil
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.metrics ?? GenerationMetrics()
    }

    private var turnIsActive: Bool { model.llama.isGenerating || model.inlineActivity != nil }

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
            if model.hasQueuedFollowUp {
                Label("현재 답변이 끝나면 이어서 전송합니다", systemImage: "text.append")
                    .font(.caption).foregroundStyle(Color.opiumPurple)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ComposerTextView(text: $model.input, height: $composerHeight, minHeight: 22, maxHeight: 220) {
                Task { await model.send() }
            }
            .frame(height: composerHeight, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if model.input.isEmpty {
                    Text("무엇이든 요청하세요").foregroundStyle(.secondary).font(AppFont.body)
                        .padding(.leading, ComposerMetrics.placeholderInset).padding(.top, 3)
                        .allowsHitTesting(false)
                }
            }
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
                    Menu("모델") {
                        ForEach(model.llama.models) { item in
                            Button { Task { await model.selectModel(item) } } label: {
                                if model.llama.selectedModel == item { Label(item.displayName, systemImage: "checkmark") }
                                else { Text(item.displayName) }
                            }
                        }
                        Divider(); Button("모델 다시 찾기", action: model.llama.discoverModels)
                    }
                    Menu("추론 강도") {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Button { model.llama.effort = effort } label: {
                                if model.llama.effort == effort { Label(effort.rawValue, systemImage: "checkmark") }
                                else { Text(effort.rawValue) }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.llama.selectedModel?.displayName ?? "모델 선택").lineLimit(1)
                        Text(model.llama.effort.rawValue).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.llama.isGenerating)
                .help("모델과 추론 강도 선택")
                if model.llama.isGenerating,
                   !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty {
                    Button("다음에 보내기") { Task { await model.send() } }
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Color.opiumPurple)
                }
                Button {
                    if model.llama.isGenerating { model.stopGeneration() }
                    else { Task { await model.send() } }
                } label: {
                    if model.llama.isStarting { OpiumLoader() }
                    else if model.llama.isGenerating { Image(systemName: "stop.fill").font(.system(size: 11, weight: .semibold)) }
                    else { Image(systemName: "arrow.up").fontWeight(.semibold) }
                }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .tint(Color.opiumPurple)
                    .disabled((!model.llama.isGenerating && model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty)
                              || model.llama.selectedModel == nil || model.llama.isStarting)
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

private struct OpiumHoverButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, compact: compact)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(compact ? 7 : 0)
                .background(Color.opiumPurple.opacity(hovering ? 0.12 : configuration.isPressed ? 0.18 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

private struct NewWorkView: View {
    let kind: WorkKind
    @Bindable var store: ThreadStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var workspacePath: String?
    @State private var date = Date().addingTimeInterval(3_600)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(kind.title, systemImage: kind.symbol).font(.title2.weight(.semibold))
            TextField("이름", text: $title).textFieldStyle(.roundedBorder)
            if kind == .project {
                HStack {
                    Text(workspacePath ?? "전용 작업 폴더를 자동으로 만듭니다.")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("폴더 선택") { chooseFolder() }
                }
            }
            if kind == .scheduled || kind == .recurring {
                DatePicker(kind == .recurring ? "첫 실행" : "실행 시각", selection: $date)
                if kind == .recurring {
                    Text("현재 프리뷰에서는 반복 계획을 저장합니다. 백그라운드 자동 실행은 앱이 실행 중일 때만 제공될 예정입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack {
                Button("취소", role: .cancel) { dismiss() }
                Spacer()
                Button("만들기") {
                    store.newThread(kind: kind, title: title.isEmpty ? nil : title,
                                    workspacePath: workspacePath,
                                    schedule: (kind == .scheduled || kind == .recurring)
                                        ? WorkSchedule(date: date, repeats: kind == .recurring) : nil)
                    dismiss()
                }.buttonStyle(.borderedProminent).tint(.opiumPurple).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480, height: 300)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        workspacePath = panel.url?.path
    }
}

enum ComposerMetrics {
    /// Left inset of the text itself. The caret sits at this x, so the placeholder is
    /// drawn a couple points further right to keep the two from overlapping.
    static let textInset: CGFloat = 4
    static let placeholderInset: CGFloat = textInset + 3
}

/// Plain `TextField(axis: .vertical)` sends on every Return, so composing a multi-line
/// prompt required awkward workarounds. This wraps an `NSTextView` directly: Return sends,
/// Shift+Return inserts a newline.
private final class ReturnAwareTextView: NSTextView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        if isReturnKey, !event.modifierFlags.contains(.shift) {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ReturnAwareTextView()
        textView.delegate = context.coordinator
        textView.onReturn = { context.coordinator.parent.onSubmit() }
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.drawsBackground = false
        // A zero-width inset puts the caret at x=0, right on top of the first glyph of
        // the SwiftUI placeholder drawn at the same origin. The inset gives the caret
        // its own column; the placeholder is offset past it in `composer`.
        textView.textContainerInset = NSSize(width: ComposerMetrics.textInset, height: 3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        // NSTextContainer adds 5pt of lineFragmentPadding by default, so text actually
        // begins at inset + 5 — which put the caret past the placeholder's origin and
        // dropped it inside the first glyph. Zeroing it makes the inset the true origin.
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        textView.allowsUndo = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.recalculateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onReturn = { context.coordinator.parent.onSubmit() }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }
    }

    /// NSScrollView reports no intrinsic content size, so a bare min/maxHeight frame
    /// just expands it to the maximum every time — this measures the actual text
    /// height and drives a fixed frame from that instead, so the box starts small
    /// and only grows with what's actually typed.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ReturnAwareTextView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func recalculateHeight() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
            let clamped = min(max(used, parent.minHeight), parent.maxHeight)
            if abs(clamped - parent.height) > 0.5 { parent.height = clamped }
        }
    }
}

private struct AgentQuestionCard: View {
    let question: AgentQuestion
    @Bindable var model: AgentViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                OpiumMark().stroke(Color.opiumPurple, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20)
                Text(question.question).font(.headline)
            }
            if let detail = question.detail, !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button(option) { Task { await model.answerQuestion(option) } }
                        .buttonStyle(.bordered).tint(.opiumPurple)
                }
            }
        }
        .padding(16).background(Color.opiumPurpleSoft, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.opiumPurple.opacity(0.24)))
        .frame(maxWidth: 820, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
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

private struct OpiumLoader: View {
    @State private var blooming = false

    var body: some View {
        OpiumMark()
            .stroke(Color.opiumPurple, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .frame(width: 16, height: 16)
            .scaleEffect(blooming ? 1 : 0.72)
            .opacity(blooming ? 1 : 0.35)
            .shadow(color: .opiumPurple.opacity(blooming ? 0.5 : 0), radius: 5)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: blooming)
            .onAppear { blooming = true }
            .accessibilityLabel("작업 중")
    }
}

private struct ActivityInspector: View {
    @Bindable var model: AgentViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("보안 활동").font(AppFont.panelTitle)
                }
                Spacer()
                if model.llama.isGenerating { OpiumLoader() }
            }.padding(16)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.activities.isEmpty {
                        Color.clear.frame(height: 1)
                    } else {
                        ForEach(model.activities.reversed()) { activity in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: activity.securityLevel == nil ? activity.symbol : "shield.fill")
                                    .foregroundStyle(activity.securityLevel.map(securityColor) ?? (activity.isActive ? Color.opiumPurple : Color.secondary))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(activity.title).font(AppFont.bodyEmphasis)
                                        if let level = activity.securityLevel {
                                            Text(level.title).font(AppFont.micro)
                                                .foregroundStyle(securityColor(level))
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(securityColor(level).opacity(0.12), in: Capsule())
                                        }
                                    }
                                    if let detail = activity.detail, !detail.isEmpty {
                                        Text(detail).font(AppFont.secondary).foregroundStyle(.secondary)
                                            .lineLimit(2).truncationMode(.middle)
                                    }
                                    if let outcome = activity.outcome, !outcome.isEmpty {
                                        Text(outcome).font(AppFont.caption).foregroundStyle(.secondary)
                                            .lineLimit(2).truncationMode(.middle)
                                    }
                                    Text(activity.date, style: .time).font(AppFont.caption).foregroundStyle(.tertiary)
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
                    .font(AppFont.secondary).monospacedDigit().foregroundStyle(.secondary)
            }
            MemoryGraph(values: snapshot.history)
                .frame(height: 42)
            HStack(spacing: 18) {
                utilization("CPU", snapshot.cpuUsage, Color.opiumPurple.opacity(0.62))
                utilization("GPU", snapshot.gpuUsage, .opiumPurple)
            }
            HStack {
                Label("온도 상태", systemImage: "thermometer.medium").foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.thermalState).foregroundStyle(snapshot.thermalState == "정상" ? Color.secondary : .orange)
            }.font(AppFont.secondary)
            VStack(spacing: 7) {
                resourceRow("모델 프로세스", snapshot.modelBytes, .opiumPurple)
                resourceRow("Opium", snapshot.appBytes, Color.opiumPurple.opacity(0.62))
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
                    Spacer(); Text("\(model.liveMetrics.promptTokens.formatted()) / \(model.llama.lowPowerMode ? "16K" : "32K")").monospacedDigit()
                }
                HStack {
                    Text("생성 속도").foregroundStyle(.secondary)
                    Spacer(); Text(String(format: "%.1f tok/s", model.liveMetrics.tokensPerSecond)).monospacedDigit()
                }
            }.font(AppFont.secondary)
            if model.llama.isRunning {
                Button { model.llama.stop() } label: {
                    Label("모델 언로드", systemImage: "power")
                        .font(AppFont.secondaryEmphasis)
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
        }.font(AppFont.secondary).frame(maxWidth: .infinity)
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
            .stroke(Color.opiumPurple, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
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
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("생각 과정") { Text(reasoning).foregroundStyle(.secondary).textSelection(.enabled) }.font(.caption)
                }
                MarkdownMessageView(markdown: message.content.isEmpty ? " " : message.content)
                    .padding(.horizontal, message.role == .user ? 16 : 0)
                    .padding(.vertical, message.role == .user ? 13 : 0)
                    .background(message.role == .user ? Color.opiumPurple.opacity(0.17) : .clear,
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(message.role == .user ? Color.opiumPurple.opacity(0.28) : .clear))
                    .frame(maxWidth: message.role == .user ? 720 : .infinity,
                           alignment: message.role == .user ? .trailing : .leading)
                if let attachments = message.attachments, !attachments.isEmpty {
                    HStack { ForEach(attachments) { Label("\($0.name) · \($0.formattedSize)", systemImage: "doc.text").font(.caption) } }
                }
                if let files = message.changedFiles, !files.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("변경한 항목 \(files.count)개", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.opiumPurple)
                        if let stats = message.changeStats, !stats.isEmpty {
                            ForEach(stats) { stat in
                                HStack {
                                    Text(stat.path).font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    ChangeCountView(stats: [stat], showsFileName: false)
                                }
                            }
                        } else {
                            ForEach(files, id: \.self) { path in
                                Text(path).font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .padding(10).background(Color.opiumPurple.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.opiumPurple.opacity(0.16)))
                }
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        }
    }
}

private struct MarkdownMessageView: View {
    let markdown: String
    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(.system(size: level == 1 ? 22 : level == 2 ? 19 : 17, weight: .semibold))
                        .padding(.top, level == 1 ? 5 : 2)
                case .bullets(let items):
                    listCard {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(.secondary).frame(width: 5, height: 5)
                                inline(text)
                            }
                        }
                    }
                case .numbered(let items):
                    listCard {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text("\(item.0).").foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                                inline(item.1)
                            }
                        }
                    }
                case .paragraph(let text):
                    inline(text)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .table(let header, let rows):
                    MarkdownTableView(header: header, rows: rows)
                }
            }
        }
        .font(AppFont.body).lineSpacing(5).textSelection(.enabled)
        .onAppear { blocks = MarkdownBlock.parse(markdown) }
        .onChange(of: markdown) { _, newValue in blocks = MarkdownBlock.parse(newValue) }
    }

    private func listCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.primary.opacity(0.08)))
    }

    private func inline(_ source: String) -> Text {
        let value = (try? AttributedString(markdown: source,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        return Text(value)
    }
}

enum MarkdownBlock {
    case heading(Int, String), bullets([String]), numbered([(Int, String)]), paragraph(String), code(String, String)
    case table([String], [[String]])

    static func parse(_ source: String) -> [Self] {
        var result: [Self] = []
        var paragraph: [String] = []
        var code: [String] = []
        var bullets: [String] = []
        var numbers: [(Int, String)] = []
        var language = ""
        var inCode = false
        let lines = source.components(separatedBy: .newlines)
        func flushParagraph() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll() }
        }
        func flushLists() {
            if !bullets.isEmpty { result.append(.bullets(bullets)); bullets.removeAll() }
            if !numbers.isEmpty { result.append(.numbered(numbers)); numbers.removeAll() }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                if inCode { result.append(.code(language, code.joined(separator: "\n"))); code.removeAll() }
                else { flushParagraph(); flushLists(); language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                inCode.toggle(); index += 1; continue
            }
            if inCode { code.append(line); index += 1; continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushParagraph(); flushLists(); index += 1; continue }
            if index + 1 < lines.count, let table = parseTable(header: line, separator: lines[index + 1], remaining: lines[(index + 2)...]) {
                flushParagraph(); flushLists()
                result.append(.table(table.header, table.rows))
                index += 2 + table.rows.count
                continue
            }
            if let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flushParagraph(); flushLists(); result.append(.heading(match.1.count, String(match.2))); index += 1; continue
            }
            if let match = line.firstMatch(of: /^\s*[-*•]\s+(.+)$/) {
                flushParagraph(); if !numbers.isEmpty { flushLists() }; bullets.append(String(match.1)); index += 1; continue
            }
            if let match = line.firstMatch(of: /^\s*(\d+)\.\s+(.+)$/), let number = Int(match.1) {
                flushParagraph(); if !bullets.isEmpty { flushLists() }; numbers.append((number, String(match.2))); index += 1; continue
            }
            flushLists()
            paragraph.append(line)
            index += 1
        }
        if inCode { result.append(.code(language, code.joined(separator: "\n"))) }
        flushParagraph(); flushLists()
        return result
    }

    private static func parseTable(header: String, separator: String, remaining: ArraySlice<String>) -> (header: [String], rows: [[String]])? {
        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard header.contains("|") else { return nil }
        let separatorCells = cells(separator)
        guard !separatorCells.isEmpty,
              separatorCells.allSatisfy({ $0.trimmingCharacters(in: CharacterSet(charactersIn: ":- ")).isEmpty && $0.contains("-") })
        else { return nil }
        let headerCells = cells(header)
        var rows: [[String]] = []
        for line in remaining {
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            rows.append(cells(line))
        }
        return (headerCells, rows)
    }
}

private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    cellText(cell, weight: .semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(header.indices), id: \.self) { column in
                        cellText(column < row.count ? row[column] : "")
                    }
                }
                if rowIndex < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
        .font(AppFont.caption)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.primary.opacity(0.08)))
    }

    private func cellText(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(text).fontWeight(weight).lineLimit(3)
            .padding(.trailing, 18).padding(.vertical, 6)
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
                Text(code).font(AppFont.secondary).monospaced().lineSpacing(3)
                    .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.1)))
    }
}

private struct ChangeCountView: View {
    let stats: [FileChangeStat]
    var showsFileName = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(stats) { stat in
                HStack(spacing: 5) {
                    if showsFileName {
                        Text(URL(fileURLWithPath: stat.path).lastPathComponent)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Text("+\(stat.additions)").foregroundStyle(.green)
                    Text("-\(stat.deletions)").foregroundStyle(.red)
                }
                .contentTransition(.numericText())
                .animation(.snappy, value: stat.additions + stat.deletions)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
    }
}

private struct ToolMessageView: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup {
                Text(message.content).font(AppFont.mono).textSelection(.enabled).padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Label(toolTitle + " 완료", systemImage: "checkmark.circle").font(.caption.weight(.medium))
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
            "[search_mail]": "메일 검색", "[fetch_url]": "웹페이지 확인", "[web_search]": "웹 검색",
            "[list_ui_elements]": "화면 요소 확인", "[click_ui_element]": "화면 클릭",
            "[take_screenshot]": "화면 캡처", "[click_at]": "좌표 클릭",
            "[type_text]": "텍스트 입력", "[press_key]": "키 입력"
        ][name] ?? "도구 실행"
    }
}

private struct MetricsView: View {
    let metrics: GenerationMetrics
    var body: some View {
        Text(metricText)
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            .help("총 \(metrics.promptTokens + metrics.completionTokens) 토큰")
    }

    private var metricText: String {
        if metrics.completionTokens == 0, metrics.elapsedSeconds > 0 {
            return "응답 작성 중  ·  \(String(format: "%.1f", metrics.elapsedSeconds))초"
        }
        let thinking = metrics.thinkingSeconds.map { String(format: "%.1f초 생각  ·  ", $0) } ?? ""
        return "\(thinking)\((metrics.promptTokens + metrics.completionTokens).formatted()) 토큰  ·  \(String(format: "%.1f", metrics.tokensPerSecond)) tok/s  ·  \(String(format: "%.1f", metrics.elapsedSeconds))초"
    }
}

private struct PermissionSettingsView: View {
    @Bindable var store: PermissionStore
    let usage: GenerationMetrics
    let modelName: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("권한 및 설정").font(.title2.weight(.semibold))
                    Text("사용량, 실행 권한, 연결된 도구를 관리합니다.").foregroundStyle(.secondary)
                }
                Spacer(); Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.bottom, 22)
            ScrollView { settingsContent }
        }.padding(26).frame(width: 600, height: 640)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                usageCard("지금까지 사용한 토큰", usage.promptTokens + usage.completionTokens)
            }
            Text(modelName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            VStack(alignment: .leading, spacing: 8) {
                Text("실행 권한").font(.headline)
                ForEach(ToolPolicy.allCases) { policy in
                    Button { store.policy = policy } label: {
                        HStack(spacing: 10) {
                            Image(systemName: store.policy == policy ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(store.policy == policy ? Color.opiumPurple : .secondary)
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
                Label("Apple Mail", systemImage: "envelope").foregroundStyle(Color.opiumPurple.opacity(0.72))
                Label("웹 읽기/제작", systemImage: "globe").foregroundStyle(Color.opiumPurple)
            }.font(.caption)
            computerUseSection
        }
    }

    private var computerUseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $store.computerUseEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("컴퓨터 사용").foregroundStyle(.primary)
                    Text("마우스 클릭, 키보드 입력, 화면 캡처를 모델이 사용할 수 있게 합니다. 항상 개별 승인이 필요합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch)
            if store.computerUseEnabled {
                ComputerUsePermissionStatus()
                Text("화면 캡처는 비전 모델을 선택했을 때만 의미가 있습니다. 텍스트 전용 모델에서는 화면 요소 목록(list_ui_elements)만 활용됩니다.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.25)))
    }

    private func usageCard(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title3.monospacedDigit().weight(.semibold))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// TCC grants can change at any moment from outside the app (System Settings), and
/// AXIsProcessTrusted/CGPreflightScreenCaptureAccess are plain synchronous checks with
/// no change notification — so this polls instead of reading them once at render time,
/// otherwise the row can sit on a stale "not granted" reading indefinitely.
private struct ComputerUsePermissionStatus: View {
    @State private var accessibilityGranted = ComputerUse.hasAccessibilityAccess
    @State private var screenRecordingGranted = ComputerUse.hasScreenRecordingAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            permissionRow(title: "접근성 권한", granted: accessibilityGranted) { ComputerUse.requestAccessibilityAccess() }
            permissionRow(title: "화면 기록 권한", granted: screenRecordingGranted) { ComputerUse.requestScreenRecordingAccess() }
        }
        .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .task {
            while !Task.isCancelled {
                accessibilityGranted = ComputerUse.hasAccessibilityAccess
                screenRecordingGranted = ComputerUse.hasScreenRecordingAccess
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func permissionRow(title: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title).font(.caption)
            Spacer()
            if !granted { Button("권한 요청", action: request).buttonStyle(.bordered).controlSize(.small) }
        }
    }
}

private struct ModelDownloadView: View {
    @Bindable var model: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    private let device = DeviceCapability.current

    private enum Tab: String, CaseIterable, Identifiable { case featured = "추천", search = "검색"; var id: Self { self } }
    @State private var tab: Tab = .featured

    @State private var query = ""
    @State private var searchResults: [HFModelSummary] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var expandedRepo: String?
    @State private var filesByRepo: [String: [HFFile]] = [:]
    @State private var filesLoading = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("모델 관리").font(.title2.weight(.semibold))
                    Text("\(device.chipName) · 메모리 \(device.memoryGB) GB").foregroundStyle(.secondary)
                }
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 12)
            Divider()
            switch tab {
            case .featured: featuredList
            case .search: searchTab
            }
        }
        .frame(width: 600, height: 620)
        .alert("다운로드 오류", isPresented: Binding(get: { model.downloader.errorMessage != nil },
            set: { if !$0 { model.downloader.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(model.downloader.errorMessage ?? "") }
    }

    // MARK: - Featured (curated catalog)

    private var featuredList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(ModelCatalog.all) { item in modelRow(item) }
            }.padding(20)
        }
    }

    private var recommendedID: String? { ModelCatalog.recommended(forMemoryGB: device.memoryGB)?.id }

    private func modelRow(_ item: CatalogModel) -> some View {
        let installed = model.downloader.isInstalled(item)
        let progress = model.downloader.progress[item.id]
        let fitsDevice = item.minMemoryGB <= device.memoryGB

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(item.displayName).font(.headline)
                        if item.id == recommendedID {
                            Text("추천").font(.caption2.weight(.semibold)).foregroundStyle(Color.opiumPurple)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.opiumPurple.opacity(0.12), in: Capsule())
                        }
                    }
                    Text("\(item.quant) · \(String(format: "%.1f", item.sizeGB)) GB · 최소 메모리 \(item.minMemoryGB) GB")
                        .font(.caption).foregroundStyle(.secondary)
                    if !fitsDevice {
                        Text("이 기기 메모리로는 느리거나 불안정할 수 있어요").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                actionButton(item, installed: installed, isDownloading: progress != nil)
            }
            if let progress {
                ProgressView(value: progress).tint(.opiumPurple)
            }
        }
        .padding(14).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07)))
    }

    private func actionButton(_ item: CatalogModel, installed: Bool, isDownloading: Bool) -> some View {
        Group {
            if installed {
                Label("설치됨", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.green)
            } else if isDownloading {
                Button("취소") { model.downloader.cancel(item) }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Button("받기") { model.downloader.start(item) }.buttonStyle(.borderedProminent).controlSize(.small).tint(.opiumPurple)
            }
        }
    }

    // MARK: - Live Hugging Face search

    private var searchTab: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("모델 이름으로 검색 (예: qwen3, llama, gemma)", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { runSearch() }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(10).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .padding([.horizontal, .top], 20).padding(.bottom, 12)
            .onChange(of: query) { _, _ in debounceSearch() }

            if let searchError {
                Text(searchError).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(searchResults) { result in searchResultRow(result) }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }

    private func debounceSearch() {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        Task { await performSearch() }
    }

    private func performSearch() async {
        isSearching = true
        searchError = nil
        do {
            searchResults = try await HuggingFaceSearch.searchModels(query: query)
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    private func searchResultRow(_ result: HFModelSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedRepo = expandedRepo == result.id ? nil : result.id
                }
                guard filesByRepo[result.id] == nil else { return }
                Task {
                    filesLoading = true
                    defer { filesLoading = false }
                    filesByRepo[result.id] = (try? await HuggingFaceSearch.ggufFiles(repo: result.id)) ?? []
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.id).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if let downloads = result.downloads {
                            Text("다운로드 \(downloads.formatted())").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: expandedRepo == result.id ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }.buttonStyle(.plain)

            if expandedRepo == result.id {
                if filesLoading && filesByRepo[result.id] == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    ForEach(filesByRepo[result.id] ?? []) { file in
                        searchFileRow(repo: result.id, file: file)
                    }
                }
            }
        }
        .padding(12).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07)))
    }

    private func searchFileRow(repo: String, file: HFFile) -> some View {
        let catalogItem = HuggingFaceSearch.catalogModel(repo: repo, file: file)
        let installed = model.downloader.isInstalled(catalogItem)
        let progress = model.downloader.progress[catalogItem.id]

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path).font(.caption).lineLimit(1).truncationMode(.middle)
                Text("\(String(format: "%.1f", file.sizeGB)) GB · 최소 메모리 \(file.estimatedMinMemoryGB) GB")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 60).tint(.opiumPurple)
            }
            actionButton(catalogItem, installed: installed, isDownloading: progress != nil)
        }
        .padding(.leading, 12).padding(.vertical, 4)
    }
}

private struct PluginDirectoryView: View {
    @Bindable var model: AgentViewModel
    private var store: PluginStore { model.plugins }
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
                                    RoundedRectangle(cornerRadius: 10).fill(Color.opiumPurple.opacity(0.14))
                                        .overlay(Image(systemName: kitSymbol(plugin))
                                            .foregroundStyle(Color.opiumPurple))
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 7) {
                                            Text(plugin.displayName).font(.headline)
                                            if plugin.isBuiltIn {
                                                Text("Opium 제공").font(.caption2.weight(.semibold)).foregroundStyle(Color.opiumPurple)
                                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                                    .background(Color.opiumPurple.opacity(0.12), in: Capsule())
                                            }
                                        }
                                        Text(plugin.summary).font(AppFont.secondary).foregroundStyle(.secondary).lineLimit(2)
                                        HStack(spacing: 6) {
                                            capability("Skill \(plugin.skillURLs.count)", active: !plugin.skillURLs.isEmpty)
                                            capability(plugin.manifest.name == "adrenaline-kit" ? "기본 도구 11" : (plugin.isBuiltIn ? "효율 프로필" : "MCP"),
                                                       active: plugin.isBuiltIn || plugin.hasMCP)
                                            capability("Hooks", active: plugin.hasHooks)
                                            if let version = plugin.manifest.version { capability("v\(version)", active: true) }
                                        }
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(get: { plugin.isEnabled },
                                                             set: { enabled in Task { await model.setPluginEnabled(enabled, for: plugin) } }))
                                        .labelsHidden().toggleStyle(.switch)
                                        .disabled(plugin.manifest.name == "adrenaline-kit")
                                    if !plugin.isBuiltIn {
                                        Menu {
                                            Button("폴더에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([plugin.rootURL]) }
                                            Divider()
                                            Button("삭제", role: .destructive) { store.uninstall(plugin) }
                                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                                    }
                                }
                                if plugin.isBuiltIn {
                                    Label(kitNote(plugin), systemImage: plugin.manifest.name == "melatonin-kit" ? "leaf.fill" : "bolt.shield.fill")
                                        .font(.caption).foregroundStyle(Color.opiumPurple)
                                } else if plugin.hasMCP || plugin.hasHooks {
                                    Label("MCP와 Hooks는 현재 자동 실행되지 않습니다.", systemImage: "shield.lefthalf.filled")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(16).background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.07)))
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("추천 MCP 연결").font(.headline)
                            Text("인기 서비스를 위한 카탈로그입니다. 계정 연결과 실제 실행은 각 MCP 설치 후 활성화됩니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(Self.catalog) { item in
                                    HStack(spacing: 10) {
                                        AsyncImage(url: item.iconURL) { image in
                                            image.resizable().scaledToFit()
                                        } placeholder: {
                                            Image(systemName: item.symbol).foregroundStyle(Color.opiumPurple)
                                        }
                                        .frame(width: 22, height: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name).font(AppFont.secondaryEmphasis)
                                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if store.isInstalled(item.id) {
                                            Text("설치됨").font(.caption2.weight(.medium)).foregroundStyle(Color.opiumPurple)
                                        } else {
                                            Button("설치") {
                                                store.installFromCatalog(name: item.id, displayName: item.name,
                                                                         summary: item.detail,
                                                                         documentationURL: item.documentation.absoluteString)
                                            }.buttonStyle(.bordered).controlSize(.small).tint(.opiumPurple)
                                        }
                                    }
                                    .padding(11).background(Color.opiumPurple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding(16).background(.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
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

    private func kitSymbol(_ plugin: InstalledPlugin) -> String {
        switch plugin.manifest.name {
        case "adrenaline-kit": "syringe.fill"
        case "caffeine-kit": "cup.and.saucer.fill"
        case "melatonin-kit": "moon.zzz.fill"
        default: "puzzlepiece.extension.fill"
        }
    }

    private func kitNote(_ plugin: InstalledPlugin) -> String {
        switch plugin.manifest.name {
        case "caffeine-kit": "불필요한 설명과 도구 호출을 줄여 토큰을 절약합니다."
        case "melatonin-kit": "16K 컨텍스트와 제한된 CPU 스레드로 부하와 발열을 낮춥니다."
        default: "Opium 보안 정책과 활동 로그를 통해 항상 안전하게 실행됩니다."
        }
    }

    private struct CatalogItem: Identifiable {
        let id: String, name: String, detail: String, symbol: String
        let domain: String
        let documentation: URL
        var iconURL: URL? { URL(string: "https://\(domain)/favicon.ico") }
    }

    private static let catalog = [
        CatalogItem(id: "gmail", name: "Gmail", detail: "메일 검색·요약·초안", symbol: "envelope.fill", domain: "mail.google.com", documentation: URL(string: "https://developers.google.com/gmail/api")!),
        CatalogItem(id: "google-drive", name: "Google Drive", detail: "파일 검색·문서 읽기", symbol: "externaldrive.fill", domain: "drive.google.com", documentation: URL(string: "https://developers.google.com/drive")!),
        CatalogItem(id: "google-calendar", name: "Google Calendar", detail: "일정 조회·생성", symbol: "calendar", domain: "calendar.google.com", documentation: URL(string: "https://developers.google.com/calendar")!),
        CatalogItem(id: "notion", name: "Notion", detail: "페이지·데이터베이스", symbol: "doc.text.fill", domain: "www.notion.so", documentation: URL(string: "https://developers.notion.com")!),
        CatalogItem(id: "github", name: "GitHub", detail: "저장소·이슈·PR", symbol: "chevron.left.forwardslash.chevron.right", domain: "github.com", documentation: URL(string: "https://docs.github.com")!),
        CatalogItem(id: "slack", name: "Slack", detail: "채널 검색·메시지", symbol: "number", domain: "slack.com", documentation: URL(string: "https://api.slack.com")!),
        CatalogItem(id: "linear", name: "Linear", detail: "이슈·프로젝트 관리", symbol: "line.3.horizontal.decrease.circle", domain: "linear.app", documentation: URL(string: "https://developers.linear.app")!),
        CatalogItem(id: "figma", name: "Figma", detail: "디자인 파일·코멘트", symbol: "paintbrush.fill", domain: "www.figma.com", documentation: URL(string: "https://www.figma.com/developers/api")!),
        CatalogItem(id: "dropbox", name: "Dropbox", detail: "클라우드 파일", symbol: "shippingbox.fill", domain: "www.dropbox.com", documentation: URL(string: "https://www.dropbox.com/developers")!),
        CatalogItem(id: "postgresql", name: "PostgreSQL", detail: "스키마·쿼리", symbol: "cylinder.fill", domain: "www.postgresql.org", documentation: URL(string: "https://www.postgresql.org/docs/")!),
        CatalogItem(id: "sentry", name: "Sentry", detail: "오류·성능 분석", symbol: "exclamationmark.triangle.fill", domain: "sentry.io", documentation: URL(string: "https://docs.sentry.io")!),
        CatalogItem(id: "stripe", name: "Stripe", detail: "결제 데이터 조회", symbol: "creditcard.fill", domain: "stripe.com", documentation: URL(string: "https://docs.stripe.com")!)
    ]
}

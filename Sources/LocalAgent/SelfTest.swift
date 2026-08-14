import Foundation

enum SelfTest {
    @MainActor
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: file)
        let data = try JSONSerialization.data(withJSONObject: ["path": file.path])
        let arguments = String(decoding: data, as: UTF8.self)
        let result = try FileTools.run(.init(id: "1", name: "read_file", arguments: arguments))
        precondition(result == "hello")
        precondition(!FileTools.requiresApproval("read_file"))
        precondition(FileTools.requiresApproval("move_file"))
        precondition(FileTools.requiresApproval("trash_file"))
        precondition(FileTools.requiresApproval("write_file"))
        precondition(FileTools.requiresApproval("run_command"))
        precondition(FileTools.normalizedPath(file.path + " \u{D3F4}\u{B354}") == file.path)
        precondition(FileTools.normalizedPath("/runner/webpage_test/index.html", workspace: directory.path)
                     == directory.appending(path: "webpage_test/index.html").path)
        let nested = directory.appending(path: "site/assets/app.js")
        let nestedArguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": "/workspace/site/assets/app.js", "content": "ok"
        ]), as: UTF8.self)
        _ = try FileTools.run(.init(id: "nested", name: "write_file", arguments: nestedArguments), workspace: directory.path)
        precondition(FileManager.default.fileExists(atPath: nested.path))
        let updateArguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": "/workspace/site/assets/app.js", "content": "ok\nnext"
        ]), as: UTF8.self)
        let updateCall = PendingToolCall(id: "diff", name: "write_file", arguments: updateArguments)
        let stat = FileTools.changeStat(for: updateCall, workspace: directory.path)
        precondition(stat?.additions == 1 && stat?.deletions == 0)
        let toolArguments = String(decoding: try JSONSerialization.data(withJSONObject: ["path": file.path]), as: UTF8.self)
        let toolPaths = FileTools.paths(in: .init(id: "paths", name: "read_file", arguments: toolArguments))
        precondition(toolPaths == [file.path])
        let writeCall = PendingToolCall(id: "write", name: "write_file", arguments: toolArguments)
        precondition(FileTools.presentation(for: writeCall).title == "파일 내용 변경")

        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","role":"user","content":"hello","createdAt":0}
        """
        let legacyMessage = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        precondition(legacyMessage.attachments == nil && legacyMessage.metrics == nil)

        let attachment = MessageAttachment(name: "hello.txt", path: file.path, size: 5, content: "hello")
        let encoded = try JSONEncoder().encode(ChatMessage(role: .user, content: "read", attachments: [attachment]))
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
        precondition(decoded.attachments?.first?.content == "hello")
        let toolHistory = ChatMessage(role: .tool, content: "result", toolCallID: "call-1",
                                      toolName: "list_files", toolArguments: #"{"path":"."}"#)
        let decodedToolHistory = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(toolHistory))
        precondition(decodedToolHistory.toolCallID == "call-1")
        let progressMessage = ChatMessage(role: .assistant, content: "확인하겠습니다.", isProgress: true)
        precondition(progressMessage.isProgress == true)
        let condensed = ChatMessage.visibleConversation([
            ChatMessage(role: .user, content: "폴더를 확인해줘"),
            ChatMessage(role: .assistant, content: "확인하겠습니다.", isProgress: true),
            ChatMessage(role: .tool, content: "[list_files]\na.txt"),
            ChatMessage(role: .assistant, content: "폴더에는 다음 항목이 있습니다.\n\n- a.txt")
        ], condenseCurrentTurn: true)
        precondition(condensed.count == 2 && condensed.last?.content.contains("a.txt") == true)

        let qwen38 = LocalModel(url: directory.appending(path: "Qwen3.8-27B-Q4_K_M.gguf"))
        precondition(qwen38.isQwen38 && !qwen38.isAuxiliary && qwen38.identity == "Qwen3.8")
        precondition(LocalModel(url: directory.appending(path: "mmproj-Qwen3.8-27B-Q8_0.gguf")).isAuxiliary)
        precondition(LocalModel(url: directory.appending(path: "mtp-Qwen3.8-27B-Q4_0.gguf")).isAuxiliary)
        precondition(ReasoningEffort.medium.qwenReasoningEffort == "medium")
        precondition(ReasoningEffort.ultra.qwenReasoningEffort == "xhigh")
        let meteredCall = PendingToolCall(id: "metered", name: "list_files", arguments: "{}",
                                          progress: "폴더를 확인합니다.",
                                          metrics: GenerationMetrics(promptTokens: 10, completionTokens: 5,
                                                                     tokensPerSecond: 12, elapsedSeconds: 1))
        precondition(meteredCall.progress == "폴더를 확인합니다." && meteredCall.metrics?.completionTokens == 5)
        precondition(FileTools.securityLevel(for: .init(id: "safe", name: "read_file", arguments: toolArguments),
                                             workspace: directory.path) == .normal)
        let sshArguments = String(decoding: try JSONSerialization.data(withJSONObject: [
            "path": FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config").path
        ]), as: UTF8.self)
        precondition(FileTools.securityLevel(for: .init(id: "ssh", name: "read_file", arguments: sshArguments)) == .critical)
        precondition(FileTools.securityLevel(for: .init(id: "shell", name: "run_command", arguments: "{}")) == .critical)
        let serverCall = PendingToolCall(id: "server", name: "run_command", arguments: #"{"command":"python3 -m http.server 8000 & open -a Safari http://localhost:8000","working_directory":"/tmp"}"#)
        precondition(FileTools.liveTitle(for: serverCall) == "로컬 서버를 시작하고 Safari에서 여는 중")
        precondition(ResourceMonitor.gpuUsage(from: #""PerformanceStatistics" = {"Device Utilization %"=73}"#) == 0.73)
        let searchHTML = #"<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&amp;rut=x">Example &amp; Test</a>"#
        let searchResults = FileTools.searchResults(from: searchHTML, limit: 5)
        precondition(searchResults.first?.title == "Example & Test" && searchResults.first?.url == "https://example.com")
        let listBlocks = MarkdownBlock.parse("- index.html\n- server.log")
        guard case .bullets(let listItems) = listBlocks.first else { preconditionFailure("목록이 카드 단위로 묶이지 않았습니다.") }
        precondition(listItems == ["index.html", "server.log"])

        let pluginRoot = directory.appending(path: "sample-plugin")
        let manifestDirectory = pluginRoot.appending(path: ".codex-plugin")
        let skillDirectory = pluginRoot.appending(path: "skills/concise")
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try Data(#"{"name":"sample-plugin","version":"1.0.0","description":"test","skills":"./skills/"}"#.utf8)
            .write(to: manifestDirectory.appending(path: "plugin.json"))
        try Data("---\nname: concise\n---\nBe concise.".utf8).write(to: skillDirectory.appending(path: "SKILL.md"))
        let plugin = try PluginStore.loadPlugin(at: pluginRoot, enabled: true)
        precondition(plugin.manifest.name == "sample-plugin" && plugin.skillURLs.count == 1 && plugin.isEnabled)
        try Data(#"{"name":"unsafe-plugin","skills":"../../"}"#.utf8)
            .write(to: manifestDirectory.appending(path: "plugin.json"))
        do {
            _ = try PluginStore.loadPlugin(at: pluginRoot, enabled: false)
            preconditionFailure("플러그인 외부 경로가 거절되어야 합니다.")
        } catch { }
        print("Self-test passed")
    }
}

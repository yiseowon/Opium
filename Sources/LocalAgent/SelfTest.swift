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

        let qwen38 = LocalModel(url: directory.appending(path: "Qwen3.8-27B-Q4_K_M.gguf"))
        precondition(qwen38.isQwen38 && !qwen38.isAuxiliary && qwen38.identity == "Qwen3.8")
        precondition(LocalModel(url: directory.appending(path: "mmproj-Qwen3.8-27B-Q8_0.gguf")).isAuxiliary)
        precondition(LocalModel(url: directory.appending(path: "mtp-Qwen3.8-27B-Q4_0.gguf")).isAuxiliary)
        precondition(ReasoningEffort.medium.qwenReasoningEffort == "medium")
        precondition(ReasoningEffort.ultra.qwenReasoningEffort == "xhigh")

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

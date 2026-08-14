import AppKit
import Foundation

enum FileTools {
    static func requiresApproval(_ name: String) -> Bool {
        ["write_file", "create_directory", "move_file", "trash_file", "run_command"].contains(name)
    }

    static func presentation(for call: PendingToolCall) -> (title: String, target: String, impact: String) {
        let arguments = decodedArguments(call.arguments)
        let target = paths(in: call).joined(separator: " → ")
        switch call.name {
        case "write_file": return ("파일 내용 변경", target, "이 파일의 기존 내용을 새 내용으로 교체합니다.")
        case "create_directory": return ("폴더 생성", target, "새 폴더와 필요한 상위 폴더를 만듭니다.")
        case "move_file": return ("파일 이동", target, "원본 파일의 위치가 변경됩니다.")
        case "trash_file": return ("휴지통으로 이동", target, "Finder 휴지통에서 복구할 수 있습니다.")
        case "run_command": return ("터미널 명령 실행", arguments["working_directory"] ?? "터미널", arguments["command"] ?? call.arguments)
        case "search_mail": return ("메일 검색", arguments["query"] ?? "최근 메일", "Apple Mail에서 읽기만 수행합니다.")
        case "fetch_url": return ("웹페이지 읽기", arguments["url"] ?? "웹", "페이지 내용을 읽고 변경하지 않습니다.")
        default: return (call.name, target.isEmpty ? call.arguments : target, "이 작업을 실행합니다.")
        }
    }

    static func changeStat(for call: PendingToolCall, workspace: String? = nil) -> FileChangeStat? {
        guard call.name == "write_file" else { return nil }
        let arguments = decodedArguments(call.arguments)
        guard let rawPath = arguments["path"], let newContent = arguments["content"] else { return nil }
        let path = normalizedPath(rawPath, workspace: workspace)
        let oldContent = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let newLines = newContent.isEmpty ? [] : newContent.components(separatedBy: .newlines)
        let oldLines = oldContent.isEmpty ? [] : oldContent.components(separatedBy: .newlines)
        let difference = newLines.difference(from: oldLines)
        var additions = 0
        var deletions = 0
        for change in difference {
            switch change {
            case .insert: additions += 1
            case .remove: deletions += 1
            }
        }
        return FileChangeStat(path: path, additions: additions, deletions: deletions)
    }

    static func run(_ call: PendingToolCall, workspace: String? = nil) throws -> String {
        guard let data = call.arguments.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw AgentError.message("도구 인자를 해석할 수 없습니다: \(call.arguments)")
        }
        switch call.name {
        case "search_files":
            let path = try value("path", in: arguments, workspace: workspace)
            let query = try string("query", in: arguments).lowercased()
            guard let enumerator = FileManager.default.enumerator(atPath: path) else {
                throw AgentError.message("Folder does not exist: \(path)")
            }
            return enumerator.compactMap { $0 as? String }
                .filter { URL(fileURLWithPath: $0).lastPathComponent.lowercased().contains(query) }
                .prefix(500).joined(separator: "\n")
        case "list_files":
            let path = try value("path", in: arguments, workspace: workspace)
            return try FileManager.default.contentsOfDirectory(atPath: path).sorted().joined(separator: "\n")
        case "read_file":
            let path = try value("path", in: arguments, workspace: workspace)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else {
                throw AgentError.message("1MB 이하 UTF-8 텍스트 파일만 읽을 수 있습니다.")
            }
            return text
        case "write_file":
            let path = try value("path", in: arguments, workspace: workspace)
            let content = try string("content", in: arguments)
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            return "Wrote \(content.utf8.count) bytes: \(path)"
        case "create_directory":
            let path = try value("path", in: arguments, workspace: workspace)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return "Created directory: \(path)"
        case "move_file":
            let source = try value("source", in: arguments, workspace: workspace)
            let destination = try value("destination", in: arguments, workspace: workspace)
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: destination).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            return "이동 완료: \(source) → \(destination)"
        case "trash_file":
            let path = try value("path", in: arguments, workspace: workspace)
            var resulting: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
            return "휴지통으로 이동했습니다: \(path)"
        case "run_command":
            let command = try string("command", in: arguments)
            let workingDirectory = try value("working_directory", in: arguments, workspace: workspace)
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data.prefix(100_000), as: UTF8.self)
            return "Exit code: \(process.terminationStatus)\n\(output)"
        case "search_mail":
            return try searchMail(query: try string("query", in: arguments), limit: Int(arguments["limit"] ?? "20") ?? 20)
        case "fetch_url":
            let rawURL = try string("url", in: arguments)
            guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw AgentError.message("HTTP 또는 HTTPS 주소가 필요합니다.")
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000 else { throw AgentError.message("웹페이지가 2MB를 넘습니다.") }
            return String(decoding: data, as: UTF8.self)
        default:
            throw AgentError.message("지원하지 않는 도구입니다: \(call.name)")
        }
    }

    static func paths(in call: PendingToolCall, workspace: String? = nil) -> [String] {
        let arguments = decodedArguments(call.arguments)
        return ["path", "source", "destination", "working_directory"]
            .compactMap { arguments[$0] }
            .map { normalizedPath($0, workspace: workspace) }
            .filter { $0.hasPrefix("/") }
    }

    private static func decodedArguments(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    private static func searchMail(query: String, limit: Int) throws -> String {
        let script = """
        on run argv
          set needle to item 1 of argv
          set maxItems to (item 2 of argv) as integer
          tell application "Mail"
            set foundMessages to (messages of inbox whose subject contains needle)
            set output to ""
            set messageCount to count of foundMessages
            if messageCount > maxItems then set messageCount to maxItems
            repeat with i from 1 to messageCount
              set m to item i of foundMessages
              set bodyText to content of m
              if (length of bodyText) > 2000 then set bodyText to text 1 thru 2000 of bodyText
              set output to output & "제목: " & subject of m & linefeed & "보낸 사람: " & sender of m & linefeed & "날짜: " & (date received of m as string) & linefeed & "내용: " & bodyText & linefeed & linefeed
            end repeat
            return output
          end tell
        end run
        """
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, query, String(min(max(limit, 1), 50))]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AgentError.message("Mail 접근 실패: \(output)") }
        return output.isEmpty ? "검색 결과가 없습니다." : output
    }

    private static func value(_ key: String, in arguments: [String: String], workspace: String?) throws -> String {
        guard let rawValue = arguments[key] else {
            throw AgentError.message("\(key)에 절대 경로가 필요합니다.")
        }
        let value = normalizedPath(rawValue, workspace: workspace)
        guard value.hasPrefix("/") else { throw AgentError.message("Absolute path required for \(key)") }
        return value
    }

    static func normalizedPath(_ rawValue: String, workspace: String? = nil) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
        let suffixes = [" folder", " directory", " \u{D3F4}\u{B354}", " \u{B514}\u{B809}\u{D1A0}\u{B9AC}"]
        for suffix in suffixes where value.lowercased().hasSuffix(suffix) {
            value.removeLast(suffix.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let workspace {
            if value == "/runner" || value == "/workspace" {
                value = workspace
            } else if value.hasPrefix("/runner/") {
                value = URL(fileURLWithPath: workspace).appending(path: String(value.dropFirst(8))).path
            } else if value.hasPrefix("/workspace/") {
                value = URL(fileURLWithPath: workspace).appending(path: String(value.dropFirst(11))).path
            } else if !value.hasPrefix("/") {
                value = URL(fileURLWithPath: workspace).appending(path: value).path
            }
        }
        let variants = [value, value.precomposedStringWithCanonicalMapping, value.decomposedStringWithCanonicalMapping]
        return variants.first(where: FileManager.default.fileExists(atPath:)) ?? value
    }

    private static func string(_ key: String, in arguments: [String: String]) throws -> String {
        guard let value = arguments[key] else { throw AgentError.message("Missing argument: \(key)") }
        return value
    }
}

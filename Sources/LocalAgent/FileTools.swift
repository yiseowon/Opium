import AppKit
import Foundation

enum FileTools {
    static func securityLevel(for call: PendingToolCall, workspace: String? = nil) -> SecurityLevel {
        if call.name == "run_command" || call.name == "trash_file" { return .critical }
        if call.name == "search_mail" || call.name == "fetch_url" || call.name == "web_search" { return .sensitive }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let workspacePath = workspace.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let critical = ["/.ssh", "/.gnupg", "/Library/Keychains", "/Library/Mail", "/Library/Messages"]
        let sensitive = ["/Desktop", "/Documents", "/Downloads", "/Pictures", "/Movies", "/Music", "/Library"]
        for path in paths(in: call, workspace: workspace).map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) {
            if let workspacePath, path == workspacePath || path.hasPrefix(workspacePath + "/") { continue }
            if critical.contains(where: { path == home + $0 || path.hasPrefix(home + $0 + "/") })
                || ["/System", "/Library", "/private", "/etc"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return .critical
            }
            if sensitive.contains(where: { path == home + $0 || path.hasPrefix(home + $0 + "/") }) { return .sensitive }
            if !path.hasPrefix(home + "/") && path != home { return .critical }
        }
        return .normal
    }

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
        case "web_search": return ("웹 검색", arguments["query"] ?? "검색어", "공개 검색 결과의 제목과 주소를 읽습니다.")
        default: return (call.name, target.isEmpty ? call.arguments : target, "이 작업을 실행합니다.")
        }
    }

    static func liveTitle(for call: PendingToolCall) -> String {
        let arguments = decodedArguments(call.arguments)
        guard call.name == "run_command" else {
            return ["read_file": "파일 읽는 중", "list_files": "폴더 확인 중", "search_files": "파일 검색 중",
                    "write_file": "파일 수정 중", "create_directory": "폴더 생성 중", "move_file": "파일 이동 중",
                    "trash_file": "휴지통으로 이동 중", "search_mail": "메일 검색 중",
                    "fetch_url": "웹페이지 확인 중", "web_search": "웹 검색 중"][call.name] ?? "도구 실행 중"
        }

        let command = (arguments["command"] ?? "").lowercased()
        let server = command.contains("http.server") || command.contains("python -m http")
        let safari = command.contains("safari") || command.contains("open http")
        let stopping = command.contains("pkill") || command.contains("kill ") || command.contains("killall")
        if server && safari { return stopping ? "로컬 서버를 종료하고 Safari를 정리하는 중" : "로컬 서버를 시작하고 Safari에서 여는 중" }
        if server { return stopping ? "로컬 서버 종료 중" : "로컬 서버 시작 중" }
        if safari { return command.contains("close") || command.contains("quit") ? "Safari 창 닫는 중" : "Safari에서 여는 중" }
        return "터미널 명령 실행 중"
    }

    static func changeStat(for call: PendingToolCall, workspace: String? = nil) -> FileChangeStat? {
        guard call.name == "write_file" else { return nil }
        let arguments = decodedArguments(call.arguments)
        guard let rawPath = arguments["path"], let newContent = arguments["content"] else { return nil }
        let path = normalizedPath(rawPath, workspace: workspace)
        let oldContent = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let newLines = lines(in: newContent)
        let oldLines = lines(in: oldContent)
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

    static func liveChangeStat(arguments: String, workspace: String? = nil) -> FileChangeStat? {
        guard let rawPath = partialJSONString(named: "path", in: arguments, requireClosingQuote: true),
              let newContent = partialJSONString(named: "content", in: arguments) else { return nil }
        let path = normalizedPath(rawPath, workspace: workspace)
        let oldContent = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let newLines = lines(in: newContent)
        let oldLines = lines(in: oldContent)
        let difference = newLines.difference(from: Array(oldLines.prefix(newLines.count)))
        var additions = 0, deletions = 0
        for change in difference {
            if case .insert = change { additions += 1 } else { deletions += 1 }
        }
        return FileChangeStat(path: path, additions: additions, deletions: deletions)
    }

    private static func partialJSONString(named key: String, in json: String,
                                          requireClosingQuote: Bool = false) -> String? {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        while index < json.endIndex, json[index].isWhitespace || json[index] == ":" { index = json.index(after: index) }
        guard index < json.endIndex, json[index] == "\"" else { return nil }
        index = json.index(after: index)
        var result = "", escaped = false, closed = false
        while index < json.endIndex {
            let character = json[index]
            index = json.index(after: index)
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\"", "\\", "/": result.append(character)
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" { escaped = true }
            else if character == "\"" { closed = true; break }
            else { result.append(character) }
        }
        return requireClosingQuote && !closed ? nil : result
    }

    private static func lines(in content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") { lines.removeLast() }
        return lines
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

    static func runAsync(_ call: PendingToolCall, workspace: String? = nil) async throws -> String {
        guard call.name == "web_search" else { return try run(call, workspace: workspace) }
        let arguments = decodedArguments(call.arguments)
        let query = try string("query", in: arguments)
        let limit = min(max(Int(arguments["limit"] ?? "8") ?? 8, 1), 10)
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) Opium/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AgentError.message("웹 검색에 실패했습니다.") }
        guard data.count <= 2_000_000 else { throw AgentError.message("검색 결과가 너무 큽니다.") }
        let results = searchResults(from: String(decoding: data, as: UTF8.self), limit: limit)
        guard !results.isEmpty else { throw AgentError.message("웹 검색 결과를 찾지 못했습니다.") }
        return results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n\($0.element.url)" }.joined(separator: "\n\n")
    }

    static func searchResults(from html: String, limit: Int) -> [(title: String, url: String)] {
        let pattern = #"<a rel="nofollow" class="result__a" href="([^"]+)">(.+?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).prefix(limit).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { return nil }
            let href = decodeHTML(String(html[hrefRange]))
            let redirect = href.hasPrefix("//") ? "https:" + href : href
            let url = URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "uddg" })?.value ?? redirect
            let title = decodeHTML(String(html[titleRange])).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            return (title, url)
        }
    }

    private static func decodeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
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

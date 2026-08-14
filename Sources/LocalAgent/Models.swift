import Foundation

struct ChatThread: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var workspacePath: String? = nil
    var updatedAt = Date()
}

struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant, tool }

    var id = UUID()
    var role: Role
    var content: String
    var reasoning: String? = nil
    var attachments: [MessageAttachment]? = nil
    var metrics: GenerationMetrics? = nil
    var toolCallID: String? = nil
    var toolName: String? = nil
    var toolArguments: String? = nil
    var isProgress: Bool? = nil
    var changedFiles: [String]? = nil
    var changeStats: [FileChangeStat]? = nil
    var createdAt = Date()

    static func visibleConversation(_ messages: [Self], condenseCurrentTurn: Bool) -> [Self] {
        var turns: [[Self]] = []
        for message in messages {
            if message.role == .user || turns.isEmpty { turns.append([message]) }
            else { turns[turns.count - 1].append(message) }
        }
        return turns.enumerated().flatMap { index, turn in
            let shouldCondense = index < turns.count - 1 || condenseCurrentTurn
            let hasFinal = turn.contains { $0.role == .assistant && $0.isProgress != true && !$0.content.isEmpty }
            guard shouldCondense && hasFinal else { return turn }
            return turn.filter { $0.role != .tool && $0.isProgress != true }
        }
    }
}

struct FileChangeStat: Codable, Hashable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let additions: Int
    let deletions: Int
}

struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    let name: String
    let path: String
    let size: Int
    let content: String

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

struct GenerationMetrics: Codable, Hashable, Sendable {
    var promptTokens = 0
    var completionTokens = 0
    var tokensPerSecond = 0.0
    var elapsedSeconds = 0.0
    var thinkingSeconds: Double? = nil
}

struct AgentActivity: Identifiable, Hashable, Sendable {
    let id = UUID()
    let title: String
    let detail: String?
    let symbol: String
    let date = Date()
    var isActive = false
    var securityLevel: SecurityLevel? = nil
    var outcome: String? = nil
}

enum SecurityLevel: Int, Codable, Hashable, Sendable {
    case normal = 1
    case sensitive = 2
    case critical = 3

    var title: String { "레벨 \(rawValue)" }
}

struct ResourceSnapshot: Sendable {
    var appBytes: UInt64 = 0
    var modelBytes: UInt64 = 0
    var systemUsedBytes: UInt64 = 0
    var physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    var history: [Double] = []
    var cpuUsage: Double = 0
    var gpuUsage: Double? = nil
    var thermalState = "정상"
}

struct LocalModel: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var displayName: String {
        name.replacingOccurrences(of: "-Instruct", with: "")
            .replacingOccurrences(of: "-Q4_K_M", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }
    var fileSize: UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
    }
    var quantization: String {
        name.firstMatch(of: /Q\d(?:_[A-Z0-9]+)*/).map { String($0.output) } ?? "GGUF"
    }
    var isAuxiliary: Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("mmproj-") || lower.hasPrefix("mtp-")
    }
    var isQwen38: Bool { name.lowercased().contains("qwen3.8") }
    var identity: String { isQwen38 ? "Qwen3.8" : name }
}

enum ReasoningEffort: String, CaseIterable, Identifiable, Codable {
    case feather = "Feather"
    case light = "Light"
    case medium = "Medium"
    case high = "High"
    case extraHigh = "Extra High"
    case ultra = "Ultra"

    var id: Self { self }
    var maxTokens: Int {
        switch self {
        case .feather: 512
        case .light: 1_024
        case .medium: 2_048
        case .high: 4_096
        case .extraHigh: 6_144
        case .ultra: 8_192
        }
    }
    var usesThinking: Bool { self != .feather && self != .light }
    var qwenReasoningEffort: String {
        switch self {
        case .feather, .light: "low"
        case .medium, .high: "medium"
        case .extraHigh, .ultra: "xhigh"
        }
    }
    var instruction: String {
        switch self {
        case .feather: "Respond immediately with the minimum sufficient work."
        case .light: "Use a brief check and keep the response lightweight."
        case .medium: "Reason normally and verify important claims."
        case .high: "Inspect carefully, consider edge cases, and verify the result."
        case .extraHigh: "Perform a thorough implementation and validation pass."
        case .ultra: "Use maximum available reasoning, inspect alternatives, and verify comprehensively."
        }
    }
}

struct PendingToolCall: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String
    var progress: String? = nil
    var metrics: GenerationMetrics? = nil
}

enum ModelEvent: Sendable {
    case text(String)
    case reasoning(String)
    case usage(GenerationMetrics)
    case toolCallProgress(name: String, arguments: String)
    case toolCall(id: String, name: String, arguments: String)
    case completed
}

struct ToolDefinition: Encodable {
    let type = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }
}

struct JSONSchema: Encodable {
    let type: String
    var properties: [String: Property]? = nil
    var required: [String]? = nil

    struct Property: Encodable {
        let type: String
        let description: String
    }
}

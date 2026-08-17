import AppKit
import Foundation
import Observation

enum ToolPolicy: String, CaseIterable, Codable, Identifiable {
    case askEveryTime
    case safeReads
    case trustedFolders
    case fullAccess

    var id: Self { self }
    var title: String {
        switch self {
        case .askEveryTime: "항상 확인"
        case .safeReads: "읽기는 자동"
        case .trustedFolders: "작업 폴더"
        case .fullAccess: "전체 액세스"
        }
    }
    var detail: String {
        switch self {
        case .askEveryTime: "모든 파일 작업 전에 물어봅니다."
        case .safeReads: "읽기와 검색은 자동, 변경은 확인합니다."
        case .trustedFolders: "신뢰 폴더 안의 파일 변경은 자동 허용합니다."
        case .fullAccess: "파일 변경과 터미널 명령을 확인 없이 실행합니다."
        }
    }
}

@MainActor @Observable
final class PermissionStore {
    var policy: ToolPolicy { didSet { save() } }
    var trustedFolders: [String] { didSet { save() } }
    var computerUseEnabled: Bool { didSet { save() } }

    private let defaults = UserDefaults.standard

    init() {
        policy = ToolPolicy(rawValue: defaults.string(forKey: "toolPolicy") ?? "") ?? .safeReads
        trustedFolders = defaults.stringArray(forKey: "trustedFolders") ?? []
        computerUseEnabled = defaults.bool(forKey: "computerUseEnabled")
    }

    /// Computer-use tools follow the same policy as everything else, with one
    /// exception: "safeReads" and "trustedFolders" never auto-approve them (clicking
    /// around the screen isn't a "safe read" or scoped to a folder the way file edits
    /// are). "전체 액세스" means full access, including this.
    func allows(_ call: PendingToolCall, workspace: String? = nil) -> Bool {
        if ComputerUse.toolNames.contains(call.name) { return policy == .fullAccess }
        switch policy {
        case .askEveryTime:
            return false
        case .safeReads:
            return !FileTools.requiresApproval(call.name)
        case .trustedFolders:
            guard FileTools.requiresApproval(call.name) else { return true }
            guard call.name != "run_command" else { return false }
            let paths = FileTools.paths(in: call, workspace: workspace)
            return !paths.isEmpty && paths.allSatisfy(isTrusted)
        case .fullAccess:
            return true
        }
    }

    func trustFolder(for call: PendingToolCall) {
        guard let path = FileTools.paths(in: call).first else { return }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let folder = exists && isDirectory.boolValue ? path : url.deletingLastPathComponent().path
        add(folder)
        policy = .trustedFolders
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Opium이 자동으로 변경할 수 있는 폴더를 선택하세요."
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { add($0.path) }
    }

    func remove(_ path: String) { trustedFolders.removeAll { $0 == path } }

    private func add(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if !trustedFolders.contains(normalized) { trustedFolders.append(normalized) }
    }

    private func isTrusted(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return trustedFolders.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    private func save() {
        defaults.set(policy.rawValue, forKey: "toolPolicy")
        defaults.set(trustedFolders, forKey: "trustedFolders")
        defaults.set(computerUseEnabled, forKey: "computerUseEnabled")
    }
}

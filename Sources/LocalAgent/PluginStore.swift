import AppKit
import Foundation
import Observation

struct PluginManifest: Codable {
    struct Interface: Codable {
        var displayName: String?
        var shortDescription: String?
        var developerName: String?
        var category: String?
        var brandColor: String?
        var logo: String?
    }

    let name: String
    var version: String?
    var description: String?
    var skills: String?
    var mcpServers: String?
    var hooks: String?
    var interface: Interface?
}

struct InstalledPlugin: Identifiable, Hashable {
    var id: String { manifest.name }
    let manifest: PluginManifest
    let rootURL: URL
    let skillURLs: [URL]
    let hasMCP: Bool
    let hasHooks: Bool
    var isEnabled: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(isEnabled) }
    var displayName: String { manifest.interface?.displayName ?? manifest.name }
    var summary: String { manifest.interface?.shortDescription ?? manifest.description ?? "설명이 없는 플러그인" }
}

@MainActor @Observable
final class PluginStore {
    var plugins: [InstalledPlugin] = []
    var errorMessage: String?
    private let directory: URL
    private let enabledKey = "enabledOpiumPlugins"

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Opium/Plugins", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        discover()
    }

    func discover() {
        let enabled = Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
        let roots = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        plugins = roots.compactMap { try? Self.loadPlugin(at: $0, enabled: enabled.contains($0.lastPathComponent)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = ".codex-plugin/plugin.json이 있는 플러그인 폴더를 선택하세요."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do { try install(from: source) }
        catch { errorMessage = error.localizedDescription }
    }

    func install(from source: URL) throws {
        let plugin = try Self.loadPlugin(at: source, enabled: false)
        guard plugin.manifest.name.range(of: #"^[a-z0-9][a-z0-9-]{1,63}$"#, options: .regularExpression) != nil else {
            throw AgentError.message("플러그인 name은 소문자·숫자·하이픈만 사용해야 합니다.")
        }
        try Self.validateContents(source)
        let destination = directory.appending(path: plugin.manifest.name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AgentError.message("이미 설치된 플러그인입니다: \(plugin.manifest.name)")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        discover()
    }

    func setEnabled(_ enabled: Bool, for plugin: InstalledPlugin) {
        var names = Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
        if enabled { names.insert(plugin.manifest.name) } else { names.remove(plugin.manifest.name) }
        UserDefaults.standard.set(Array(names), forKey: enabledKey)
        discover()
    }

    func uninstall(_ plugin: InstalledPlugin) {
        do {
            setEnabled(false, for: plugin)
            _ = try FileManager.default.trashItem(at: plugin.rootURL, resultingItemURL: nil)
            discover()
        } catch { errorMessage = error.localizedDescription }
    }

    var enabledInstructions: String {
        var remaining = 60_000
        return plugins.filter(\.isEnabled).compactMap { plugin in
            let bodies = plugin.skillURLs.compactMap { url -> String? in
                guard remaining > 0, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let clipped = String(text.prefix(min(remaining, 20_000)))
                remaining -= clipped.count
                return "### \(url.deletingLastPathComponent().lastPathComponent)\n\(clipped)"
            }
            guard !bodies.isEmpty else { return nil }
            return "## Plugin: \(plugin.displayName)\n" + bodies.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    static func loadPlugin(at root: URL, enabled: Bool) throws -> InstalledPlugin {
        let manifestURL = root.appending(path: ".codex-plugin/plugin.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let skillsRoot = try componentURL(in: root, path: manifest.skills, defaultPath: "skills")
        let skillURLs = ((try? FileManager.default.contentsOfDirectory(at: skillsRoot, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])) ?? [])
            .map { $0.appending(path: "SKILL.md") }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let mcpURL = try componentURL(in: root, path: manifest.mcpServers, defaultPath: ".mcp.json")
        let hooksURL = try componentURL(in: root, path: manifest.hooks, defaultPath: "hooks/hooks.json")
        return InstalledPlugin(manifest: manifest, rootURL: root, skillURLs: skillURLs,
                               hasMCP: FileManager.default.fileExists(atPath: mcpURL.path),
                               hasHooks: FileManager.default.fileExists(atPath: hooksURL.path),
                               isEnabled: enabled)
    }

    private static func componentURL(in root: URL, path: String?, defaultPath: String) throws -> URL {
        let relative = (path ?? defaultPath).hasPrefix("./") ? String((path ?? defaultPath).dropFirst(2)) : (path ?? defaultPath)
        let rootPath = root.standardizedFileURL.path + "/"
        let candidate = root.appending(path: relative).standardizedFileURL
        guard candidate.path.hasPrefix(rootPath) else {
            throw AgentError.message("플러그인 구성 경로는 플러그인 폴더 밖을 가리킬 수 없습니다.")
        }
        return candidate
    }

    private static func validateContents(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw AgentError.message("플러그인 폴더를 읽을 수 없습니다.")
        }
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw AgentError.message("안전을 위해 심볼릭 링크가 포함된 플러그인은 설치할 수 없습니다.") }
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
            if total > 50_000_000 { throw AgentError.message("플러그인 크기는 50 MB를 넘을 수 없습니다.") }
        }
    }
}

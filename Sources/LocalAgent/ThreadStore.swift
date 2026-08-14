import Foundation
import Observation

@MainActor @Observable
final class ThreadStore {
    var threads: [ChatThread] = []
    var selectedID: UUID?

    private let fileURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalAgent", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "threads.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([ChatThread].self, from: data) {
            threads = saved
            selectedID = saved.first?.id
            for index in threads.indices where threads[index].workspacePath == nil {
                threads[index].workspacePath = makeWorkspace(for: threads[index].id)
            }
            save()
        } else {
            newThread()
        }
    }

    var selectedIndex: Int? { threads.firstIndex { $0.id == selectedID } }
    var selected: ChatThread? { selectedIndex.map { threads[$0] } }
    var selectedWorkspacePath: String { selected?.workspacePath ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "LLM").path }
    var totalUsage: GenerationMetrics {
        threads.flatMap(\.messages).compactMap(\.metrics).reduce(into: GenerationMetrics()) { total, item in
            total.promptTokens += item.promptTokens
            total.completionTokens += item.completionTokens
            total.elapsedSeconds += item.elapsedSeconds
        }
    }

    func newThread() {
        let id = UUID()
        let thread = ChatThread(id: id, title: "새 작업", workspacePath: makeWorkspace(for: id))
        threads.insert(thread, at: 0)
        selectedID = thread.id
        save()
    }

    func append(_ message: ChatMessage) {
        guard let index = selectedIndex else { return }
        threads[index].messages.append(message)
        threads[index].updatedAt = .now
        save()
    }

    func setTitle(_ title: String, for id: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].title = title
        save()
    }

    func updateLastAssistant(text: String? = nil, reasoning: String? = nil,
                             metrics: GenerationMetrics? = nil, changedFiles: [String]? = nil,
                             changeStats: [FileChangeStat]? = nil, persist: Bool = true) {
        guard let index = selectedIndex,
              let messageIndex = threads[index].messages.lastIndex(where: { $0.role == .assistant }) else { return }
        if let text { threads[index].messages[messageIndex].content += text }
        if let reasoning {
            threads[index].messages[messageIndex].reasoning =
                (threads[index].messages[messageIndex].reasoning ?? "") + reasoning
        }
        if let metrics { threads[index].messages[messageIndex].metrics = metrics }
        if let changedFiles { threads[index].messages[messageIndex].changedFiles = changedFiles }
        if let changeStats { threads[index].messages[messageIndex].changeStats = changeStats }
        if persist { save() }
    }

    func discardLastAssistantDraft() {
        guard let index = selectedIndex, threads[index].messages.last?.role == .assistant else { return }
        threads[index].messages.removeLast()
        save()
    }

    func flush() { save() }

    func delete(_ ids: Set<UUID>) {
        threads.removeAll { ids.contains($0.id) }
        if !threads.contains(where: { $0.id == selectedID }) { selectedID = threads.first?.id }
        if threads.isEmpty { newThread() } else { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(threads) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func makeWorkspace(for id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd/HHmmss"
        let relative = formatter.string(from: .now) + "-" + id.uuidString.prefix(6)
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "LLM").appending(path: relative)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}

import Foundation
import Observation

@MainActor @Observable
final class ModelDownloader: NSObject {
    var progress: [String: Double] = [:]
    var downloading: Set<String> = []
    var errorMessage: String?
    var onModelInstalled: (() -> Void)?

    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private let modelsDirectory: URL
    @ObservationIgnored private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    override init() {
        modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalAgent/Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        super.init()
    }

    func isInstalled(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: modelsDirectory.appending(path: model.filename).path)
    }

    func start(_ model: CatalogModel) {
        guard !downloading.contains(model.id) else { return }
        downloading.insert(model.id)
        progress[model.id] = 0
        let task = session.downloadTask(with: model.url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: CatalogModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        downloading.remove(model.id)
        progress[model.id] = nil
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in self?.progress[id] = fraction }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription,
              let model = ModelCatalog.all.first(where: { $0.id == id }) else { return }
        let destinationDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalAgent/Models", directoryHint: .isDirectory)
        let destination = destinationDirectory.appending(path: model.filename)
        let temporaryCopy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".gguf")
        do {
            try FileManager.default.copyItem(at: location, to: temporaryCopy)
        } catch {
            Task { @MainActor [weak self] in self?.errorMessage = error.localizedDescription }
            return
        }
        Task { @MainActor [weak self] in
            defer { try? FileManager.default.removeItem(at: temporaryCopy) }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryCopy, to: destination)
                self?.downloading.remove(id)
                self?.progress[id] = nil
                self?.onModelInstalled?()
            } catch {
                self?.downloading.remove(id)
                self?.progress[id] = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor [weak self] in
            self?.downloading.remove(id)
            self?.progress[id] = nil
            self?.errorMessage = error.localizedDescription
        }
    }
}

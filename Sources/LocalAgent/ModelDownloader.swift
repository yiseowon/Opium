import Foundation
import Observation

@MainActor @Observable
final class ModelDownloader: NSObject {
    /// Combined 0...1 progress per catalog id, weighted across the main weights file
    /// and its mmproj companion when the model is vision-capable.
    var progress: [String: Double] = [:]
    var downloading: Set<String> = []
    var errorMessage: String?
    var onModelInstalled: (() -> Void)?

    @ObservationIgnored private var bytesWritten: [String: Int64] = [:]
    @ObservationIgnored private var bytesExpected: [String: Int64] = [:]
    @ObservationIgnored private var pendingParts: [String: Int] = [:]
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
        let hasWeights = FileManager.default.fileExists(atPath: modelsDirectory.appending(path: model.filename).path)
        guard let mmproj = model.mmproj else { return hasWeights }
        return hasWeights && FileManager.default.fileExists(atPath: modelsDirectory.appending(path: mmproj.filename).path)
    }

    func start(_ model: CatalogModel) {
        guard !downloading.contains(model.id) else { return }
        downloading.insert(model.id)
        progress[model.id] = 0

        var parts: [(key: String, url: URL, filename: String, sizeBytes: Int64)] =
            [("\(model.id)::weights", model.url, model.filename, model.sizeBytes)]
        if let mmproj = model.mmproj {
            parts.append(("\(model.id)::mmproj", mmproj.url, mmproj.filename, mmproj.sizeBytes))
        }
        pendingParts[model.id] = parts.count

        for part in parts {
            bytesWritten[part.key] = 0
            bytesExpected[part.key] = part.sizeBytes
            let task = session.downloadTask(with: part.url)
            task.taskDescription = part.key
            tasks[part.key] = task
            task.resume()
        }
    }

    func cancel(_ model: CatalogModel) {
        for key in tasks.keys where key.hasPrefix("\(model.id)::") {
            tasks[key]?.cancel()
            tasks[key] = nil
            bytesWritten[key] = nil
            bytesExpected[key] = nil
        }
        pendingParts[model.id] = nil
        downloading.remove(model.id)
        progress[model.id] = nil
    }

    private func modelID(for partKey: String) -> String { String(partKey.split(separator: ":").first ?? "") }

    private func destinationFilename(for partKey: String) -> String? {
        guard let modelID = partKey.split(separator: ":").first.map(String.init),
              let model = ModelCatalog.all.first(where: { $0.id == modelID }) else { return nil }
        return partKey.hasSuffix("mmproj") ? model.mmproj?.filename : model.filename
    }

    private func updateCombinedProgress(for modelID: String) {
        let keys = bytesExpected.keys.filter { $0.hasPrefix("\(modelID)::") }
        let totalExpected = keys.reduce(0) { $0 + (bytesExpected[$1] ?? 0) }
        let totalWritten = keys.reduce(0) { $0 + (bytesWritten[$1] ?? 0) }
        guard totalExpected > 0 else { return }
        progress[modelID] = Double(totalWritten) / Double(totalExpected)
    }

    private func finishPart(_ partKey: String, tempLocation: URL?, error: Error?) {
        let modelID = modelID(for: partKey)
        defer {
            pendingParts[modelID, default: 1] -= 1
            if let remaining = pendingParts[modelID], remaining <= 0 {
                pendingParts[modelID] = nil
                downloading.remove(modelID)
                progress[modelID] = nil
                if error == nil { onModelInstalled?() }
            }
        }
        tasks[partKey] = nil
        bytesWritten[partKey] = nil
        bytesExpected[partKey] = nil

        if let error {
            if (error as NSError).code != NSURLErrorCancelled { errorMessage = error.localizedDescription }
            return
        }
        guard let tempLocation, let filename = destinationFilename(for: partKey) else { return }
        let destination = modelsDirectory.appending(path: filename)
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: tempLocation, to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.bytesWritten[key] = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { self.bytesExpected[key] = totalBytesExpectedToWrite }
            self.updateCombinedProgress(for: self.modelID(for: key))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        let temporaryCopy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".gguf")
        do {
            try FileManager.default.copyItem(at: location, to: temporaryCopy)
        } catch {
            Task { @MainActor [weak self] in self?.finishPart(key, tempLocation: nil, error: error) }
            return
        }
        Task { @MainActor [weak self] in self?.finishPart(key, tempLocation: temporaryCopy, error: nil) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription, let error else { return }
        Task { @MainActor [weak self] in self?.finishPart(key, tempLocation: nil, error: error) }
    }
}

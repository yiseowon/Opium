import Foundation

struct HFModelSummary: Identifiable, Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
}

struct HFFile: Identifiable {
    var id: String { path }
    let path: String
    let sizeBytes: Int64

    var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }

    /// Same rule of thumb `ModelCatalog` uses for its curated entries: file size
    /// plus context/KV-cache overhead plus headroom for macOS itself.
    var estimatedMinMemoryGB: Int {
        Int((sizeGB * 1.3 + 4).rounded(.up))
    }
}

enum HuggingFaceSearch {
    private static let session = URLSession(configuration: .ephemeral)

    static func searchModels(query: String) async throws -> [HFModelSummary] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "20")
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentError.message("Hugging Face 검색에 실패했습니다.")
        }
        return try JSONDecoder().decode([HFModelSummary].self, from: data)
    }

    static func ggufFiles(repo: String) async throws -> [HFFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentError.message("파일 목록을 불러오지 못했습니다.")
        }
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry -> HFFile? in
            guard let path = entry["path"] as? String, path.lowercased().hasSuffix(".gguf") else { return nil }
            let size = (entry["size"] as? Int64) ?? Int64(entry["size"] as? Int ?? 0)
            return HFFile(path: path, sizeBytes: size)
        }.sorted { $0.path < $1.path }
    }

    static func downloadURL(repo: String, file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
    }

    static func catalogModel(repo: String, file: HFFile) -> CatalogModel {
        CatalogModel(
            id: "hf::\(repo)::\(file.path)",
            displayName: file.path,
            quant: "", sizeBytes: file.sizeBytes, minMemoryGB: file.estimatedMinMemoryGB,
            url: downloadURL(repo: repo, file: file.path),
            filename: file.path
        )
    }
}

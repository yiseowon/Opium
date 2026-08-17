import Foundation

struct CatalogModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let quant: String
    let sizeBytes: Int64
    let minMemoryGB: Int
    let url: URL
    let filename: String
    var mmproj: (url: URL, filename: String, sizeBytes: Int64)? = nil

    var sizeGB: Double { Double(totalBytes) / 1_073_741_824 }
    var totalBytes: Int64 { sizeBytes + (mmproj?.sizeBytes ?? 0) }
    var isVisionCapable: Bool { mmproj != nil }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ModelCatalog {
    /// minMemoryGB is a rough "safe to run" floor: file size plus KV-cache/context
    /// overhead plus headroom for macOS itself, not the bare minimum to load the weights.
    static let all: [CatalogModel] = [
        CatalogModel(
            id: "llama-3.2-3b",
            displayName: "Llama 3.2 3B Instruct",
            quant: "Q4_K_M", sizeBytes: 2_019_377_696, minMemoryGB: 8,
            url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        ),
        CatalogModel(
            id: "qwen2.5-7b",
            displayName: "Qwen2.5 7B Instruct",
            quant: "Q4_K_M", sizeBytes: 4_683_074_240, minMemoryGB: 16,
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
            filename: "Qwen2.5-7B-Instruct-Q4_K_M.gguf"
        ),
        CatalogModel(
            id: "qwen2.5-14b",
            displayName: "Qwen2.5 14B Instruct",
            quant: "Q4_K_M", sizeBytes: 8_988_110_976, minMemoryGB: 24,
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf")!,
            filename: "Qwen2.5-14B-Instruct-Q4_K_M.gguf"
        ),
        CatalogModel(
            id: "qwen2.5-32b",
            displayName: "Qwen2.5 32B Instruct",
            quant: "Q4_K_M", sizeBytes: 19_851_336_576, minMemoryGB: 36,
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-32B-Instruct-GGUF/resolve/main/Qwen2.5-32B-Instruct-Q4_K_M.gguf")!,
            filename: "Qwen2.5-32B-Instruct-Q4_K_M.gguf"
        ),
        CatalogModel(
            id: "llama-3.1-70b",
            displayName: "Llama 3.1 70B Instruct",
            quant: "Q4_K_M", sizeBytes: 42_520_398_400, minMemoryGB: 96,
            url: URL(string: "https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf")!,
            filename: "Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
        ),
        CatalogModel(
            id: "qwen2-vl-7b",
            displayName: "Qwen2 VL 7B Instruct (비전)",
            quant: "Q4_K_M", sizeBytes: 4_683_072_672, minMemoryGB: 20,
            url: URL(string: "https://huggingface.co/bartowski/Qwen2-VL-7B-Instruct-GGUF/resolve/main/Qwen2-VL-7B-Instruct-Q4_K_M.gguf")!,
            filename: "Qwen2-VL-7B-Instruct-Q4_K_M.gguf",
            mmproj: (
                url: URL(string: "https://huggingface.co/bartowski/Qwen2-VL-7B-Instruct-GGUF/resolve/main/mmproj-Qwen2-VL-7B-Instruct-f32.gguf")!,
                filename: "mmproj-Qwen2-VL-7B-Instruct-f32.gguf",
                sizeBytes: 2_703_066_624
            )
        )
    ]

    /// The largest general-purpose (non-vision) model this device can comfortably run.
    static func recommended(forMemoryGB memoryGB: Int) -> CatalogModel? {
        all.filter { $0.minMemoryGB <= memoryGB && !$0.isVisionCapable }.max { $0.minMemoryGB < $1.minMemoryGB }
    }
}

struct DeviceCapability {
    let chipName: String
    let memoryGB: Int

    static var current: DeviceCapability {
        DeviceCapability(chipName: chipName(), memoryGB: memoryGB())
    }

    private static func memoryGB() -> Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    private static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "알 수 없는 칩" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let name = String(cString: buffer)
        return name.isEmpty ? "알 수 없는 칩" : name
    }
}

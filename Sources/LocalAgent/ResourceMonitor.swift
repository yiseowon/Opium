import Darwin
import Foundation
import Observation

@MainActor @Observable
final class ResourceMonitor {
    var snapshot = ResourceSnapshot()
    private var task: Task<Void, Never>?

    func start(modelPID: @escaping @MainActor () -> Int32?) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample(modelPID: modelPID())
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func sample(modelPID: Int32?) {
        let app = Self.physicalFootprint(pid: getpid())
        let model = modelPID.map(Self.physicalFootprint(pid:)) ?? 0
        let used = Self.systemUsedBytes()
        var history = snapshot.history
        history.append(Double(used) / Double(max(ProcessInfo.processInfo.physicalMemory, 1)))
        if history.count > 36 { history.removeFirst(history.count - 36) }
        snapshot = ResourceSnapshot(appBytes: app, modelBytes: model, systemUsedBytes: used, history: history)
    }

    // Activity Monitor's per-process "Memory" column uses physical footprint,
    // not RSS. This includes compressed/private memory without double-counting mappings.
    private static func physicalFootprint(pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    private static func systemUsedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // Matches Activity Monitor's Memory Used categories: app/active + wired + compressed.
        let pages = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count)
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return pages * UInt64(pageSize)
    }
}

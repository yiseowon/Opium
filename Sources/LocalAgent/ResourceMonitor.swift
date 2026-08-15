import Darwin
import Foundation
import Observation

@MainActor @Observable
final class ResourceMonitor {
    var snapshot = ResourceSnapshot()
    private var task: Task<Void, Never>?
    private var previousCPUTicks: (total: UInt64, idle: UInt64)?

    func start(modelPID: @escaping @MainActor () -> Int32?) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let gpuUsage = await Task.detached { Self.gpuUsage() }.value
                self?.sample(modelPID: modelPID(), gpuUsage: gpuUsage)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func sample(modelPID: Int32?, gpuUsage: Double?) {
        let app = Self.physicalFootprint(pid: getpid())
        let model = modelPID.map(Self.residentBytes(pid:)) ?? 0
        let used = Self.systemUsedBytes()
        var history = snapshot.history
        history.append(Double(used) / Double(max(ProcessInfo.processInfo.physicalMemory, 1)))
        if history.count > 36 { history.removeFirst(history.count - 36) }
        let ticks = Self.cpuTicks()
        let cpuUsage = previousCPUTicks.map {
            let total = ticks.total - $0.total
            return total == 0 ? 0 : Double(total - (ticks.idle - $0.idle)) / Double(total)
        } ?? 0
        previousCPUTicks = ticks
        snapshot = ResourceSnapshot(appBytes: app, modelBytes: model, systemUsedBytes: used, history: history,
                                    cpuUsage: cpuUsage, gpuUsage: gpuUsage, thermalState: Self.thermalState)
    }

    private nonisolated static func cpuTicks() -> (total: UInt64, idle: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let ticks = info.cpu_ticks
        let idle = UInt64(ticks.2)
        return (UInt64(ticks.0) + UInt64(ticks.1) + idle + UInt64(ticks.3), idle)
    }

    private nonisolated static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "정상"
        case .fair: "약간 높음"
        case .serious: "높음"
        case .critical: "매우 높음"
        @unknown default: "알 수 없음"
        }
    }

    private nonisolated static func gpuUsage() -> Double? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-c", "AGXAccelerator", "-d", "1"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return gpuUsage(from: output)
    }

    nonisolated static func gpuUsage(from output: String) -> Double? {
        guard let match = output.firstMatch(of: /"Device Utilization %"=(\d+)/),
              let value = Double(match.1) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    // llama.cpp memory-maps GGUF weights. Resident size includes those pages while
    // physical footprint omits most of them and severely under-reports model memory.
    private static func residentBytes(pid: Int32) -> UInt64 {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(size))
        }
        return result == size ? info.pti_resident_size : 0
    }

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

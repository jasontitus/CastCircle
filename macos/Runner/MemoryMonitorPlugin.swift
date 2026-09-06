import FlutterMacOS
import Darwin

/// macOS native plugin that reports process memory usage.
class MemoryMonitorPlugin: NSObject {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.lineguide/memory_monitor",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handle)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getMemoryUsage":
            guard let physicalMB = getPhysicalFootprint(),
                  let availableMB = getAvailableMemory() else {
                result(FlutterError(
                    code: "MEMORY_PROBE_FAILED",
                    message: "Could not read macOS memory statistics",
                    details: nil
                ))
                return
            }

            let totalMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
            result([
                "physicalFootprintMB": physicalMB,
                "availableMemoryMB": availableMB,
                "totalPhysicalMemoryMB": totalMB,
            ])

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getPhysicalFootprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let probeResult = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard probeResult == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint) / 1024 / 1024
    }

    private func getAvailableMemory() -> Int? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let probeResult = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard probeResult == KERN_SUCCESS else { return nil }

        let availablePages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
        return Int(availablePages * UInt64(vm_kernel_page_size) / 1024 / 1024)
    }
}

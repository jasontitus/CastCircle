import Flutter
import UIKit
import Darwin

/// Native plugin that reports process memory usage.
/// Uses `task_info` for accurate memory measurement that matches
/// what Jetsam sees.
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
            guard let physicalMB = getPhysicalFootprint() else {
                result(FlutterError(
                    code: "TASK_INFO_FAILED",
                    message: "Unable to read the process physical footprint",
                    details: nil
                ))
                return
            }

            // os_proc_available_memory gives the amount of memory available
            // before Jetsam kills us
            let availableMB = Int(os_proc_available_memory()) / 1024 / 1024

            result([
                "physicalFootprintMB": physicalMB,
                "availableMemoryMB": availableMB,
                "totalPhysicalMemoryMB": Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024),
            ])

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Get the physical footprint of this process in MB.
    /// This matches what Jetsam uses to decide whether to kill the process.
    private func getPhysicalFootprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Int(info.phys_footprint) / 1024 / 1024
        }
        return nil
    }
}

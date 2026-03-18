import Foundation
import MLX

// MARK: - Memory & Performance Instrumentation

/// Snapshot of memory usage at a point in time.
public struct MemorySnapshot {
    /// MLX GPU active memory in bytes.
    public let gpuActive: Int
    /// MLX GPU peak memory in bytes (since last reset).
    public let gpuPeak: Int
    /// Process resident memory (RSS) in bytes.
    public let processRSS: Int
    /// Timestamp.
    public let timestamp: CFAbsoluteTime

    public var gpuActiveMB: Double { Double(gpuActive) / 1_048_576.0 }
    public var gpuPeakMB: Double { Double(gpuPeak) / 1_048_576.0 }
    public var processRSSMB: Double { Double(processRSS) / 1_048_576.0 }
}

/// Performance metrics for a timed operation.
public struct PerfMetrics {
    public let name: String
    public let durationSeconds: Double
    public let memBefore: MemorySnapshot
    public let memAfter: MemorySnapshot

    public var gpuDeltaMB: Double { memAfter.gpuActiveMB - memBefore.gpuActiveMB }
    public var gpuPeakMB: Double { memAfter.gpuPeakMB }
    public var rssDeltaMB: Double { memAfter.processRSSMB - memBefore.processRSSMB }
}

/// Instrument a block of code, measuring time and memory.
public func instrument<T>(_ name: String, _ body: () throws -> T) rethrows -> (result: T, metrics: PerfMetrics) {
    GPU.peakMemory = 0
    let memBefore = takeMemorySnapshot()
    let start = CFAbsoluteTimeGetCurrent()

    let result = try body()

    // Force MLX to finish pending work before measuring
    eval(MLXArray(0))
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    let memAfter = takeMemorySnapshot()

    let metrics = PerfMetrics(
        name: name,
        durationSeconds: elapsed,
        memBefore: memBefore,
        memAfter: memAfter
    )
    return (result, metrics)
}

/// Async variant of instrument.
public func instrumentAsync<T>(_ name: String, _ body: () async throws -> T) async rethrows -> (result: T, metrics: PerfMetrics) {
    GPU.peakMemory = 0
    let memBefore = takeMemorySnapshot()
    let start = CFAbsoluteTimeGetCurrent()

    let result = try await body()

    eval(MLXArray(0))
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    let memAfter = takeMemorySnapshot()

    let metrics = PerfMetrics(
        name: name,
        durationSeconds: elapsed,
        memBefore: memBefore,
        memAfter: memAfter
    )
    return (result, metrics)
}

/// Take a memory snapshot right now.
public func takeMemorySnapshot() -> MemorySnapshot {
    return MemorySnapshot(
        gpuActive: GPU.activeMemory,
        gpuPeak: GPU.peakMemory,
        processRSS: getProcessRSS(),
        timestamp: CFAbsoluteTimeGetCurrent()
    )
}

/// Get current process resident set size (RSS) in bytes.
private func getProcessRSS() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), ptr, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

// MARK: - Report Formatting

/// Format a complete benchmark report as a table.
public func formatBenchmarkReport(
    modelName: String,
    metrics: [PerfMetrics],
    audioDurationSeconds: Double,
    outputSampleRate: Int = 24000
) -> String {
    var lines: [String] = []

    lines.append("╔══════════════════════════════════════════════════════════════╗")
    lines.append("║  BENCHMARK: \(modelName.padding(toLength: 47, withPad: " ", startingAt: 0))║")
    lines.append("╠══════════════════════════════════════════════════════════════╣")

    // Per-phase metrics
    lines.append("║  Phase                  Time(s)   GPU(MB)   RSS(MB)        ║")
    lines.append("║  ──────────────────── ────────── ────────── ─────────       ║")

    var totalTime = 0.0
    for m in metrics {
        totalTime += m.durationSeconds
        let phase = m.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        let time = String(format: "%8.2f", m.durationSeconds)
        let gpu = String(format: "%8.1f", m.gpuPeakMB)
        let rss = String(format: "%8.1f", m.memAfter.processRSSMB)
        lines.append("║  \(phase) \(time)   \(gpu)   \(rss)       ║")
    }

    lines.append("║  ──────────────────── ────────── ────────── ─────────       ║")

    // Summary
    let rtf = totalTime / audioDurationSeconds
    let peakGPU = metrics.map { $0.gpuPeakMB }.max() ?? 0
    let peakRSS = metrics.map { $0.memAfter.processRSSMB }.max() ?? 0

    lines.append("║                                                             ║")
    lines.append("║  Total inference:  \(String(format: "%8.2f", totalTime))s                               ║")
    lines.append("║  Audio duration:   \(String(format: "%8.2f", audioDurationSeconds))s                               ║")
    lines.append("║  Real-time factor: \(String(format: "%8.2f", rtf))x                               ║")
    lines.append("║  Peak GPU memory:  \(String(format: "%8.1f", peakGPU)) MB                             ║")
    lines.append("║  Peak RSS memory:  \(String(format: "%8.1f", peakRSS)) MB                             ║")
    lines.append("║                                                             ║")
    lines.append("╚══════════════════════════════════════════════════════════════╝")

    return lines.joined(separator: "\n")
}

/// Export metrics as JSON for automated comparison.
public func exportMetricsJSON(
    modelName: String,
    metrics: [PerfMetrics],
    audioDurationSeconds: Double
) -> String {
    var phases: [[String: Any]] = []
    for m in metrics {
        phases.append([
            "name": m.name,
            "duration_s": m.durationSeconds,
            "gpu_peak_mb": m.gpuPeakMB,
            "gpu_delta_mb": m.gpuDeltaMB,
            "rss_after_mb": m.memAfter.processRSSMB,
            "rss_delta_mb": m.rssDeltaMB,
        ])
    }

    let totalTime = metrics.reduce(0) { $0 + $1.durationSeconds }
    let peakGPU = metrics.map { $0.gpuPeakMB }.max() ?? 0
    let peakRSS = metrics.map { $0.memAfter.processRSSMB }.max() ?? 0

    // Manual JSON construction (no JSONSerialization dependency)
    var json = "{\n"
    json += "  \"model\": \"\(modelName)\",\n"
    json += "  \"audio_duration_s\": \(String(format: "%.3f", audioDurationSeconds)),\n"
    json += "  \"total_inference_s\": \(String(format: "%.3f", totalTime)),\n"
    json += "  \"rtf\": \(String(format: "%.3f", totalTime / audioDurationSeconds)),\n"
    json += "  \"peak_gpu_mb\": \(String(format: "%.1f", peakGPU)),\n"
    json += "  \"peak_rss_mb\": \(String(format: "%.1f", peakRSS)),\n"
    json += "  \"phases\": [\n"
    for (i, p) in phases.enumerated() {
        json += "    {"
        json += "\"name\": \"\(p["name"] as! String)\", "
        json += "\"duration_s\": \(String(format: "%.3f", p["duration_s"] as! Double)), "
        json += "\"gpu_peak_mb\": \(String(format: "%.1f", p["gpu_peak_mb"] as! Double)), "
        json += "\"rss_after_mb\": \(String(format: "%.1f", p["rss_after_mb"] as! Double))"
        json += "}\(i < phases.count - 1 ? "," : "")\n"
    }
    json += "  ]\n"
    json += "}"
    return json
}

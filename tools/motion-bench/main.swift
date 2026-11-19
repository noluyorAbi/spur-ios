import Darwin
import Foundation
import simd

// Release-mode time and memory of the motion analysis (SPEC 16.3.2 step 10, review item 9).
//   gen <file> <hours>   writes a synthetic motion.bin at 100 Hz and a fixes file next to it
//   analyze <file>       analyzes it through the mapped reader; prints time and footprint peak
//   csv <file>           writes the sensor CSV; prints time and footprint peak
//   live <file>          one live refresh (MotionAnalyzer.live, SPEC 17.3) through the mapped
//                        reader, including the read; prints time and the cadence it implies
// Built by scripts/motion-bench.sh with -O; each step runs in its own process, so the
// footprint peak (phys_footprint, what iOS limits an app by) belongs to that step alone.

func footprintPeakMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
}

let t0 = 1_794_420_000.0
func fixesURL(_ file: String) -> URL { URL(fileURLWithPath: file + ".fixes.json") }

struct FixRow: Codable { var t: Double; var v: Double }

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "gen":
    let url = URL(fileURLWithPath: args[2]), hours = Double(args[3])!
    try? FileManager.default.removeItem(at: url)
    let writer = try MotionFileWriter(url: url, rateHz: 100, created: t0)
    var noise = MotionSynth.Noise(state: 11)
    let mount = MotionSynth.mount(yaw: 37, pitch: -62, roll: 8)
    var rows: [FixRow] = []
    var v = 10.0
    for s in 0..<Int(3600 * hours) {
        // Stop-and-go with turns: 10 s at +0.8, 10 s at -0.8 m/s², a turn every minute.
        let phase = s % 60
        let long = phase < 20 ? (phase < 10 ? 0.8 : -0.8) : (phase < 40 ? 0.6 * (phase < 30 ? 1 : -1) : 0)
        let yaw = phase >= 40 && phase < 46 ? 0.2 : 0
        rows.append(FixRow(t: t0 + Double(s), v: v))
        var batch: [MotionSample] = []
        batch.reserveCapacity(100)
        for k in 0..<100 {
            batch.append(MotionSynth.sample(time: t0 + Double(s) + Double(k) / 100, long: long, lat: v * yaw, vert: 0, yawRate: yaw, mount: mount, noise: &noise))
            v = max(3, v + long / 100)
        }
        try writer.append(batch)
    }
    writer.close()
    try JSONEncoder().encode(rows).write(to: fixesURL(args[2]))
    print("motion-bench gen: \(hours) h, \(rows.count * 100) samples")
case "analyze", "csv", "live":
    let rows = try JSONDecoder().decode([FixRow].self, from: Data(contentsOf: fixesURL(args[2])))
    var heading = 0.0
    let fixes = rows.enumerated().map { (k, r) -> Fix in
        let phase = k % 60
        if phase >= 40 && phase < 46 { heading += 0.2 * 180 / .pi }
        return Fix(timestampMs: Int64(r.t * 1000), latitude: 32.78 + Double(k) * 1e-5, longitude: -96.80, horizontalAccuracy: 5,
                   speed: r.v, speedAccuracy: 0.3, course: (360 - heading.truncatingRemainder(dividingBy: 360)).truncatingRemainder(dividingBy: 360))
    }
    let before = footprintPeakMB()
    let source = MappedMotionFile(url: URL(fileURLWithPath: args[2]))!
    let start = Date()
    if args[1] == "live" {
        let out = MotionAnalyzer.live(source: source, fixes: fixes, now: Date())
        let elapsed = Date().timeIntervalSince(start)
        let interval = max(10, 50 * elapsed)
        print(String(format: "motion-bench live: %d samples, refresh %.3f s, cadence %.0f s (%.1f %% of a core), footprint peak %.0f MB, aligned %d",
                     source.count, elapsed, interval, 100 * elapsed / interval, footprintPeakMB(), out.output.summary.alignedSegments))
    } else if args[1] == "analyze" {
        let out = MotionAnalyzer.analyze(source: source, fixes: fixes)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "motion-bench analyze: %d samples in %.2f s, footprint peak %.0f MB (%.0f MB before), aligned %d of %d, r_long %.3f",
                     source.count, elapsed, footprintPeakMB(), before, out.summary.alignedSegments, out.summary.segments, out.summary.rLong ?? -1))
    } else {
        let csv = URL(fileURLWithPath: args[2] + ".csv")
        try MotionCSVExporter.write(source: source, fixes: fixes, to: csv)
        let elapsed = Date().timeIntervalSince(start)
        let size = (try FileManager.default.attributesOfItem(atPath: csv.path)[.size] as? Int) ?? 0
        try? FileManager.default.removeItem(at: csv)
        print(String(format: "motion-bench csv: %d rows, %.0f MB, %.0f bytes per row, in %.2f s, footprint peak %.0f MB (%.0f MB before)",
                     source.count, Double(size) / 1_000_000, Double(size) / Double(source.count), elapsed, footprintPeakMB(), before))
    }
default:
    print("usage: motion-bench gen|analyze|csv|live <file> [hours]")
    exit(2)
}

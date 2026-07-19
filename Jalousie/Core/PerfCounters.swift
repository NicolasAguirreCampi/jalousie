import Foundation

// Runtime perf counters. Bumped from hot paths (AX reads/writes, retile
// entry/exit) so we can observe the effect of a fix by comparing snapshots
// before and after in the running app.
//
// Deliberately not thread-safe — everything we count runs on the main
// queue after we bounce off the AX/CGEventTap callback threads. Adding a
// lock would add measurable cost inside every AX call.
enum PerfCounters {
    // Retile lifecycle
    static var retileRequested: Int = 0    // times something asked for a retile
    static var retileExecuted: Int = 0     // times retile() actually ran (post-coalesce)
    static var retileTotalNanos: UInt64 = 0
    static var retileMaxNanos: UInt64 = 0

    // AX chatter
    static var axReads: Int = 0            // AXUIElementCopyAttributeValue calls
    static var axWrites: Int = 0           // AXUIElementSetAttributeValue calls

    // Enumeration cost
    static var enumerateCalls: Int = 0     // times enumerateManagedWindows() ran
    static var setFrameCalls: Int = 0      // times setFrame() actually applied

    static func reset() {
        retileRequested = 0
        retileExecuted = 0
        retileTotalNanos = 0
        retileMaxNanos = 0
        axReads = 0
        axWrites = 0
        enumerateCalls = 0
        setFrameCalls = 0
    }

    static func snapshot() -> String {
        let avgMillis = retileExecuted > 0
            ? Double(retileTotalNanos) / Double(retileExecuted) / 1_000_000.0
            : 0
        let maxMillis = Double(retileMaxNanos) / 1_000_000.0
        return """
        perf snapshot
          retile requested: \(retileRequested)
          retile executed:  \(retileExecuted)  \(coalesceRatio())
          retile avg:       \(String(format: "%.2f", avgMillis)) ms
          retile max:       \(String(format: "%.2f", maxMillis)) ms
          enumerate calls:  \(enumerateCalls)
          setFrame calls:   \(setFrameCalls)
          AX reads:         \(axReads)
          AX writes:        \(axWrites)
        """
    }

    private static func coalesceRatio() -> String {
        guard retileRequested > 0, retileExecuted > 0 else { return "" }
        let ratio = Double(retileRequested) / Double(retileExecuted)
        return "(coalesce ratio \(String(format: "%.1fx", ratio)))"
    }
}

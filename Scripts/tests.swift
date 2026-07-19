#!/usr/bin/env swift

// Standalone deterministic test suite for Jalousie's pure logic. Runs via:
//   swift Scripts/tests.swift
// Zero Xcode dependencies. Contains a duplicated copy of RetileCoalescer
// (kept in sync via the source-drift check at the end of this file — if
// the app's copy and this copy diverge, tests fail).

import Foundation
import CryptoKit

// MARK: - RetileCoalescer (DUPLICATE — keep in sync with Jalousie/Core/RetileCoalescer.swift)
// The duplicated region sits between the two BEGIN/END sentinel lines below.
// The drift check near the bottom of this file hashes only that region and
// compares it to the same-shaped region in the app's file.

// >>> COALESCER BEGIN <<<
final class RetileCoalescer {
    typealias Scheduler = (@escaping () -> Void) -> Void
    typealias Executor = () -> Void

    private let schedule: Scheduler
    private let execute: Executor
    private var pending: Bool = false

    private(set) var requestCount: Int = 0
    private(set) var executeCount: Int = 0

    init(schedule: @escaping Scheduler, execute: @escaping Executor) {
        self.schedule = schedule
        self.execute = execute
    }

    func request() {
        requestCount += 1
        guard !pending else { return }
        pending = true
        schedule { [weak self] in
            guard let self else { return }
            self.pending = false
            self.executeCount += 1
            self.execute()
        }
    }

    func resetCounters() {
        requestCount = 0
        executeCount = 0
    }
}
// >>> COALESCER END <<<

// MARK: - Test harness

var failures: [String] = []

func expect(_ condition: Bool, _ message: @autoclosure () -> String,
            file: String = #file, line: Int = #line) {
    if !condition {
        failures.append("\(file):\(line): \(message())")
    }
}

func run(_ name: String, _ body: () -> Void) {
    let before = failures.count
    body()
    let added = failures.count - before
    if added == 0 {
        print("  ✓ \(name)")
    } else {
        print("  ✗ \(name)")
    }
}

// MARK: - Deterministic dispatch scheduler
// Instead of DispatchQueue.main.async (which is main-runloop dependent and
// non-deterministic in a script), tests use a manual "runloop" that queues
// blocks and flushes them on demand. This is exactly the coalescer's
// contract: schedule fires on a later tick, we control when the tick happens.

final class ManualScheduler {
    private var queue: [() -> Void] = []
    var schedule: (@escaping () -> Void) -> Void { { [weak self] block in
        self?.queue.append(block)
    } }
    func drain() {
        let pending = queue
        queue.removeAll(keepingCapacity: true)
        for block in pending { block() }
    }
    var pendingCount: Int { queue.count }
}

// MARK: - Coalescer tests

print("\nRetileCoalescer")

run("single request → single execute after drain") {
    let sched = ManualScheduler()
    var executes = 0
    let coalescer = RetileCoalescer(schedule: sched.schedule) { executes += 1 }

    coalescer.request()
    expect(coalescer.requestCount == 1, "requestCount=\(coalescer.requestCount)")
    expect(executes == 0, "should not execute before drain, got \(executes)")

    sched.drain()
    expect(executes == 1, "executes=\(executes)")
    expect(coalescer.executeCount == 1, "executeCount=\(coalescer.executeCount)")
}

run("20 requests in one tick → 1 execute") {
    let sched = ManualScheduler()
    var executes = 0
    let coalescer = RetileCoalescer(schedule: sched.schedule) { executes += 1 }

    for _ in 0..<20 { coalescer.request() }
    expect(coalescer.requestCount == 20, "requestCount=\(coalescer.requestCount)")
    expect(executes == 0, "should not execute before drain")

    sched.drain()
    expect(executes == 1, "expected 1 execute for the burst, got \(executes)")
    expect(coalescer.executeCount == 1, "executeCount=\(coalescer.executeCount)")
}

run("sequential bursts run separately (no cross-tick collapse)") {
    let sched = ManualScheduler()
    var executes = 0
    let coalescer = RetileCoalescer(schedule: sched.schedule) { executes += 1 }

    // burst 1
    for _ in 0..<5 { coalescer.request() }
    sched.drain()
    expect(executes == 1, "burst 1 executes=\(executes)")

    // burst 2
    for _ in 0..<3 { coalescer.request() }
    sched.drain()
    expect(executes == 2, "burst 2 executes=\(executes)")

    expect(coalescer.requestCount == 8, "requestCount=\(coalescer.requestCount)")
    expect(coalescer.executeCount == 2, "executeCount=\(coalescer.executeCount)")
}

run("request during execute schedules the next tick, not immediate") {
    // Simulates: retile() itself causes AX events that call requestRetile()
    // recursively. Those inner requests must be deferred to the NEXT tick,
    // not swallowed and not run immediately.
    let sched = ManualScheduler()
    var executes = 0
    var coalescer: RetileCoalescer!
    coalescer = RetileCoalescer(schedule: sched.schedule) {
        executes += 1
        if executes == 1 {
            // Fire another request from inside the execute block.
            coalescer.request()
        }
    }

    coalescer.request()
    sched.drain()
    expect(executes == 1, "first drain executes=\(executes)")
    expect(sched.pendingCount == 1, "second execute should be queued for next tick, pending=\(sched.pendingCount)")

    sched.drain()
    expect(executes == 2, "second drain executes=\(executes)")
}

run("reset clears counters but preserves pending schedule") {
    let sched = ManualScheduler()
    var executes = 0
    let coalescer = RetileCoalescer(schedule: sched.schedule) { executes += 1 }

    coalescer.request()
    coalescer.resetCounters()
    expect(coalescer.requestCount == 0, "requestCount reset")
    expect(coalescer.executeCount == 0, "executeCount reset")

    // The pending block still fires — reset is for counters only.
    sched.drain()
    expect(executes == 1, "pending schedule survived reset, executes=\(executes)")
    expect(coalescer.executeCount == 1, "executeCount=\(coalescer.executeCount) after post-reset drain")
}

// MARK: - Source drift check
// Guarantees the RetileCoalescer copy in this file matches the one shipping
// in the app. If someone changes the app's implementation without updating
// this file, tests here would test the old code — a silent lie. This check
// makes drift a build failure.

// Markers are assembled at runtime so this file's search strings don't
// self-match — otherwise firstIndex would find the code below before it
// finds the actual marker at the top of the file.
let beginMarker = ">>" + "> COALESCER BEGIN <" + "<<"
let endMarker   = ">>" + "> COALESCER END <"   + "<<"

func extractCoalescerRegion(from path: String) -> String? {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
    }
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    guard let beginIndex = lines.firstIndex(where: { $0.contains(beginMarker) }),
          let endIndex   = lines.firstIndex(where: { $0.contains(endMarker) }),
          beginIndex < endIndex else {
        return nil
    }
    return lines[(beginIndex + 1)..<endIndex].joined(separator: "\n")
}

func normalize(_ s: String) -> String {
    // Strip comments and whitespace so cosmetic differences don't trip drift.
    var out = ""
    for line in s.split(separator: "\n") {
        var trimmed = String(line).trimmingCharacters(in: .whitespaces)
        if let commentStart = trimmed.range(of: "//") {
            trimmed = String(trimmed[..<commentStart.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if !trimmed.isEmpty { out += trimmed + "\n" }
    }
    return out
}

print("\nSource-drift check")
run("app RetileCoalescer matches script copy") {
    // Locate the app file relative to this script.
    let scriptPath = CommandLine.arguments[0]
    let scriptURL = URL(fileURLWithPath: scriptPath)
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    let appPath = repoRoot.appendingPathComponent("Jalousie/Core/RetileCoalescer.swift").path

    guard let scriptRegion = extractCoalescerRegion(from: scriptPath) else {
        expect(false, "could not extract script coalescer region from \(scriptPath)")
        return
    }
    guard let appRegion = extractCoalescerRegion(from: appPath) else {
        expect(false, "could not extract app coalescer region from \(appPath)")
        return
    }
    let scriptHash = SHA256.hash(data: Data(normalize(scriptRegion).utf8))
    let appHash    = SHA256.hash(data: Data(normalize(appRegion).utf8))
    expect(scriptHash == appHash, """
    RetileCoalescer has drifted between the app and the test copy.
    App:    \(appPath)
    Script: \(scriptPath)
    Update Scripts/tests.swift (the region between COALESCER BEGIN/END markers)
    so it matches the class body in the app file.
    """)
}

// MARK: - Report

print("")
if failures.isEmpty {
    print("PASS — all tests green")
    exit(0)
} else {
    print("FAIL — \(failures.count) failure(s):")
    for f in failures { print("  \(f)") }
    exit(1)
}

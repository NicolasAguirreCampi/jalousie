import Foundation

// Coalesces a burst of retile requests into a single execution on the next
// runloop tick. macOS routinely fires 4–8 AX/workspace notifications for one
// user event (Cmd-Tab, new window, focus change) — without coalescing every
// one runs a full retile pass, most of them redundant.
//
// The type is intentionally tiny and dispatch-injectable so it can be
// exercised without a real DispatchQueue in tests.
//
// NOTE: keep the region between the BEGIN/END markers below in exact sync
// with Scripts/tests.swift. The drift check in that script fails the build
// if they diverge — no accidental "tests pass while the app is broken".

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

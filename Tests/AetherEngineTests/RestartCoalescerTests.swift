import Testing
@testable import AetherEngine

@Suite("Restart coalescing")
struct RestartCoalescerTests {

    @Test("First request runs; concurrent requests coalesce to the latest target")
    func coalescesBurst() {
        var c = RestartCoalescer()
        #expect(c.begin(10) == true)
        #expect(c.begin(20) == false)
        #expect(c.begin(35) == false)   // latest target wins
        #expect(c.next(justRan: 10) == 35)
        #expect(c.next(justRan: 35) == nil)
        #expect(c.begin(40) == true)
    }

    @Test("No coalescing when requests are fully sequential")
    func sequentialRequestsEachRun() {
        var c = RestartCoalescer()
        #expect(c.begin(5) == true)
        #expect(c.next(justRan: 5) == nil)   // nothing pending
        #expect(c.begin(6) == true)          // free to run again
        #expect(c.next(justRan: 6) == nil)
    }

    @Test("A pending target equal to what just ran does not loop forever")
    func samePendingTargetTerminates() {
        var c = RestartCoalescer()
        #expect(c.begin(12) == true)
        #expect(c.begin(12) == false)        // duplicate while in-flight
        #expect(c.next(justRan: 12) == nil)  // same index → no redundant restart
    }
}

import Testing

@testable import ClickyCore

@Suite("Brain service refresh coalescing")
struct BrainServiceRefreshCoalescerTests {
    @Test("the first request starts a run now")
    func firstStarts() {
        var coalescer = BrainServiceRefreshCoalescer()
        let request = coalescer.request(folders: ["/a"])
        #expect(request.shouldStartNow)
        #expect(request.run == 1)
        #expect(coalescer.runningFolders == ["/a"])
        #expect(!coalescer.hasCompleted(run: 1))
    }

    @Test("the same list while running joins the running run")
    func sameListJoins() {
        var coalescer = BrainServiceRefreshCoalescer()
        _ = coalescer.request(folders: ["/a"])
        let joined = coalescer.request(folders: ["/a"])
        #expect(!joined.shouldStartNow)
        #expect(joined.run == 1)
        #expect(coalescer.finishRun() == nil)
        #expect(coalescer.hasCompleted(run: 1))
    }

    @Test("a different list while running queues exactly one more run, and many requests share it")
    func differentListQueuesOne() {
        var coalescer = BrainServiceRefreshCoalescer()
        _ = coalescer.request(folders: ["/a"])
        let second = coalescer.request(folders: ["/a", "/b"])
        let third = coalescer.request(folders: ["/a", "/b", "/c"])
        #expect(!second.shouldStartNow && !third.shouldStartNow)
        #expect(second.run == 2 && third.run == 2)
        let next = coalescer.finishRun()
        #expect(next?.run == 2)
        #expect(next?.folders == ["/a", "/b", "/c"])
        #expect(coalescer.finishRun() == nil)
        #expect(coalescer.hasCompleted(run: 2))
    }

    @Test("the same list as the queued run joins the queued run")
    func sameAsQueuedJoinsQueued() {
        var coalescer = BrainServiceRefreshCoalescer()
        _ = coalescer.request(folders: ["/a"])
        _ = coalescer.request(folders: ["/b"])
        let again = coalescer.request(folders: ["/b"])
        #expect(again.run == 2 && !again.shouldStartNow)
    }

    @Test("after the last run finishes the next request starts a new numbered run")
    func idleAgain() {
        var coalescer = BrainServiceRefreshCoalescer()
        _ = coalescer.request(folders: [])
        _ = coalescer.finishRun()
        let request = coalescer.request(folders: [])
        #expect(request.shouldStartNow && request.run == 2)
    }
}

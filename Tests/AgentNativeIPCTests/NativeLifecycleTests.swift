import AgentNativeIPC
import Foundation
import Testing

private actor NativeLifecycleProbe {
    var started = 0
    var cancelled = 0
    func begin() { started += 1 }
    func end(cancelled: Bool) { if cancelled { self.cancelled += 1 } }
    func counts() -> (Int, Int) { (started, cancelled) }
}
@Test func nativeConnectionWorkIsBoundedAndClosingCancelsEveryOwnedCall() async throws {
    let calls = NativeCallRegistry(), probe = NativeLifecycleProbe()
    for _ in 0..<NativeCallRegistry.maximumCalls {
        try calls.start {
            await probe.begin()
            do { while !Task.isCancelled { try await Task.sleep(for: .milliseconds(2)) } } catch {}
            await probe.end(cancelled: Task.isCancelled)
        }
    }
    #expect(calls.pendingCount == NativeCallRegistry.maximumCalls)
    #expect(throws: NativeIPCFailure.unavailable) { try calls.start {} }
    let startDeadline = ContinuousClock.now + .seconds(5)
    while await probe.counts().0 < NativeCallRegistry.maximumCalls && ContinuousClock.now < startDeadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await probe.counts().0 == NativeCallRegistry.maximumCalls)
    calls.close()
    #expect(calls.pendingCount == 0)
    #expect(throws: NativeIPCFailure.unavailable) { try calls.start {} }
    let endDeadline = ContinuousClock.now + .seconds(5)
    while await probe.counts().1 < NativeCallRegistry.maximumCalls && ContinuousClock.now < endDeadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await probe.counts().1 == NativeCallRegistry.maximumCalls)
}
@Test func nativeCompletedCallReleasesAdmissionWithoutClosingConnection() async throws {
    let calls = NativeCallRegistry()
    try calls.start {}
    let deadline = ContinuousClock.now + .seconds(5)
    while calls.pendingCount != 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(calls.pendingCount == 0)
    try calls.start {}
    calls.close()
    #expect(calls.pendingCount == 0)
}

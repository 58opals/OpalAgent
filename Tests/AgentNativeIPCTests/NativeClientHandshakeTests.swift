import AgentNativeIPC
import AgentValues
import Foundation
import Testing
@testable import AgentClient

struct NativeClientHandshakeTests {
    @Test func initialReadinessRejectsRetirementImmediatelyAfterValidAuthenticationAcknowledgement() async throws {
        let link = ScriptedHandshakeLink(), factory = HandshakeLinkFactory()
        factory.append(link)
        defer { factory.close() }
        let channel = handshakeChannel(factory)
        let pending = Task { try await channel.ready() }
        let hello = try await link.nextExchange()
        try expectHello(hello, channel: "integration")
        try link.reply(to: hello, packet: literalReply(to: hello, kind: "helloResponse", connection: firstConnection))
        let auth = try await link.nextExchange()
        try expectAuthentication(auth, hello: hello, channel: "integration", connection: firstConnection)
        try link.reply(to: auth, packet: literalReply(to: auth, kind: "authenticated", connection: firstConnection), retire: true)
        await #expect(throws: ClientFailure.unavailable) { try await pending.value }
        #expect(link.exchanges.map(\.mode) == ["hello", "authenticate"])
        #expect(link.retiredBeforeReturningReply && !link.isActive)
    }

    @Test func rejectedPrerequisitesNeverCreateOrDiscloseToALink() async throws {
        let prerequisites = HandshakePrerequisites(allowed: false), factory = HandshakeLinkFactory()
        defer { factory.close() }
        let channel = handshakeChannel(factory, prerequisites: prerequisites)
        await #expect(throws: ClientFailure.unavailable) { try await channel.ready() }
        #expect(prerequisites.checks == 1 && factory.openings == 0)
    }

    @Test(arguments: [IntegrationPeerProfile.mcp, .appleAutomation])
    func integrationCredentialsFollowValidatedHelloAndExactAcknowledgement(_ profile: IntegrationPeerProfile) async throws {
        let link = ScriptedHandshakeLink(), factory = HandshakeLinkFactory()
        factory.append(link)
        defer { factory.close() }
        let selected: NativeChannel = profile == .mcp ? .integration : .appleAutomation
        let spelling = profile == .mcp ? "integration" : "appleAutomation"
        let channel = handshakeChannel(factory, channel: selected)
        let pending = Task { try await channel.ready() }
        let hello = try await link.nextExchange()
        try expectHello(hello, channel: spelling)
        #expect(link.exchanges.count == 1 && link.bindings.isEmpty)
        try link.reply(to: hello, packet: literalReply(to: hello, kind: "helloResponse", channel: spelling, connection: firstConnection))
        let auth = try await link.nextExchange()
        try expectAuthentication(auth, hello: hello, channel: spelling, connection: firstConnection)
        #expect(link.bindings == [firstConnection] && factory.openings == 1)
        try link.reply(to: auth, packet: literalReply(to: auth, kind: "authenticated", channel: spelling, connection: firstConnection))
        #expect(try await pending.value === link)
        #expect(try await channel.ready() === link)
        #expect(factory.openings == 1 && link.exchanges.count == 2)
    }

    @Test(arguments: HelloFault.allCases)
    private func rejectedHelloCannotReleaseAnIntegrationCredential(_ fault: HelloFault) async throws {
        let link = ScriptedHandshakeLink(sameUser: fault != .differentUser), factory = HandshakeLinkFactory()
        factory.append(link)
        defer { factory.close() }
        let channel = handshakeChannel(factory)
        let pending = Task { try await channel.ready() }
        let hello = try await link.nextExchange()
        try expectHello(hello, channel: "integration")
        let response: NativeOwnerPacket
        if fault == .malformedFrame { response = NativeOwnerPacket(frame: Data([0xff])) }
        else {
            response = try literalReply(to: hello, kind: "helloResponse",
                channel: fault == .wrongChannel ? "owner" : "integration",
                connection: fault == .invalidConnection ? "not-a-uuid" : firstConnection,
                correlation: fault == .wrongCorrelation ? foreignCorrelation : nil)
        }
        try link.reply(to: hello, packet: response)
        await #expect(throws: fault.expected) { try await pending.value }
        #expect(!link.isActive && link.exchanges.count == 1 && link.bindings.isEmpty)
        #expect(link.exchanges.allSatisfy { $0.credential == nil })
    }

    @Test(arguments: AcknowledgementFault.allCases)
    private func rejectedAcknowledgementCannotBeReusedByTheNextAttempt(_ fault: AcknowledgementFault) async throws {
        let first = ScriptedHandshakeLink(), second = ScriptedHandshakeLink(), factory = HandshakeLinkFactory()
        factory.append(first); factory.append(second)
        defer { factory.close() }
        let prerequisites = HandshakePrerequisites(), channel = handshakeChannel(factory, prerequisites: prerequisites)
        let pending = Task { try await channel.ready() }
        let hello = try await first.nextExchange()
        try expectHello(hello, channel: "integration")
        try first.reply(to: hello, packet: literalReply(to: hello, kind: "helloResponse", connection: firstConnection))
        let auth = try await first.nextExchange()
        try expectAuthentication(auth, hello: hello, channel: "integration", connection: firstConnection)
        try first.reply(to: auth, packet: literalReply(to: auth, kind: "authenticated",
            connection: fault == .changedGreeting ? secondConnection : firstConnection,
            correlation: fault == .wrongCorrelation ? foreignCorrelation : nil))
        await #expect(throws: fault.expected) { try await pending.value }
        #expect(!first.isActive)
        let fresh = Task { try await channel.ready() }
        _ = try await completeHandshake(second, connection: secondConnection)
        #expect(try await fresh.value === second)
        #expect(prerequisites.checks == 2 && factory.openings == 2)
    }

    @Test func ownerHandshakeBindsItsConnectionWithoutIntegrationAuthentication() async throws {
        let link = ScriptedHandshakeLink(), factory = HandshakeLinkFactory()
        factory.append(link)
        defer { factory.close() }
        let channel = handshakeChannel(factory, channel: .owner)
        let pending = Task { try await channel.ready() }
        let hello = try await link.nextExchange()
        try expectHello(hello, channel: "owner")
        try link.reply(to: hello, packet: literalReply(to: hello, kind: "helloResponse", channel: "owner", connection: firstConnection))
        #expect(try await pending.value === link)
        #expect(link.bindings == [firstConnection] && link.exchanges.map(\.mode) == ["hello"])
        #expect(link.exchanges.allSatisfy { $0.credential == nil })
    }

    @Test(arguments: [AgentNativeIPC.NativeChannel.owner, .integration, .appleAutomation])
    func retirementDuringBindingCannotPublishReadinessOrReleaseAuthentication(_ selected: AgentNativeIPC.NativeChannel) async throws {
        let link = ScriptedHandshakeLink(retireOnBind: true), factory = HandshakeLinkFactory()
        factory.append(link)
        defer { factory.close() }
        let channel = handshakeChannel(factory, channel: selected)
        let pending = Task { try await channel.ready() }
        let hello = try await link.nextExchange()
        let spelling: String
        switch selected { case .owner: spelling = "owner"; case .integration: spelling = "integration"; case .appleAutomation: spelling = "appleAutomation" }
        try expectHello(hello, channel: spelling)
        try link.reply(to: hello, packet: literalReply(to: hello, kind: "helloResponse", channel: spelling, connection: firstConnection))
        await #expect(throws: ClientFailure.unavailable) { try await pending.value }
        #expect(link.bindings == [firstConnection] && !link.isActive)
        #expect(link.exchanges.count == 1 && link.exchanges.allSatisfy { $0.credential == nil })
    }

    @Test func acknowledgedAcquisitionsShareOneInitializationAndActiveLink() async throws {
        let link = ScriptedHandshakeLink(), factory = HandshakeLinkFactory()
        factory.append(link)
        defer { factory.close() }
        let channel = handshakeChannel(factory)
        let first = try await channel.acquireInitialization()
        let second = try await channel.acquireInitialization()
        #expect(first.id == second.id && factory.openings == 1)
        let one = Task { try await channel.finishInitialization(first) }
        let two = Task { try await channel.finishInitialization(second) }
        _ = try await completeHandshake(link, connection: firstConnection)
        #expect(try await one.value === link)
        #expect(try await two.value === link)
        let cached = try await channel.acquireInitialization()
        #expect(cached.id == first.id && factory.openings == 1 && link.exchanges.count == 2)
    }

    @Test func retiredCachedLinkRequiresAQualifiedFreshHandshake() async throws {
        let first = ScriptedHandshakeLink(), second = ScriptedHandshakeLink(), factory = HandshakeLinkFactory()
        factory.append(first); factory.append(second)
        defer { factory.close() }
        let prerequisites = HandshakePrerequisites(), channel = handshakeChannel(factory, prerequisites: prerequisites)
        let original = try await channel.acquireInitialization()
        _ = try await completeHandshake(first, connection: firstConnection)
        #expect(try await channel.finishInitialization(original) === first)
        first.invalidate()
        let pending = Task { try await channel.ready() }
        _ = try await completeHandshake(second, connection: secondConnection)
        #expect(try await pending.value === second)
        let replacement = try await channel.acquireInitialization()
        #expect(replacement.id != original.id && factory.openings == 2 && prerequisites.checks == 2)
        #expect(first.exchanges.count == 2 && second.exchanges.count == 2)
    }

    @Test(arguments: RetainedOutcome.allCases)
    private func retainedOldFinalizationCannotClearOrReturnTheReplacement(_ outcome: RetainedOutcome) async throws {
        let first = ScriptedHandshakeLink(), second = ScriptedHandshakeLink(), factory = HandshakeLinkFactory()
        factory.append(first); factory.append(second)
        defer { factory.close() }
        let channel = handshakeChannel(factory)
        let original = try await channel.acquireInitialization()
        if outcome == .failure {
            let hello = try await first.nextExchange()
            try expectHello(hello, channel: "integration")
            try first.fail(hello)
            await #expect(throws: HandshakeFixtureFailure.injected) { try await channel.finishInitialization(original) }
        } else {
            _ = try await completeHandshake(first, connection: firstConnection)
            #expect(try await channel.finishInitialization(original) === first)
            first.invalidate()
        }
        let reconnect = Task { try await channel.ready() }
        _ = try await completeHandshake(second, connection: secondConnection)
        #expect(try await reconnect.value === second)
        let replacement = try await channel.acquireInitialization()
        #expect(replacement.id != original.id)
        // This is a retained production finalizer snapshot, not an NSXPC callback probe.
        if outcome == .failure {
            await #expect(throws: HandshakeFixtureFailure.injected) { try await channel.finishInitialization(original) }
        } else {
            #expect(try await channel.finishInitialization(original) === second)
        }
        let current = try await channel.acquireInitialization()
        #expect(current.id == replacement.id && factory.openings == 2)
        #expect(try await channel.finishInitialization(current) === second)
        #expect(second.isActive && second.exchanges.count == 2)
    }

    @Test func rawAuthenticationAcknowledgementFromRetiredLinkCannotAuthenticateItsReplacement() async throws {
        let first = ScriptedHandshakeLink(), second = ScriptedHandshakeLink(), factory = HandshakeLinkFactory()
        factory.append(first); factory.append(second)
        defer { factory.close() }
        let channel = handshakeChannel(factory)
        let original = try await channel.acquireInitialization()
        let oldAuth = try await completeHandshake(first, connection: firstConnection)
        #expect(try await channel.finishInitialization(original) === first)
        let oldAcknowledgement = try literalReply(to: oldAuth, kind: "authenticated", connection: firstConnection)
        first.invalidate()
        let pending = Task { try await channel.ready() }
        let hello = try await second.nextExchange()
        try expectHello(hello, channel: "integration")
        try second.reply(to: hello, packet: literalReply(to: hello, kind: "helloResponse", connection: secondConnection))
        let newAuth = try await second.nextExchange()
        try expectAuthentication(newAuth, hello: hello, channel: "integration", connection: secondConnection)
        #expect(newAuth.id != oldAuth.id && newAuth.connection != oldAuth.connection)
        try second.reply(to: newAuth, packet: oldAcknowledgement)
        await #expect(throws: NativeIPCFailure.malformedFrame) { try await pending.value }
        #expect(!second.isActive && second.exchanges.count == 2 && factory.openings == 2)
    }
}

private let handshakeCredential = Data(repeating: 0x39, count: 32)
private let firstConnection = "80D1F523-A982-4B55-9D27-F63A712E20C4"
private let secondConnection = "42AE9F17-0538-47C3-8254-BA685902E16D"
private let foreignCorrelation = "37B1064D-A826-4E09-BE68-0D2F439C751A"
private enum HelloFault: CaseIterable {
    case wrongChannel, invalidConnection, wrongCorrelation, malformedFrame, differentUser
    var expected: NativeIPCFailure { self == .wrongCorrelation || self == .malformedFrame ? .malformedFrame : .untrustedPeer }
}
private enum AcknowledgementFault: CaseIterable {
    case wrongCorrelation, changedGreeting
    var expected: NativeIPCFailure { self == .wrongCorrelation ? .malformedFrame : .untrustedPeer }
}
private enum RetainedOutcome: CaseIterable { case failure, success }
private enum HandshakeFixtureFailure: Error { case injected, unexpectedExchange, closed }

private typealias HandshakeChannel = NativeClientChannel<ScriptedHandshakeLink>
private func handshakeChannel(_ factory: HandshakeLinkFactory, channel: NativeChannel = .integration,
                              prerequisites: HandshakePrerequisites = HandshakePrerequisites()) -> HandshakeChannel {
    NativeClientChannel(deployment: prerequisites, channel: channel,
        credential: channel == .owner ? nil : handshakeCredential, makeLink: { factory.make() })
}

private func expectHello(_ request: ObservedHandshakeExchange, channel: String) throws {
    try #require(request.mode == "hello" && request.kind == "hello")
    #expect(request.channel == channel && request.connection == "" && request.credential == nil)
}
private func expectAuthentication(_ request: ObservedHandshakeExchange, hello: ObservedHandshakeExchange,
                                  channel: String, connection: String) throws {
    try #require(request.mode == "authenticate" && request.kind == "authenticate")
    #expect(request.channel == channel && request.connection == connection)
    #expect(request.credential == handshakeCredential && request.id != hello.id)
}
@discardableResult private func completeHandshake(_ link: ScriptedHandshakeLink, connection: String) async throws -> ObservedHandshakeExchange {
    let hello = try await link.nextExchange()
    try expectHello(hello, channel: "integration")
    try link.reply(to: hello, packet: literalReply(to: hello, kind: "helloResponse", connection: connection))
    let auth = try await link.nextExchange()
    try expectAuthentication(auth, hello: hello, channel: "integration", connection: connection)
    try link.reply(to: auth, packet: literalReply(to: auth, kind: "authenticated", connection: connection))
    return auth
}
private func literalReply(to request: ObservedHandshakeExchange, kind: String, channel: String = "integration",
                          connection: String, correlation: String? = nil) throws -> NativeOwnerPacket {
    let payload = try JSONSerialization.data(withJSONObject: ["channel": channel, "connectionID": connection])
    let frame = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "requestID": correlation ?? request.id,
        "kind": kind, "payload": payload.base64EncodedString()])
    return NativeOwnerPacket(frame: frame)
}

/// Synthetic prerequisite evidence never provides an NSXPC policy or opens a connection.
private final class HandshakePrerequisites: NativeDeploymentProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let allowed: Bool
    private var count = 0
    init(allowed: Bool = true) { self.allowed = allowed }
    var checks: Int { lock.withLock { count } }
    func requireQualifiedPrerequisites() throws {
        try lock.withLock { count += 1; if !allowed { throw ClientFailure.unavailable } }
    }
    func deployment() throws -> NativeDeploymentPolicy { throw ClientFailure.unavailable }
}
private final class HandshakeLinkFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [ScriptedHandshakeLink] = []
    private var count = 0
    var openings: Int { lock.withLock { count } }
    func append(_ link: ScriptedHandshakeLink) { lock.withLock { links.append(link) } }
    func make() -> ScriptedHandshakeLink {
        if let link = lock.withLock({ () -> ScriptedHandshakeLink? in
            let index = count; count += 1
            return index < links.count ? links[index] : nil
        }) { return link }
        let unexpected = ScriptedHandshakeLink(); unexpected.invalidate(); return unexpected
    }
    func close() { for link in lock.withLock({ links }) { link.invalidate() } }
}

private struct ObservedHandshakeExchange: Sendable {
    let id: String
    let mode: String
    let kind: String
    let channel: String
    let connection: String
    let credential: Data?
    init(_ mode: NativeExchange, packet: NativeOwnerPacket, credential: Data?) throws {
        guard packet.sensitive == nil,
              let outer = try JSONSerialization.jsonObject(with: packet.frame) as? [String: Any],
              Set(outer.keys) == ["protocolVersion", "requestID", "kind", "payload"], outer["protocolVersion"] as? Int == 1,
              let id = outer["requestID"] as? String, UUID(uuidString: id) != nil,
              let kind = outer["kind"] as? String, let body = outer["payload"] as? String,
              let bytes = Data(base64Encoded: body),
              let greeting = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
              Set(greeting.keys) == ["channel", "connectionID"],
              let channel = greeting["channel"], let connection = greeting["connectionID"] else {
            throw HandshakeFixtureFailure.unexpectedExchange
        }
        switch mode { case .hello: self.mode = "hello"; case .authenticate: self.mode = "authenticate"
        case .integration: self.mode = "integration"; case .owner: self.mode = "owner" }
        self.id = id; self.kind = kind; self.channel = channel; self.connection = connection; self.credential = credential
    }
}
private struct ScriptedHandshakeReply: Sendable { let packet: NativeOwnerPacket; let retire: Bool }

/// One lock owns observations and reply continuations. Resumption happens after removal,
/// outside the lock; barriers acknowledge actual exchanges rather than task scheduling.
private final class ScriptedHandshakeLink: NativeClientLinking, @unchecked Sendable {
    private let lock = NSLock()
    private let sameUser: Bool
    private let retireOnBind: Bool
    private var active = true
    private var calls: [ObservedHandshakeExchange] = []
    private var bound: [String] = []
    private var retiredReply = false
    private var queued: [ObservedHandshakeExchange] = []
    private var observer: CheckedContinuation<ObservedHandshakeExchange, any Error>?
    private var pending: [String: CheckedContinuation<ScriptedHandshakeReply, any Error>] = [:]
    init(sameUser: Bool = true, retireOnBind: Bool = false) { self.sameUser = sameUser; self.retireOnBind = retireOnBind }
    var isActive: Bool { lock.withLock { active } }
    var sameUserPeer: Bool { lock.withLock { active && sameUser } }
    var exchanges: [ObservedHandshakeExchange] { lock.withLock { calls } }
    var bindings: [String] { lock.withLock { bound } }
    var retiredBeforeReturningReply: Bool { lock.withLock { retiredReply } }
    func bindConsent(connectionID: String) {
        lock.withLock { bound.append(connectionID); if retireOnBind { active = false } }
    }
    func invalidate() {
        let waiting = lock.withLock { () -> ([CheckedContinuation<ScriptedHandshakeReply, any Error>], CheckedContinuation<ObservedHandshakeExchange, any Error>?) in
            active = false
            let replies = Array(pending.values), observing = observer
            pending.removeAll(); queued.removeAll(); observer = nil
            return (replies, observing)
        }
        for reply in waiting.0 { reply.resume(throwing: HandshakeFixtureFailure.closed) }
        waiting.1?.resume(throwing: HandshakeFixtureFailure.closed)
    }
    func exchange(_ mode: NativeExchange, packet: NativeOwnerPacket, credential: Data?) async throws -> NativeOwnerPacket {
        let request = try ObservedHandshakeExchange(mode, packet: packet, credential: credential)
        let result: ScriptedHandshakeReply = try await withCheckedThrowingContinuation { continuation in
            let admission = lock.withLock { () -> (Bool, CheckedContinuation<ObservedHandshakeExchange, any Error>?) in
                calls.append(request)
                guard active else { return (false, nil) }
                pending[request.id] = continuation
                let observing = observer; observer = nil
                if observing == nil { queued.append(request) }
                return (true, observing)
            }
            if admission.0 { admission.1?.resume(returning: request) }
            else { continuation.resume(throwing: ClientFailure.unavailable) }
        }
        if result.retire { lock.withLock { active = false; retiredReply = true } }
        return result.packet
    }
    func nextExchange() async throws -> ObservedHandshakeExchange {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<ObservedHandshakeExchange, any Error>? in
                if !queued.isEmpty { return .success(queued.removeFirst()) }
                guard active, observer == nil else { return .failure(HandshakeFixtureFailure.closed) }
                observer = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }
    func reply(to request: ObservedHandshakeExchange, packet: NativeOwnerPacket, retire: Bool = false) throws {
        let continuation = try #require(lock.withLock { pending.removeValue(forKey: request.id) })
        continuation.resume(returning: ScriptedHandshakeReply(packet: packet, retire: retire))
    }
    func fail(_ request: ObservedHandshakeExchange) throws {
        let continuation = try #require(lock.withLock { pending.removeValue(forKey: request.id) })
        continuation.resume(throwing: HandshakeFixtureFailure.injected)
    }
}

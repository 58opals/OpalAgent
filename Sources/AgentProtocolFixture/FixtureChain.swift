#if DEBUG
import CryptoKit
import Foundation
import OpalBaseCore
@testable import AgentServiceCore

/// Synthetic raw public-chain inputs only. No operation state or engine outcome is mocked.
final class FixtureClock: PaymentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = PaymentClockReading(wall: 1_000, monotonic: 100)
    func read() -> PaymentClockReading { lock.withLock { value } }
    func advance(_ seconds: UInt64) { lock.withLock { value.wall += Int64(seconds); value.monotonic += seconds } }
}
final class FixtureAnchor: ContinuityAnchorStore, @unchecked Sendable {
    let path: URL
    private let lock = NSLock()
    init(_ path: URL) { self.path = path }
    func read() throws -> ContinuityAnchor? {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return try JSONDecoder().decode(ContinuityAnchor.self, from: Data(contentsOf: path))
        }
    }
    func write(_ value: ContinuityAnchor) throws {
        try lock.withLock { try JSONEncoder().encode(value).write(to: path, options: .atomic) }
    }
}
final class FixtureKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var present = true
    private var accessCount = 0
    var reads: Int { lock.withLock { accessCount } }
    var isPresent: Bool { lock.withLock { present } }
    func setPresent(_ value: Bool) { lock.withLock { present = value } }
    func read() -> WrappingKeyAvailability {
        lock.withLock {
            accessCount += 1
            return present ? .available(SymmetricKey(data: Data(repeating: 0x42, count: 32))) : .missing
        }
    }
}
actor FixtureRelayLatch {
    private var opened = true
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func close() { opened = false }
    func wait() async throws {
        try Task.checkCancellation()
        guard !opened else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func open() { opened = true; let pending = waiters; waiters = [:]; for waiter in pending.values { waiter.resume() } }
}
final class FixturePublicChain: @unchecked Sendable {
    private struct Entry { var bytes: Data; var transaction: OpalBase.Transaction; var height: Int }
    private let lock = NSLock()
    private var entries: [Data: Entry] = [:]
    private var unspents: [OpalBase.Transaction.Output.Unspent] = []
    private var sent: [Data] = []
    private var queryCount = 0
    private var view = "view-A"
    private var fresh = true
    private var accepted = false
    let relayLatch = FixtureRelayLatch()
    private let clock: FixtureClock
    init(clock: FixtureClock) { self.clock = clock }
    var sentBytes: [Data] { lock.withLock { sent } }
    var counts: (queries: Int, relays: Int) { lock.withLock { (queryCount, sent.count) } }
    private func query() { lock.withLock { queryCount += 1 } }
    func setAccepted(_ value: Bool) { lock.withLock { accepted = value } }
    func setFresh(_ value: Bool) { lock.withLock { fresh = value } }
    func setView(_ value: String) { lock.withLock { view = value } }
    func context() -> BaseChainContext {
        lock.withLock { BaseChainContext(network: "mainnet", source: "raw-fixture", view: view,
            tip: "tip-10", tipHeight: 10, observedAt: clock.read().wall, complete: true, fresh: fresh) }
    }
    func publish(_ bytes: Data, height: Int, consumeInputs: Bool = true) throws {
        let transaction = try OpalBase.Transaction.decode(from: bytes).transaction
        let hash = Self.hash(bytes)
        lock.withLock {
            entries[hash] = Entry(bytes: bytes, transaction: transaction, height: height)
            if consumeInputs {
                let inputs = transaction.inputs
                unspents.removeAll { utxo in inputs.contains { $0.previousTransactionHash == utxo.previousTransactionHash && $0.previousTransactionOutputIndex == utxo.previousTransactionOutputIndex } }
            }
            for (index, output) in transaction.outputs.enumerated() {
                if !unspents.contains(where: { $0.previousTransactionHash.naturalOrder == hash && $0.previousTransactionOutputIndex == UInt32(index) }) {
                    unspents.append(.init(value: output.value, lockingScript: output.lockingScript,
                        previousTransactionHash: .init(naturalOrder: hash), previousTransactionOutputIndex: UInt32(index)))
                }
            }
        }
    }
    func remove(_ bytes: Data) {
        lock.withLock {
            let hash = Self.hash(bytes); entries.removeValue(forKey: hash)
            unspents.removeAll { $0.previousTransactionHash.naturalOrder == hash }
        }
    }
    private func script(_ address: String) throws -> Data {
        OpalBase.Transaction.Output(value: 0, address: try OpalBase.Address(address)).lockingScript
    }
    private func history(_ address: String, includeUnconfirmed: Bool) throws -> [OpalBase.Network.TransactionHistoryEntry] {
        query()
        let target = try script(address)
        return lock.withLock {
            entries.compactMap { hash, entry in
                guard includeUnconfirmed || entry.height > 0 else { return nil }
                let receives = entry.transaction.outputs.contains { $0.lockingScript == target }
                let spends = entry.transaction.inputs.contains { input in
                    guard let previous = entries[input.previousTransactionHash.naturalOrder],
                          Int(input.previousTransactionOutputIndex) < previous.transaction.outputs.count else { return false }
                    return previous.transaction.outputs[Int(input.previousTransactionOutputIndex)].lockingScript == target
                }
                guard receives || spends else { return nil }
                return .init(transactionIdentifier: Self.hex(Data(hash.reversed())), blockHeight: entry.height, fee: nil)
            }
        }
    }
    func operations() -> OpalBase.WalletPublicChainOperations {
        let reader = OpalBase.Network.AddressReader(fetchBalance: { address, _ in
            self.query()
            let target = try self.script(address)
            return self.lock.withLock {
                let outputs = self.unspents.filter { $0.lockingScript == target }
                return .init(confirmed: outputs.reduce(0) { $0 + $1.value }, unconfirmed: 0)
            }
        }, fetchUnspentOutputs: { address, _ in
            self.query()
            let target = try self.script(address)
            return self.lock.withLock { self.unspents.filter { $0.lockingScript == target } }
        }, fetchHistory: { try self.history($0, includeUnconfirmed: $1) }, fetchFirstUse: { _ in self.query(); return nil },
            fetchMempoolTransactions: { try self.history($0, includeUnconfirmed: true).filter { $0.blockHeight == 0 } },
            fetchScriptHash: { self.query(); return $0 }, subscribeToAddress: { _ in self.query(); return AsyncThrowingStream { $0.finish() } })
        let client = OpalBase.Network.TransactionClient(broadcastTransaction: { raw in
            let bytes = try Self.data(raw)
            self.lock.withLock { self.sent.append(bytes) }
            try await self.relayLatch.wait()
            if self.lock.withLock({ self.accepted }) { return Self.hex(Data(Self.hash(bytes).reversed())) }
            throw CancellationError() // Request ownership happened; the remote result is unknown.
        }, fetchConfirmations: { _ in self.query(); return nil }, fetchConfirmationStatus: { hash in
            self.query()
            let height = self.lock.withLock { self.entries[hash.naturalOrder]?.height ?? 0 }
            return .init(transactionHash: hash, transactionHeight: height > 0 ? height : nil,
                tipHeight: 10, confirmations: height > 0 ? UInt(11 - height) : 0)
        })
        return .init(addressReader: reader, transactionClient: client,
            transactionReader: .init { hash in
                self.query()
                guard let bytes = self.lock.withLock({ self.entries[hash.naturalOrder]?.bytes }) else { throw PaymentFailure.networkUnavailable }
                return bytes
            })
    }
    func proof(hash: OpalBase.Transaction.Hash, height: UInt32, context: BaseChainContext) -> BaseCanonicalTransactionProof? {
        return BaseCanonicalTransactionProof(context: context, height: height,
            header: .init(version: 1, previousBlockHash: Data(repeating: 0, count: 32), merkleRoot: hash.naturalOrder,
                time: 1, bits: 0x1d00ffff, nonce: 0),
            inclusion: .init(blockHeight: height, position: 0, branch: []))
    }
    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: Data(SHA256.hash(data: data)))) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func data(_ hex: String) throws -> Data {
        var bytes = Data(); var offset = hex.startIndex
        while offset < hex.endIndex {
            let next = hex.index(offset, offsetBy: 2)
            guard let value = UInt8(hex[offset..<next], radix: 16) else { throw PaymentFailure.invalidRequest }
            bytes.append(value); offset = next
        }
        return bytes
    }
}
#endif

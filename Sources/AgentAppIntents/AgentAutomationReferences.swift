// AgentAutomationReferences.swift

import AgentValues
import CryptoKit
import Foundation

func automationIdentity<T: Encodable>(_ fields: [String], encoded value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(AutomationIdentityPayload(fields: fields, value: value))
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
func automationAccountID(binding: AgentAutomationBinding, account: AccountScope) throws -> String {
    try automationIdentity(["agent-account-v1", binding.wallet.walletID, binding.wallet.network.rawValue,
        binding.integrationID, binding.grantID, String(binding.walletGeneration), account.accountID],
        encoded: Optional<SnapshotObservation>.none)
}
func automationExact<T: BinaryInteger>(_ value: T) throws -> Int {
    guard let result = Int(exactly: value) else { throw AgentAutomationFailure.invalidResponse }
    return result
}
private struct AutomationIdentityPayload<T: Encodable>: Encodable { let fields: [String]; let value: T }

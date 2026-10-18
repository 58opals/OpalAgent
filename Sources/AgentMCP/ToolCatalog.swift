import AgentValues
import MCP

/// Discovery describes protocol shape only. Tools and annotations confer no wallet authority.
public enum ToolCatalog {
    public static func tools() -> [Tool] {
        CapabilityMethod.allCases.map { method in
            Tool(name: method.rawValue, description: description(method), inputSchema: ToolSchema.input(method),
                 outputSchema: ToolSchema.output(method))
        }
    }
    private static func description(_ method: CapabilityMethod) -> String {
        let purpose: String
        switch method {
        case .listWallets: purpose = "List authorized wallet identities."
        case .listAccounts: purpose = "List authorized accounts for an explicit wallet and network."
        case .getBalance: purpose = "Read a retained balance observation; never synchronize."
        case .listTransactions: purpose = "Page retained transaction observations; unknown deltas or confirmations remain null."
        case .listUTXOs: purpose = "Page retained UTXOs with privacy-preserving reservation status."
        case .getSyncStatus: purpose = "Read cached synchronization provenance and current readiness; never start work."
        case .synchronizeAccount: purpose = "Request one keyed synchronization effect; retain its key before calling and poll its operation."
        case .createReceiveRequest: purpose = "Request one keyed receive allocation; retain its key before calling and poll its operation."
        case .preparePayment: purpose = "Prepare one immutable payment using an address, exact decimal-string satoshis and fee rate."
        case .submitPayment: purpose = "Submit an existing payment operation under current service policy; may await separate owner approval."
        case .getOperation: purpose = "Read one retained operation by identity or its original effect key; never retry effects."
        case .cancelOperation: purpose = "Cancel provably unsubmitted work; cannot recall an admitted transaction or unissue an address."
        }
        return purpose + " Requires current service scope: " + method.requiredScope.rawValue + "."
    }
}

private enum ToolSchema {
    static func object(_ properties: [String: Value], required: [String]? = nil) -> Value {
        .object(["type": .string("object"), "properties": .object(properties),
            "required": .array((required ?? properties.keys.sorted()).map(Value.string)), "additionalProperties": .bool(false)])
    }
    static func string(maximum: Int = 2_048, minimum: Int = 1, pattern: String? = nil) -> Value {
        var fields: [String: Value] = ["type": .string("string"), "minLength": .int(minimum), "maxLength": .int(maximum)]
        if let pattern { fields["pattern"] = .string(pattern) }; return .object(fields)
    }
    static func values(_ strings: [String]) -> Value { .object(["type": .string("string"), "enum": .array(strings.map(Value.string))]) }
    static func integer(_ minimum: Int = 0, maximum: Int? = nil) -> Value {
        var fields: [String: Value] = ["type": .string("integer"), "minimum": .int(minimum)]
        if let maximum { fields["maximum"] = .int(maximum) }; return .object(fields)
    }
    static func array(_ item: Value, maximum: Int? = nil) -> Value {
        var fields: [String: Value] = ["type": .string("array"), "items": item]
        if let maximum { fields["maxItems"] = .int(maximum) }; return .object(fields)
    }
    static func nullable(_ item: Value) -> Value { .object(["anyOf": .array([item, .object(["type": .string("null")])])]) }
    static func ref(_ name: String) -> Value { .object(["$ref": .string("#/$defs/" + name)]) }
    static let boolean = Value.object(["type": .string("boolean")])
    static let identifier = string(pattern: "^\\S+$")
    static let key = string(maximum: 32, minimum: 32, pattern: "^[0-9a-f]{32}$")
    static let positiveDecimal = string(maximum: 19, pattern: "^[1-9][0-9]*$")
    static let decimal = string(maximum: 20, pattern: "^(0|[1-9][0-9]*)$")
    static let signedDecimal = string(maximum: 20, pattern: "^(0|-?[1-9][0-9]*)$")
    static let hash = string(maximum: 64, minimum: 64, pattern: "^[0-9a-f]{64}$")
    static let script = string(maximum: 20_000, pattern: "^([0-9a-f]{2})+$")
    static let wallet = object(["walletID": identifier, "network": values(WalletNetwork.allCases.map(\.rawValue))])
    static let account = object(["wallet": wallet, "accountID": identifier])
    static let page = object(["limit": .object(["type": .string("integer"), "minimum": .int(1),
        "maximum": .int(PageRequest.maximumCount), "default": .int(PageRequest.maximumCount)]), "cursor": identifier], required: [])
    static let selector = object(["account": account, "operationID": identifier])
    static let keyed = object(["account": account, "requestKey": key])
    static let effect = values(EffectKind.allCases.map(\.rawValue))

    static func input(_ method: CapabilityMethod) -> Value {
        switch method {
        case .listWallets: page
        case .listAccounts: object(["wallet": wallet, "page": page])
        case .getBalance, .getSyncStatus: account
        case .listTransactions, .listUTXOs: object(["account": account, "page": page])
        case .synchronizeAccount, .createReceiveRequest: keyed
        case .preparePayment: object(["account": account, "requestKey": key, "destinationAddress": string(maximum: 512),
            "amountSatoshis": string(maximum: 16, pattern: "^[1-9][0-9]*$"), "feeRateSatoshisPerByte": positiveDecimal,
            "expiresAt": integer(1)], required: ["account", "requestKey", "destinationAddress", "amountSatoshis"])
        case .submitPayment, .cancelOperation: selector
        case .getOperation:
            .object(["type": .string("object"), "oneOf": .array([
                object(["operation": selector]), object(["account": account, "effect": effect, "requestKey": key])])])
        }
    }
    private static func paged(_ item: Value) -> Value { object(["items": array(item, maximum: PageRequest.maximumCount), "nextCursor": nullable(identifier)]) }
    private static func accountPage(_ item: Value) -> Value {
        object(["account": account, "observation": ref("observation"), "page": paged(item), "readiness": ref("readiness")])
    }
    static func output(_ method: CapabilityMethod) -> Value {
        let result: Value
        switch method {
        case .listWallets: result = paged(object(["scope": wallet, "availability": values(["unavailable", "recoveryRequired", "restricted", "enabled"])]))
        case .listAccounts: result = object(["wallet": wallet, "page": paged(object(["scope": account, "readiness": ref("readiness")]))])
        case .getBalance: result = object(["account": account, "totalSatoshis": decimal, "observation": ref("observation"), "readiness": ref("readiness")])
        case .listTransactions: result = accountPage(object(["transactionID": hash, "deltaSatoshis": nullable(signedDecimal),
            "confirmations": nullable(integer()), "height": nullable(integer()), "status": values(["unknown", "discovered", "pending", "confirmed", "failed"])]))
        case .listUTXOs: result = accountPage(object(["outpoint": ref("outpoint"), "amountSatoshis": decimal,
            "reservation": .object(["oneOf": .array([
                object(["state": values(["unreserved", "otherOperation"])]),
                object(["state": values(["visibleOperation"]), "operationID": identifier])])])]))
        case .getSyncStatus: result = object(["account": account, "observation": nullable(ref("observation")), "readiness": ref("readiness")])
        case .synchronizeAccount: result = ref("sync")
        case .createReceiveRequest: result = ref("receive")
        case .preparePayment, .submitPayment: result = ref("payment")
        case .getOperation, .cancelOperation:
            result = .object(["oneOf": .array([
                object(["effect": values(["synchronizeAccount"]), "operation": ref("sync")]),
                object(["effect": values(["createReceiveRequest"]), "operation": ref("receive")]),
                object(["effect": values(["preparePayment"]), "operation": ref("payment")])])])
        }
        let success = object(["ok": .object(["const": .bool(true)]), "method": values([method.rawValue]), "result": result])
        let failure = object(["ok": .object(["const": .bool(false)]), "error": object(["code": values([
            "unavailable", "invalidRequest", "conflictingRequest", "approvalNeeded", "accountRestricted", "staleContext", "leaseExpired",
            "transportBusy", "networkUnavailable", "keyUnavailable", "recoveryRequired", "invalidTransition", "relayNotEligible"])])])
        return .object(["type": .string("object"), "oneOf": .array([success, failure]), "$defs": .object(definitions)])
    }
    private static var definitions: [String: Value] {
        let blocker = values(["unavailable", "authorizationUnavailable", "continuityUnavailable", "historyIncomplete", "custodyUnavailable",
            "accountRestricted", "keyUnavailable", "networkUnavailable", "staleSnapshot", "incompleteSnapshot", "approvalNeeded", "leaseExpired",
            "transportBusy", "staleContext", "staleEvidence", "inconclusiveEvidence", "automaticRelayBudgetExhausted", "evidenceDefect", "leaseCleanupFailed", "relayNotEligible"])
        let reason = values(["cancelled", "invalidated", "failed", "rejected", "expired", "authorizationInvalidated", "failedUnsubmitted", "reconciledAccepted", "reconciledConflict"])
        let support = values(["unknown", "unsupported", "supported", "notApplicable"])
        return [
            "observation": object(["providerID": identifier, "viewID": identifier, "chainTip": identifier, "sequence": decimal,
                "observedAt": integer(), "generation": decimal, "fresh": boolean, "complete": boolean]),
            "readiness": object(["state": values(["unavailable", "blocked", "ready"]), "blockers": array(blocker, maximum: 21)]),
            "identity": object(["selector": selector, "requestKey": key]),
            "outpoint": object(["transactionID": hash, "outputIndex": integer(0, maximum: Int(UInt32.max))]),
            "sync": object(["identity": ref("identity"), "state": values(["pending", "completed", "closed"]),
                "observation": nullable(ref("observation")), "closeReason": nullable(reason), "blocker": nullable(blocker)]),
            "receive": object(["identity": ref("identity"), "state": values(["pending", "allocated", "closed"]),
                "allocation": nullable(object(["address": string(maximum: 512), "index": integer(0, maximum: Int(0x7fff_ffff))])),
                "closeReason": nullable(reason), "blocker": nullable(blocker)]),
            "preview": object(["canonicalDestinationAddress": string(maximum: 512), "destinationScriptHex": script,
                "amountSatoshis": decimal, "feeSatoshis": decimal, "selectedInputs": array(ref("outpoint")),
                "change": array(object(["lockingScriptHex": script, "amountSatoshis": decimal])),
                "templateDigest": hash, "leaseDeadline": integer(1)]),
            "payment": object(["identity": ref("identity"), "request": object(["account": account, "requestKey": key,
                "destinationAddress": string(maximum: 512), "amountSatoshis": decimal, "feeRateSatoshisPerByte": positiveDecimal,
                "expiresAt": nullable(integer(1))]),
                "state": values(["preparing", "prepared", "pendingApproval", "ready", "submitting", "uncertain", "accepted", "recoveryRequired", "closed"]),
                "preview": nullable(ref("preview")), "terminalReason": nullable(reason),
                "closures": array(object(["reason": reason, "evidenceRevision": decimal, "support": support])),
                "accountRestriction": values(["unavailable", "clear", "held"]), "liabilityUnresolved": boolean,
                "blocker": nullable(blocker), "evidence": object(["revision": decimal, "support": support, "observation": nullable(ref("observation"))]),
                "ordinaryAdmissions": string(maximum: 1, pattern: "^[0-3]$"),
                "latestAttempt": nullable(object(["attemptID": identifier, "number": decimal, "route": values(["ordinary", "owner"]),
                    "outcome": values(["admitted", "unknown", "accepted", "rejected", "noHandoff"]), "admittedAt": integer(), "nextEligibleAt": nullable(integer())])),
                "lastReconciliationAt": nullable(integer()), "observationSequence": decimal, "transactionID": nullable(hash)])
        ]
    }
}

import AgentValues

/// Wallet-command parsing is independent of optional MCP capability metadata.
enum ToolArgumentError: Error, Equatable { case invalid }

private struct ToolObject {
    let fields: [String: MCPValue]
    init(_ value: MCPValue) throws {
        guard case .object(let fields) = value else { throw ToolArgumentError.invalid }
        self.fields = fields
    }
    init(_ fields: [String: MCPValue]) { self.fields = fields }
    func only(_ allowed: Set<String>) throws {
        guard Set(fields.keys).isSubset(of: allowed) else { throw ToolArgumentError.invalid }
    }
    func required(_ key: String) throws -> MCPValue {
        guard let value = fields[key] else { throw ToolArgumentError.invalid }; return value
    }
    func string(_ key: String) throws -> String {
        guard case .string(let value) = try required(key) else { throw ToolArgumentError.invalid }; return value
    }
    func optionalString(_ key: String) throws -> String? {
        guard fields[key] != nil else { return nil }; return try string(key)
    }
    func integer(_ key: String) throws -> Int {
        guard case .int(let value) = try required(key) else { throw ToolArgumentError.invalid }; return value
    }
    func positiveDecimal(_ key: String, default fallback: Int64? = nil) throws -> Int64 {
        if fields[key] == nil, let fallback { return fallback }
        let spelling = try string(key)
        guard spelling.utf8.count <= 19, let first = spelling.utf8.first, (49...57).contains(first),
              spelling.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(spelling), value > 0 else { throw ToolArgumentError.invalid }
        return value
    }
}

enum ToolInput {
    static func call(_ method: CapabilityMethod, arguments: [String: MCPValue]?) throws -> CapabilityCall {
        let object = ToolObject(arguments ?? [:])
        switch method {
        case .listWallets: return .listWallets(try page(.object(object.fields)))
        case .listAccounts:
            try object.only(["wallet", "page"])
            return .listAccounts(try WalletPageRequest(wallet: wallet(object.required("wallet")), page: page(object.required("page"))))
        case .getBalance: return .getBalance(try account(.object(object.fields)))
        case .listTransactions: return .listTransactions(try accountPage(object))
        case .listUTXOs: return .listUTXOs(try accountPage(object))
        case .getSyncStatus: return .getSyncStatus(try account(.object(object.fields)))
        case .synchronizeAccount: return .synchronizeAccount(try keyed(object))
        case .createReceiveRequest: return .createReceiveRequest(try keyed(object))
        case .preparePayment:
            try object.only(["account", "requestKey", "destinationAddress", "amountSatoshis", "feeRateSatoshisPerByte", "expiresAt"])
            let expiry: Int64?
            if object.fields["expiresAt"] == nil { expiry = nil }
            else { expiry = Int64(exactly: try object.integer("expiresAt")); guard expiry != nil else { throw ToolArgumentError.invalid } }
            return .preparePayment(try PreparePaymentRequest(account: account(object.required("account")),
                requestKey: RequestKey(object.string("requestKey")), destinationAddress: object.string("destinationAddress"),
                amountSatoshis: object.positiveDecimal("amountSatoshis"),
                feeRateSatoshisPerByte: object.positiveDecimal("feeRateSatoshisPerByte", default: 1), expiresAt: expiry))
        case .submitPayment: return .submitPayment(try selector(.object(object.fields)))
        case .getOperation:
            try object.only(["operation", "account", "effect", "requestKey"])
            if let selected = object.fields["operation"] {
                guard object.fields.count == 1 else { throw ToolArgumentError.invalid }
                return .getOperation(.operation(try selector(selected)))
            }
            guard let effect = EffectKind(rawValue: try object.string("effect")) else { throw ToolArgumentError.invalid }
            return .getOperation(.request(account: try account(object.required("account")), effect: effect,
                key: try RequestKey(object.string("requestKey"))))
        case .cancelOperation: return .cancelOperation(try selector(.object(object.fields)))
        }
    }
    private static func wallet(_ value: MCPValue) throws -> WalletScope {
        let object = try ToolObject(value); try object.only(["walletID", "network"])
        guard let network = WalletNetwork(rawValue: try object.string("network")) else { throw ToolArgumentError.invalid }
        return try WalletScope(walletID: object.string("walletID"), network: network)
    }
    private static func account(_ value: MCPValue) throws -> AccountScope {
        let object = try ToolObject(value); try object.only(["wallet", "accountID"])
        return try AccountScope(wallet: wallet(object.required("wallet")), accountID: object.string("accountID"))
    }
    private static func page(_ value: MCPValue) throws -> PageRequest {
        let object = try ToolObject(value); try object.only(["limit", "cursor"])
        return try PageRequest(limit: object.fields["limit"] == nil ? PageRequest.maximumCount : object.integer("limit"),
                               cursor: object.optionalString("cursor"))
    }
    private static func accountPage(_ object: ToolObject) throws -> AccountPageRequest {
        try object.only(["account", "page"])
        return try AccountPageRequest(account: account(object.required("account")), page: page(object.required("page")))
    }
    private static func keyed(_ object: ToolObject) throws -> KeyedAccountRequest {
        try object.only(["account", "requestKey"])
        return try KeyedAccountRequest(account: account(object.required("account")), requestKey: RequestKey(object.string("requestKey")))
    }
    private static func selector(_ value: MCPValue) throws -> OperationSelector {
        let object = try ToolObject(value); try object.only(["account", "operationID"])
        return try OperationSelector(account: account(object.required("account")), operationID: object.string("operationID"))
    }
}

/// Explicit scalar mapping keeps UInt64 contexts out of floating-point JSON. Monetary
/// quantities and UInt64 context counters are decimal strings; no signing data is available here.
enum ToolOutput {
    static func success(_ result: CapabilityResult) throws -> MCPValue {
        .object(["ok": .bool(true), "method": .string(result.method.rawValue), "result": try payload(result)])
    }
    static func failure(_ code: ServiceProblemCode) -> MCPValue {
        .object(["ok": .bool(false), "error": .object(["code": .string(code.rawValue)])])
    }
    private static func payload(_ result: CapabilityResult) throws -> MCPValue {
        switch result {
        case .listWallets(let v): return page(v) { .object(["scope": wallet($0.scope), "availability": .string($0.availability.rawValue)]) }
        case .listAccounts(let v): return .object(["wallet": wallet(v.wallet), "page": page(v.page) {
            .object(["scope": account($0.scope), "readiness": readiness($0.readiness)])
        }])
        case .getBalance(let v): return .object(["account": account(v.account), "totalSatoshis": .string(String(v.totalSatoshis)),
            "observation": try observation(v.observation), "readiness": readiness(v.readiness)])
        case .listTransactions(let v): return try accountPage(v) { value in
            .object(["transactionID": .string(value.transactionID), "deltaSatoshis": optional(value.deltaSatoshis) { .string(String($0)) },
                "confirmations": optional(value.confirmations) { .int(Int($0)) }, "height": optional(value.height) { .int(Int($0)) },
                "status": .string(value.status.rawValue)])
        }
        case .listUTXOs(let v): return try accountPage(v) { value in
            .object(["outpoint": outpoint(value.outpoint), "amountSatoshis": .string(String(value.amountSatoshis)),
                     "reservation": reservation(value.reservation)])
        }
        case .getSyncStatus(let v): return .object(["account": account(v.account),
            "observation": try optional(v.observation, observation), "readiness": readiness(v.readiness)])
        case .synchronizeAccount(let v): return try sync(v)
        case .createReceiveRequest(let v): return receive(v)
        case .preparePayment(let v), .submitPayment(let v): return try payment(v)
        case .getOperation(let v), .cancelOperation(let v):
            let value: MCPValue
            switch v {
            case .synchronization(let item): value = try sync(item)
            case .receive(let item): value = receive(item)
            case .payment(let item): value = try payment(item)
            }
            return .object(["effect": .string(v.effect.rawValue), "operation": value])
        }
    }
    private static func wallet(_ v: WalletScope) -> MCPValue { .object(["walletID": .string(v.walletID), "network": .string(v.network.rawValue)]) }
    private static func account(_ v: AccountScope) -> MCPValue { .object(["wallet": wallet(v.wallet), "accountID": .string(v.accountID)]) }
    private static func selector(_ v: OperationSelector) -> MCPValue { .object(["account": account(v.account), "operationID": .string(v.operationID)]) }
    private static func identity(_ v: OperationIdentity) -> MCPValue {
        .object(["selector": selector(v.selector), "requestKey": .string(v.requestKey.value)])
    }
    private static func observation(_ v: SnapshotObservation) throws -> MCPValue {
        .object(["providerID": .string(v.providerID), "viewID": .string(v.viewID), "chainTip": .string(v.chainTip),
            "sequence": .string(String(v.sequence)), "observedAt": try integer(v.observedAt),
            "generation": .string(String(v.generation)), "fresh": .bool(v.fresh), "complete": .bool(v.complete)])
    }
    private static func readiness(_ v: AccountReadiness) -> MCPValue {
        .object(["state": .string(v.state.rawValue), "blockers": .array(v.blockers.map { .string($0.rawValue) })])
    }
    private static func outpoint(_ v: Outpoint) -> MCPValue { .object(["transactionID": .string(v.transactionID), "outputIndex": .int(Int(v.outputIndex))]) }
    private static func reservation(_ v: UTXOReservation) -> MCPValue {
        switch v {
        case .unreserved: .object(["state": .string("unreserved")])
        case .visibleOperation(let id): .object(["state": .string("visibleOperation"), "operationID": .string(id)])
        case .otherOperation: .object(["state": .string("otherOperation")])
        }
    }
    private static func page<T: Codable & Sendable & Equatable>(_ v: CapabilityPage<T>, _ project: (T) throws -> MCPValue) rethrows -> MCPValue {
        .object(["items": .array(try v.items.map(project)), "nextCursor": optional(v.nextCursor) { .string($0) }])
    }
    private static func accountPage<T: Codable & Sendable & Equatable>(_ v: AccountPage<T>, _ project: (T) throws -> MCPValue) throws -> MCPValue {
        .object(["account": account(v.account), "observation": try observation(v.observation),
            "page": try page(v.page, project), "readiness": readiness(v.readiness)])
    }
    private static func sync(_ v: SyncOperation) throws -> MCPValue {
        .object(["identity": identity(v.identity), "state": .string(v.state.rawValue),
            "observation": try optional(v.observation, observation), "closeReason": optional(v.closeReason) { .string($0.rawValue) },
            "blocker": optional(v.blocker) { .string($0.rawValue) }])
    }
    private static func receive(_ v: ReceiveOperation) -> MCPValue {
        .object(["identity": identity(v.identity), "state": .string(v.state.rawValue),
            "allocation": optional(v.allocation) { .object(["address": .string($0.address), "index": .int(Int($0.index))]) },
            "closeReason": optional(v.closeReason) { .string($0.rawValue) }, "blocker": optional(v.blocker) { .string($0.rawValue) }])
    }
    private static func request(_ v: PreparePaymentRequest) throws -> MCPValue {
        .object(["account": account(v.account), "requestKey": .string(v.requestKey.value), "destinationAddress": .string(v.destinationAddress),
            "amountSatoshis": .string(String(v.amountSatoshis)), "feeRateSatoshisPerByte": .string(String(v.feeRateSatoshisPerByte)),
            "expiresAt": try optional(v.expiresAt, integer)])
    }
    private static func preview(_ v: PaymentPreviewProjection) throws -> MCPValue {
        .object(["canonicalDestinationAddress": .string(v.canonicalDestinationAddress), "destinationScriptHex": .string(v.destinationScriptHex),
            "amountSatoshis": .string(String(v.amountSatoshis)), "feeSatoshis": .string(String(v.feeSatoshis)),
            "selectedInputs": .array(v.selectedInputs.map(outpoint)), "change": .array(v.change.map {
                .object(["lockingScriptHex": .string($0.lockingScriptHex), "amountSatoshis": .string(String($0.amountSatoshis))])
            }), "templateDigest": .string(v.templateDigest), "leaseDeadline": try integer(v.leaseDeadline)])
    }
    private static func attempt(_ v: RelayAttemptProjection) throws -> MCPValue {
        .object(["attemptID": .string(v.attemptID), "number": .string(String(v.number)), "route": .string(v.route.rawValue),
            "outcome": .string(v.outcome.rawValue), "admittedAt": try integer(v.admittedAt),
            "nextEligibleAt": try optional(v.nextEligibleAt, integer)])
    }
    private static func payment(_ v: PaymentOperation) throws -> MCPValue {
        .object(["identity": identity(v.identity), "request": try request(v.request), "state": .string(v.state.rawValue),
            "preview": try optional(v.preview, preview), "terminalReason": optional(v.terminalReason) { .string($0.rawValue) },
            "closures": .array(v.closures.map { .object(["reason": .string($0.reason.rawValue),
                "evidenceRevision": .string(String($0.evidenceRevision)), "support": .string($0.support.rawValue)]) }),
            "accountRestriction": .string(v.accountRestriction.rawValue), "liabilityUnresolved": .bool(v.liabilityUnresolved),
            "blocker": optional(v.blocker) { .string($0.rawValue) },
            "evidence": .object(["revision": .string(String(v.evidence.revision)), "support": .string(v.evidence.support.rawValue),
                "observation": try optional(v.evidence.observation, observation)]),
            "ordinaryAdmissions": .string(String(v.ordinaryAdmissions)), "latestAttempt": try optional(v.latestAttempt, attempt),
            "lastReconciliationAt": try optional(v.lastReconciliationAt, integer),
            "observationSequence": .string(String(v.observationSequence)), "transactionID": optional(v.transactionID) { .string($0) }])
    }
    private static func optional<T>(_ value: T?, _ project: (T) throws -> MCPValue) rethrows -> MCPValue {
        guard let value else { return .null }; return try project(value)
    }
    private static func integer(_ value: Int64) throws -> MCPValue {
        guard let exact = Int(exactly: value) else { throw ToolArgumentError.invalid }; return .int(exact)
    }
}

/// A conservative budget before either JSON encoding. A projected JSON value can
/// appear both as structured content and escaped text; four times this limit plus
/// the bounded protocol envelope remains below the 262,144-byte frame allowance.
enum ToolValueBudget {
    static let maximumJSONBytes = 60_000
    static let maximumDepth = 32
    static let maximumNodes = 8_192
    static func validate(_ value: MCPValue) throws {
        var budget = Consumption()
        try budget.visit(value, depth: 0)
    }
    private struct Consumption {
        var bytes = 0
        var nodes = 0
        mutating func add(_ count: Int) throws {
            guard count <= maximumJSONBytes - bytes else { throw ToolArgumentError.invalid }
            bytes += count
        }
        mutating func string(_ value: String) throws {
            try add(2)
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0...31: try add(6)
                case 34, 47, 92: try add(2)
                case 32...126: try add(1)
                case 127...0xffff: try add(6)
                default: try add(12)
                }
            }
        }
        mutating func visit(_ value: MCPValue, depth: Int) throws {
            guard depth <= maximumDepth, nodes < maximumNodes else { throw ToolArgumentError.invalid }
            nodes += 1
            switch value {
            case .null: try add(4)
            case .bool(let value): try add(value ? 4 : 5)
            case .int(let value): try add(String(value).utf8.count)
            case .string(let value): try string(value)
            case .array(let values):
                try add(2)
                for (index, child) in values.enumerated() {
                    if index > 0 { try add(1) }
                    try visit(child, depth: depth + 1)
                }
            case .object(let fields):
                try add(2)
                var first = true
                for (key, child) in fields {
                    if !first { try add(1) }; first = false
                    try string(key); try add(1); try visit(child, depth: depth + 1)
                }
            case .double, .data: throw ToolArgumentError.invalid
            }
        }
    }
}

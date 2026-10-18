import AgentNativeIPC
import AgentValues
import Foundation

/// The native adapter creates this from its verified owner connection, never request metadata.
final class OwnerConnectionContext: @unchecked Sendable {
    let connectionID: String
    let peer: PeerEvidence
    private let lock = NSLock()
    private var active = true
    init(connectionID: String, peer: PeerEvidence) { self.connectionID = connectionID; self.peer = peer }
    func invalidate() { lock.withLock { active = false } }
    var isActive: Bool { lock.withLock { active } }
}

struct OwnerConsentChallenge: Sendable, Equatable {
    let connectionID: String
    let nonce: UUID
    let purpose: OwnerControlMethod
    let reviewCommitment: Data
}
struct OwnerConsentProof: Sendable {
    let challenge: OwnerConsentChallenge
    let authenticatedAt: Int64
}
/// Only trusted composition supplies this provider. Production must authenticate the human
/// for this exact connection/challenge; there is no default or request-provided provider.
protocol OwnerConsentProvider: Sendable {
    func authenticate(_ challenge: OwnerConsentChallenge) async throws -> OwnerConsentProof
}
/// The service owns the catalog and resolves opaque handles. No client supplies a path or state root.
protocol OwnerRecoveryArchiveProvider: Sendable {
    func availableSources() throws -> [RecoverySourceHandle]
    func load(_ handle: RecoverySourceHandle) throws -> CanonicalState
}

/// Separate owner endpoint over existing authoritative owners. It does not implement native IPC.
struct OwnerControlService: Sendable {
    let continuity: ContinuityCoordinator
    let policy: AuthorityPolicy
    let authority: @Sendable () throws -> ServiceAuthority
    let wallet: OwnerWalletControl
    let vault: WalletSeedVault
    let accounts: any AccountChainBoundary
    let payments: PaymentEngine?
    let consent: any OwnerConsentProvider
    let archives: (any OwnerRecoveryArchiveProvider)?
    let clock: any PaymentClock

    init(continuity: ContinuityCoordinator, policy: AuthorityPolicy,
         authority: @escaping @Sendable () throws -> ServiceAuthority, vault: WalletSeedVault,
         accounts: any AccountChainBoundary, payments: PaymentEngine? = nil,
         consent: any OwnerConsentProvider, archives: (any OwnerRecoveryArchiveProvider)? = nil,
         clock: any PaymentClock = SystemPaymentClock()) {
        self.continuity = continuity; self.policy = policy; self.authority = authority
        self.wallet = OwnerWalletControl(continuity: continuity, policy: policy)
        self.vault = vault; self.accounts = accounts; self.payments = payments
        self.consent = consent; self.archives = archives; self.clock = clock
    }

    func send(_ request: OwnerControlRequest, connection: OwnerConnectionContext) async throws -> OwnerControlResponse {
        do {
            guard request.protocolVersion == ServiceStatus.currentProtocolVersion else { throw ServiceProblem(.invalidRequest) }
            try requirePeer(connection)
            if !requiresConsent(request.call) {
                let result = try await read(request.call)
                try requirePeer(connection)
                return OwnerControlResponse(result: result)
            }
            let challenge = OwnerConsentChallenge(connectionID: connection.connectionID, nonce: UUID(),
                purpose: request.call.method, reviewCommitment: try NativeWire.reviewCommitment(request.call))
            let proof = try await consent.authenticate(challenge)
            guard proof.challenge == challenge else { throw ServiceProblem(.unavailable) }
            let check: @Sendable () throws -> Void = { try self.requireProof(proof, connection: connection) }
            try check()
            let owner = OwnerAuthenticationEvidence(peer: connection.peer, authenticationSucceeded: true,
                                                    authenticatedAt: proof.authenticatedAt, authorizationCheck: check)
            let result = try await execute(request.call, owner: owner, check: check)
            try check()
            return OwnerControlResponse(result: result)
        } catch { throw safeOwnerProblem(error) }
    }

    private func requiresConsent(_ call: OwnerControlCall) -> Bool {
        switch call {
        case .status, .listAccounts, .listPayments, .inspectRecovery, .paymentStatus, .reviewPreview, .reviewRelay, .relayReceipt: false
        default: true
        }
    }
    private func read(_ call: OwnerControlCall) async throws -> OwnerControlResult {
        switch call {
        case .status: return .status(try status())
        case .listAccounts(let scope): return .listAccounts(try accountDirectory(scope))
        case .listPayments(let request): return .listPayments(try paymentPage(request))
        case .inspectRecovery:
            return .inspectRecovery(OwnerRecoveryStatus(status: try status(), availableSources: try archives?.availableSources() ?? []))
        case .paymentStatus(let selector): return .paymentStatus(try await paymentProjection(selector, owner: nil))
        case .reviewPreview(let selector): return .reviewPreview(try await previewContext(selector, owner: nil))
        case .reviewRelay(let selector): return .reviewRelay(try await relayContext(selector, owner: nil))
        case .relayReceipt(let selector):
            guard let value = try await receipt(wallet: selector.wallet, key: selector.requestKey, owner: nil) else { throw ServiceProblem(.unavailable) }
            return .relayReceipt(value)
        default: throw ServiceProblem(.unavailable)
        }
    }

    private func execute(_ call: OwnerControlCall, owner: OwnerAuthenticationEvidence,
                         check: @escaping @Sendable () throws -> Void) async throws -> OwnerControlResult {
        switch call {
        case .status:
            return .status(try status(owner))
        case .listAccounts(let scope): return .listAccounts(try accountDirectory(scope))
        case .listPayments(let request): return .listPayments(try paymentPage(request))
        case .inspectRecovery:
            return .inspectRecovery(OwnerRecoveryStatus(status: try status(owner),
                availableSources: try archives?.availableSources() ?? []))
        case .createWallet(let network):
            _ = try await wallet.createNew(vault: vault, network: network.rawValue, owner: owner,
                now: clock.read().wall, authorizationCheck: check)
            return .createWallet(try status(owner))
        case .restoreSeed(let request):
            let bytes = request.mnemonic.withBytes { $0 }
            _ = try await wallet.restoreSeed(mnemonic: bytes, vault: vault, network: request.network.rawValue,
                owner: owner, now: clock.read().wall, authorizationCheck: check)
            return .restoreSeed(try status(owner))
        case .exportRecoveryMaterial(let scope):
            let captured = try continuity.inspect { state in
                try requireWallet(scope, state: state)
                guard let custody = state.custody else { throw ServiceProblem(.unavailable) }
                return (custody, state.authorization.generation)
            }
            let bytes = try await vault.open(captured.0)
            return .exportRecoveryMaterial(try continuity.inspect { state in
                try check()
                try requireWallet(scope, state: state)
                guard state.custody == captured.0, state.authorization.generation == captured.1 else { throw ServiceProblem(.staleContext) }
                return OwnerRecoveryMaterial(wallet: scope, material: try SensitiveOwnerMaterial(bytes: bytes))
            })
        case .recoverJournal(let request):
            if let scope = request.wallet, let state = try continuity.inspectRecoveryState() {
                try requireWallet(scope, state: state)
            }
            var source: CanonicalState?
            if let handle = request.source {
                guard let archives, try archives.availableSources().contains(handle) else { throw ServiceProblem(.unavailable) }
                source = try archives.load(handle)
            }
            if let scope = request.wallet {
                if let source { try requireWallet(scope, state: source) }
                else if try continuity.inspectRecoveryState() == nil {
                    guard let identity = try continuity.recoveryIdentity(), identity.walletID == scope.walletID,
                          identity.network == scope.network.rawValue else { throw ServiceProblem(.unavailable) }
                }
            }
            try check()
            _ = try wallet.recover(owner: owner, now: clock.read().wall, source: source)
            return .recoverJournal(try status(owner))
        case .discoverPublicAccount(let account):
            try continuity.inspect { try requireAccount(account, state: $0) }
            _ = try await wallet.discover(accountID: account.accountID, network: account.wallet.network.rawValue,
                boundary: accounts, owner: owner, now: clock.read().wall, authorizationCheck: check)
            try check()
            return .discoverPublicAccount(try continuity.inspect { state in
                try requireAccount(account, state: state)
                return CapabilityService.projectSyncStatus(record: state.publicSnapshots.first { $0.accountID == account.accountID },
                    account: account, state: state)
            })
        case .enableWallet(let scope):
            try continuity.inspect { try requireWallet(scope, state: $0) }
            _ = try wallet.enable(vault: vault, owner: owner, now: clock.read().wall)
            return .enableWallet(try status(owner))
        case .enrollIntegration(let request):
            try continuity.inspect { try requireWallet(request.wallet, state: $0) }
            let issued = try authority().enroll(id: UUID().uuidString, integrationID: request.integrationID,
                accounts: request.accountIDs, capabilities: request.scopes.map(\.rawValue), expiry: request.expiresAt,
                owner: owner, now: clock.read().wall)
            return .enrollIntegration(try issuedProjection(issued, wallet: request.wallet))
        case .rotateGrant(let selector):
            try continuity.inspect { try requireWallet(selector.wallet, state: $0) }
            let issued = try authority().rotate(id: selector.grantID, owner: owner, now: clock.read().wall)
            return .rotateGrant(try issuedProjection(issued, wallet: selector.wallet))
        case .revokeGrant(let selector):
            try continuity.inspect { try requireWallet(selector.wallet, state: $0) }
            try authority().revoke(id: selector.grantID, owner: owner, now: clock.read().wall)
            return .revokeGrant(try continuity.inspect { state in
                guard let grant = state.authorization.grants.first(where: { $0.id == selector.grantID }) else { throw ServiceProblem(.unavailable) }
                let operations = try state.payments.filter { $0.originGrantID == grant.id && !$0.attempts.isEmpty }
                    .map { try operation($0, state: state) }
                return GrantRevocationProjection(grant: try grantProjection(grant, wallet: selector.wallet), admittedOperations: operations)
            })
        case .setApprovalPolicy(let request):
            try continuity.inspect { try requireWallet(request.wallet, state: $0) }
            try await paymentEngine().changePolicy(approvalRequired: request.approvalRequired, owner: owner,
                expectedRevision: request.expectedRevision)
            return .setApprovalPolicy(try continuity.inspect { state in
                ApprovalPolicyProjection(wallet: request.wallet, revision: state.paymentPolicy.revision,
                    approvalRequired: state.paymentPolicy.approvalRequired)
            })
        case .paymentStatus(let selector):
            return .paymentStatus(try await paymentProjection(selector, owner: owner))
        case .reviewPreview(let selector):
            return .reviewPreview(try await previewContext(selector, owner: owner))
        case .approveExactPayment(let context):
            guard try await previewContext(context.operation, owner: owner) == context else { throw ServiceProblem(.staleContext) }
            let snapshot = try await paymentEngine().approve(operationID: context.operation.operationID, owner: owner,
                expectedPreviewContextDigest: try ownerBytes(context.previewContextDigest))
            return .approveExactPayment(try CapabilityService.projectPayment(snapshot, account: context.operation.account))
        case .rejectExactPayment(let context):
            guard try await previewContext(context.operation, owner: owner) == context else { throw ServiceProblem(.staleContext) }
            let snapshot = try await paymentEngine().reject(operationID: context.operation.operationID, owner: owner,
                expectedPreviewContextDigest: try ownerBytes(context.previewContextDigest))
            return .rejectExactPayment(try CapabilityService.projectPayment(snapshot, account: context.operation.account))
        case .reviewRelay(let selector):
            return .reviewRelay(try await relayContext(selector, owner: owner))
        case .authorizeExactRelay(let request):
            // Retained receipt replay is historical and must work even after the current context changes.
            if let receipt = try await receipt(wallet: request.context.operation.account.wallet,
                key: request.requestKey, owner: owner, expected: request.context) { return .authorizeExactRelay(receipt) }
            try requireSelector(request.context.operation)
            let context = request.context
            let command = OwnerRelayCommand(key: request.requestKey.value, operationID: context.operation.operationID,
                accountID: context.operation.account.accountID, network: context.operation.account.wallet.network.rawValue,
                transactionDigest: try ownerBytes(context.transactionDigest), generation: context.walletGeneration,
                policyRevision: context.policyRevision, evidenceRevision: context.evidenceRevision,
                liabilityContextDigest: try ownerBytes(context.accountLiabilityContextDigest))
            do { _ = try await paymentEngine().authorizeRelay(command, owner: owner) }
            catch {
                if let retained = try await receipt(wallet: context.operation.account.wallet,
                    key: request.requestKey, owner: owner, expected: context) { return .authorizeExactRelay(retained) }
                throw error
            }
            guard let value = try await receipt(wallet: context.operation.account.wallet,
                key: request.requestKey, owner: owner, expected: context) else { throw ServiceProblem(.unavailable) }
            return .authorizeExactRelay(value)
        case .relayReceipt(let selector):
            guard let value = try await receipt(wallet: selector.wallet, key: selector.requestKey, owner: owner) else { throw ServiceProblem(.unavailable) }
            return .relayReceipt(value)
        }
    }

    private func status(_ owner: OwnerAuthenticationEvidence? = nil) throws -> OwnerWalletStatus {
        try owner?.authorizationCheck()
        let observed = continuity.status()
        if case .trusted = observed {
            return try continuity.inspect { state in
                let availability: ServiceAvailability = state.mode == .restricted ? .restricted : (state.history == .complete ? .enabled : .recoveryRequired)
                return try statusProjection(state, availability: availability)
            }
        }
        let state = try continuity.inspectRecoveryState()
        let availability: ServiceAvailability
        switch observed {
        case .quarantined: availability = state == nil ? .unavailable : .recoveryRequired
        default: availability = .unavailable
        }
        return try statusProjection(state, availability: availability)
    }
    private func statusProjection(_ state: CanonicalState?, availability: ServiceAvailability) throws -> OwnerWalletStatus {
        let scope = try state.map { try walletScope($0) }
        let unresolved = try state.map { state in try state.payments.filter(\.liabilityUnresolved).map { try operation($0, state: state) } } ?? []
        let grants = try state.map { state in try state.authorization.grants.map { try grantProjection($0, wallet: walletScope(state)) } } ?? []
        return OwnerWalletStatus(wallet: scope, availability: availability,
            history: state.map { $0.history == .complete ? .complete : .incomplete } ?? .unknown,
            walletGeneration: state?.authorization.generation, custody: state?.custody == nil ? .absent : .presentUnverified,
            approvalPolicy: try state.map { ApprovalPolicyProjection(wallet: try walletScope($0),
                revision: $0.paymentPolicy.revision, approvalRequired: $0.paymentPolicy.approvalRequired) },
            unresolvedOperations: unresolved, grants: grants)
    }
    private func accountDirectory(_ scope: WalletScope) throws -> OwnerAccountDirectory {
        try continuity.inspect { state in
            try requireWallet(scope, state: state)
            let accounts = try state.custody.map { [try AccountScope(wallet: scope, accountID: $0.accountID)] } ?? []
            return OwnerAccountDirectory(wallet: scope, walletGeneration: state.authorization.generation, accounts: accounts)
        }
    }
    private func paymentPage(_ request: WalletPageRequest) throws -> OwnerPaymentPage {
        try continuity.inspect { state in
            try requireWallet(request.wallet, state: state)
            let snapshotID = ownerHex(try state.reference().commitment)
            let binding = OwnerPaymentCursorContext(wallet: request.wallet, generation: state.authorization.generation, snapshotID: snapshotID)
            let commitment = paymentDigest(try paymentEncoding(binding))
            let rows = state.payments.sorted { $0.id < $1.id }
            let offset: Int
            if let encoded = request.page.cursor {
                guard encoded.utf8.count <= 2048, let bytes = Data(base64Encoded: encoded), bytes.count <= 1024,
                      let cursor = try? JSONDecoder().decode(OwnerPaymentCursor.self, from: bytes),
                      cursor.version == 1, try paymentEncoding(cursor) == bytes,
                      cursor.offset > 0 else { throw ServiceProblem(.invalidRequest) }
                guard cursor.context == commitment else { throw ServiceProblem(.staleContext) }
                guard cursor.offset < rows.count else { throw ServiceProblem(.invalidRequest) }
                offset = cursor.offset
            } else { offset = 0 }
            let selected = rows.dropFirst(offset).prefix(request.page.limit)
            let items = try selected.map { payment in
                let selector = try operation(payment, state: state)
                return try CapabilityService.projectPayment(snapshot(selector, state: state), account: selector.account)
            }
            let nextOffset = offset + items.count
            let next: String?
            if nextOffset < rows.count {
                next = try paymentEncoding(OwnerPaymentCursor(context: commitment, offset: nextOffset)).base64EncodedString()
            } else { next = nil }
            return OwnerPaymentPage(wallet: request.wallet, walletGeneration: state.authorization.generation,
                snapshotID: snapshotID, page: CapabilityPage(items: items, nextCursor: next))
        }
    }
    private func issuedProjection(_ issued: IssuedCredential, wallet scope: WalletScope) throws -> OwnerIssuedCredential {
        try continuity.inspect { state in
            guard let grant = state.authorization.grants.first(where: { $0.id == issued.principal.grantID }),
                  grant.integrationID == issued.principal.integrationID,
                  grant.credentialDigest == paymentDigest(issued.rawValue), !grant.revoked, !grant.expiredObserved,
                  grant.expiresAt.map({ clock.read().wall < $0 }) ?? true else { throw ServiceProblem(.staleContext) }
            return OwnerIssuedCredential(grant: try grantProjection(grant, wallet: scope),
                credential: try SensitiveOwnerMaterial(bytes: issued.rawValue))
        }
    }
    private func grantProjection(_ grant: GrantRecord, wallet scope: WalletScope) throws -> GrantProjection {
        GrantProjection(selector: try GrantSelector(wallet: scope, grantID: grant.id), integrationID: grant.integrationID,
            accountIDs: grant.accountIDs, scopes: grant.capabilities.compactMap(IntegrationScope.init(rawValue:)),
            expiresAt: grant.expiresAt, credentialGeneration: grant.credentialGeneration,
            state: grant.revoked ? .revoked : (grant.expiredObserved || grant.expiresAt.map { clock.read().wall >= $0 } == true ? .expired : .active))
    }
    private func paymentProjection(_ selector: OperationSelector, owner: OwnerAuthenticationEvidence?) async throws -> PaymentOperation {
        try requireSelector(selector)
        let snapshot = try await ownerSnapshot(selector, owner: owner)
        guard snapshot.payment.accountID == selector.account.accountID, snapshot.payment.network == selector.account.wallet.network.rawValue else { throw ServiceProblem(.unavailable) }
        return try CapabilityService.projectPayment(snapshot, account: selector.account)
    }
    private func previewContext(_ selector: OperationSelector, owner: OwnerAuthenticationEvidence?) async throws -> ExactPreviewReviewContext {
        try requireSelector(selector)
        let snapshot = try await ownerSnapshot(selector, owner: owner)
        let projection = try CapabilityService.projectPayment(snapshot, account: selector.account)
        guard let preview = projection.preview, let origin = snapshot.payment.originGrantID,
              snapshot.previewContextDigest.count == 32 else { throw ServiceProblem(.unavailable) }
        return ExactPreviewReviewContext(operation: selector, preview: preview,
            previewContextDigest: ownerHex(snapshot.previewContextDigest), walletGeneration: snapshot.currentWalletGeneration,
            policyRevision: snapshot.currentPolicyRevision, originGrantID: origin,
            originCredentialGeneration: snapshot.payment.originCredentialGeneration)
    }
    private func relayContext(_ selector: OperationSelector, owner: OwnerAuthenticationEvidence?) async throws -> ExactRelayReviewContext {
        try requireSelector(selector)
        let snapshot = try await ownerSnapshot(selector, owner: owner)
        guard snapshot.payment.accountID == selector.account.accountID,
              snapshot.payment.network == selector.account.wallet.network.rawValue,
              !snapshot.payment.canonicalBytes.isEmpty, snapshot.payment.transactionDigest.count == 32 else { throw ServiceProblem(.unavailable) }
        return ExactRelayReviewContext(operation: selector, transactionDigest: ownerHex(snapshot.payment.transactionDigest),
            walletGeneration: snapshot.currentWalletGeneration, policyRevision: snapshot.currentPolicyRevision,
            evidenceRevision: snapshot.payment.evidenceRevision, accountLiabilityContextDigest: ownerHex(snapshot.liabilityContextDigest))
    }
    private func receipt(wallet scope: WalletScope, key: RequestKey, owner: OwnerAuthenticationEvidence?,
                         expected: ExactRelayReviewContext? = nil) async throws -> OwnerRelayReceipt? {
        try continuity.inspect { state in
            try owner?.authorizationCheck()
            try requireWallet(scope, state: state)
            guard let row = state.requests.first(where: { $0.principalID == "owner" && $0.method == "authorize_payment_relay" && $0.key == key.value }) else { return nil }
            let command = try JSONDecoder().decode(OwnerRelayCommand.self, from: row.binding)
            let account = try AccountScope(wallet: scope, accountID: command.accountID)
            let selector = try OperationSelector(account: account, operationID: command.operationID)
            let context = ExactRelayReviewContext(operation: selector, transactionDigest: ownerHex(command.transactionDigest),
                walletGeneration: command.generation, policyRevision: command.policyRevision,
                evidenceRevision: command.evidenceRevision, accountLiabilityContextDigest: ownerHex(command.liabilityContextDigest))
            guard expected == nil || context == expected else { throw ServiceProblem(.conflictingRequest) }
            let snapshot = try snapshot(selector, state: state)
            let attempt = row.consumedAttemptID.flatMap { id in snapshot.payment.attempts.first { $0.id == id } }.map {
                RelayAttemptProjection(attemptID: $0.id, number: $0.number, route: .owner,
                    outcome: RelayAttemptOutcome(rawValue: $0.outcome) ?? .unknown, admittedAt: $0.admittedAt, nextEligibleAt: $0.nextEligibleAt)
            }
            return OwnerRelayReceipt(wallet: scope, requestKey: key, context: context, attempt: attempt,
                outcome: row.consumedAttemptID == nil ? .noAdmission : .admitted,
                terminalReason: row.consumedAttemptID == nil ? (String(data: row.result, encoding: .utf8).flatMap(ServiceProblemCode.init(rawValue:)) ?? .unavailable) : nil,
                payment: try CapabilityService.projectPayment(snapshot, account: account))
        }
    }
    private func ownerSnapshot(_ selector: OperationSelector, owner: OwnerAuthenticationEvidence?) async throws -> PaymentSnapshot {
        if let owner { return try await paymentEngine().ownerStatus(operationID: selector.operationID, owner: owner) }
        return try continuity.inspect { try snapshot(selector, state: $0) }
    }
    private func snapshot(_ selector: OperationSelector, state: CanonicalState) throws -> PaymentSnapshot {
        try requireAccount(selector.account, state: state)
        guard let payment = state.payments.first(where: { $0.id == selector.operationID &&
            $0.accountID == selector.account.accountID && $0.network == selector.account.wallet.network.rawValue }) else { throw ServiceProblem(.unavailable) }
        let held = state.gates.contains { $0.accountID == payment.accountID && (!$0.liabilityIDs.isEmpty || !$0.restrictions.isEmpty) }
        return PaymentSnapshot(payment: payment, accountRestricted: held, blocker: payment.blocker,
            liabilityContextDigest: accountLiabilityContextDigest(accountID: payment.accountID, state: state),
            walletID: state.authorization.walletID, currentWalletGeneration: state.authorization.generation,
            currentPolicyRevision: state.paymentPolicy.revision, previewContextDigest: paymentPreviewContextDigest(payment, state: state))
    }
    private func requireSelector(_ selector: OperationSelector) throws {
        try continuity.inspect { try requireAccount(selector.account, state: $0) }
    }
    private func requireWallet(_ scope: WalletScope, state: CanonicalState) throws {
        guard scope.walletID == state.authorization.walletID, scope.network.rawValue == state.authorization.network else { throw ServiceProblem(.unavailable) }
    }
    private func requireAccount(_ scope: AccountScope, state: CanonicalState) throws {
        try requireWallet(scope.wallet, state: state)
        guard state.custody?.accountID == scope.accountID else { throw ServiceProblem(.unavailable) }
    }
    private func walletScope(_ state: CanonicalState) throws -> WalletScope {
        guard let network = WalletNetwork(rawValue: state.authorization.network) else { throw ServiceProblem(.unavailable) }
        return try WalletScope(walletID: state.authorization.walletID, network: network)
    }
    private func operation(_ payment: PaymentRecord, state: CanonicalState) throws -> OperationSelector {
        try OperationSelector(account: AccountScope(wallet: walletScope(state), accountID: payment.accountID), operationID: payment.id)
    }
    private func paymentEngine() throws -> PaymentEngine {
        guard let payments else { throw ServiceProblem(.unavailable) }; return payments
    }
    private func requirePeer(_ connection: OwnerConnectionContext) throws {
        guard connection.isActive, !connection.connectionID.isEmpty,
              connection.peer.signatureValidated, connection.peer.identity == policy.owner else { throw ServiceProblem(.unavailable) }
    }
    private func requireProof(_ proof: OwnerConsentProof, connection: OwnerConnectionContext) throws {
        try requirePeer(connection)
        guard proof.challenge.connectionID == connection.connectionID else { throw ServiceProblem(.unavailable) }
        let authority = AuthorizationAuthority(ledger: AuthorizationLedger(walletID: "owner", network: "owner", generation: 0, grants: []),
            expectedBridgeIdentity: policy.bridge, trustedOwnerIdentity: policy.owner, maximumOwnerAuthenticationAge: policy.ownerAuthenticationAge)
        try authority.requireOwner(owner: OwnerAuthenticationEvidence(peer: connection.peer, authenticationSucceeded: true,
            authenticatedAt: proof.authenticatedAt), now: clock.read().wall)
    }

}

private struct OwnerPaymentCursorContext: Codable {
    let wallet: WalletScope
    let generation: UInt64
    let snapshotID: String
}
private struct OwnerPaymentCursor: Codable {
    var version: Int = 1
    let context: Data
    let offset: Int
}

private func ownerHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func ownerBytes(_ text: String) throws -> Data {
    guard text.utf8.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ServiceProblem(.invalidRequest) }
    var result = Data(); var index = text.startIndex
    while index < text.endIndex {
        let end = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<end], radix: 16) else { throw ServiceProblem(.invalidRequest) }
        result.append(byte); index = end
    }
    return result
}
private func safeOwnerProblem(_ error: any Error) -> ServiceProblem {
    if let error = error as? ServiceProblem { return error }
    if let error = error as? PaymentFailure { return ServiceProblem(ServiceProblemCode(rawValue: String(describing: error)) ?? .unavailable) }
    if let error = error as? ContinuityError {
        switch error {
        case .keyUnavailable: return ServiceProblem(.keyUnavailable)
        case .recoveryRequired, .incompleteHistory: return ServiceProblem(.recoveryRequired)
        default: return ServiceProblem(.unavailable)
        }
    }
    if error is PayloadProtectionError { return ServiceProblem(.keyUnavailable) }
    return ServiceProblem(.unavailable)
}

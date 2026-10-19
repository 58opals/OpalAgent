import OpalDiagnostics

/// A closed observation vocabulary. No caller payload or error text reaches diagnostics.
enum ServiceDiagnostics {
    static let authorization = OpalDiagnostics.logger(category: "agent.authorization")
    static let journal = OpalDiagnostics.logger(category: "agent.journal")
    static let recovery = OpalDiagnostics.logger(category: "agent.recovery")
    static let payment = OpalDiagnostics.logger(category: "agent.payment")

    enum TrustReason: String { case recoveryRequired, keyUnavailable, storageUnavailable }
    enum RecoveryPath: String { case reset, resumed }

    static func attemptTrace() -> OpalDiagnostics.TraceID? {
        guard journal.isEnabled(level: .notice) || payment.isEnabled(level: .notice) else { return nil }
        return OpalDiagnostics.TraceID()
    }

    static func authorizationDenied(_ failure: AuthorizationFailure) {
        record(authorization, event: "authorization_denied") {
            let reason: String
            switch failure {
            case .untrustedPeer: reason = "untrusted_peer"
            case .ownerAuthenticationRequired: reason = "owner_authentication_required"
            case .invalidRequest: reason = "invalid_request"
            case .invalidCredential: reason = "invalid_credential"
            case .revoked: reason = "revoked"
            case .expired: reason = "expired"
            case .staleSession: reason = "stale_session"
            case .scopeDenied: reason = "scope_denied"
            case .unavailable: reason = "unavailable"
            case .randomnessUnavailable: reason = "randomness_unavailable"
            }
            return [.publicField("reason", value: reason)]
        }
    }

    static func barrierVerified(trace: OpalDiagnostics.TraceID?) {
        record(journal, event: "barrier_verified", trace: trace) { [] }
    }

    static func trustUnavailable(_ reason: TrustReason) {
        record(journal, event: "trust_unavailable") { [.publicField("reason", value: reason.rawValue)] }
    }

    static func recoveryCompleted(history: HistoryCoverage, path: RecoveryPath) {
        record(recovery, event: "recovery_completed") {
            [.publicField("history", value: history.rawValue), .publicField("path", value: path.rawValue)]
        }
    }

    static func paymentTransition(from: PaymentDisposition?, to: PaymentDisposition,
                                  trace: OpalDiagnostics.TraceID?) {
        record(payment, event: "payment_transition", trace: trace) {
            [.publicField("from_state", value: from?.rawValue ?? "new"),
             .publicField("to_state", value: to.rawValue)]
        }
    }

    private static func record(_ logger: OpalDiagnostics.Logger, event: OpalDiagnostics.Event,
                               trace: OpalDiagnostics.TraceID? = nil, fields: () -> [OpalDiagnostics.Field]) {
        guard logger.isEnabled(level: .notice) else { return }
        // Explicit fresh local tokens never inherit a host-supplied authority-bearing trace.
        logger.record(event: event, level: .notice, traceID: trace ?? OpalDiagnostics.TraceID(), fields: fields)
    }
}

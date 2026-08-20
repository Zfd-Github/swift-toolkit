public enum NavigationOutcome: Sendable, Equatable {
    case applied
    case cancelled
    case timedOut
    case superseded
    case targetNotVisible
    case targetMismatch
    case contentProcessTerminated
    case unavailable
    case failed

    public var isApplied: Bool {
        self == .applied
    }

    init(_ mutation: NavigationMutationResult) {
        switch mutation.result {
        case .applied:
            self = mutation.stableVerified ? .applied : .failed
        case .cancelled:
            self = .cancelled
        case .timedOut:
            self = .timedOut
        case .superseded:
            self = .superseded
        case .spreadNotLoaded:
            self = .unavailable
        case .webContentTerminated:
            self = .contentProcessTerminated
        case .failed:
            self = .failed
        }
    }
}

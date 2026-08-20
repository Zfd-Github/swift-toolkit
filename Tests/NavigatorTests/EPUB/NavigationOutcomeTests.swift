import Foundation
@testable import ReadiumNavigator
import ReadiumShared
import Testing

@Suite
struct NavigationOutcomeTests {
    @Test("typed terminal results retain their public outcome")
    func typedTerminalResultsRetainTheirPublicOutcome() {
        #expect(outcome(for: .cancelled) == .cancelled)
        #expect(outcome(for: .timedOut) == .timedOut)
        #expect(outcome(for: .superseded) == .superseded)
        #expect(outcome(for: .webContentTerminated) == .contentProcessTerminated)
        #expect(outcome(for: .failed(TestError())) == .failed)
    }

    @Test("applied requires a stable verified navigation")
    func appliedRequiresStableVerifiedNavigation() {
        let unverified = NavigationMutationResult(
            result: .applied,
            mayHaveMutated: true,
            stableVerified: false
        )
        let verified = NavigationMutationResult(
            result: .applied,
            mayHaveMutated: true,
            stableVerified: true
        )

        #expect(NavigationOutcome(unverified) == .failed)
        #expect(NavigationOutcome(verified) == .applied)
        #expect(!NavigationOutcome(unverified).isApplied)
        #expect(NavigationOutcome(verified).isApplied)
    }

    @Test("verification rejection remains unavailable without target evidence")
    func verificationRejectionRemainsUnavailableWithoutTargetEvidence() {
        let stableLocator = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(progression: 0.25)
        )
        let mutation = NavigationMutationResult(
            result: .spreadNotLoaded,
            mayHaveMutated: true,
            stableLocator: stableLocator,
            stableVerified: false,
            failureStage: .verification
        )

        #expect(NavigationOutcome(mutation) == .unavailable)
        #expect(NavigationOutcome(mutation) != .targetNotVisible)
        #expect(NavigationOutcome(mutation) != .targetMismatch)
    }

    private func outcome(for result: NavigationResult) -> NavigationOutcome {
        NavigationOutcome(
            NavigationMutationResult(
                result: result,
                mayHaveMutated: false,
                failureStage: .preflight
            )
        )
    }
}

private struct TestError: Error {}

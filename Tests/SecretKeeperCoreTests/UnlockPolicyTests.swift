import XCTest
import LocalAuthentication
@testable import SecretKeeperCore

final class UnlockPolicyTests: XCTestCase {

    // MARK: - Policy chain

    /// The whole point of the chain: a Mac with no Touch ID and no paired Watch
    /// must still have a way to open its own vault.
    func testChainAlwaysEndsWithThePasswordCapablePolicy() {
        let chain = KeychainStore.unlockPolicyChain(context: LAContext())
        XCTAssertFalse(chain.isEmpty)
        XCTAssertEqual(chain.last, .deviceOwnerAuthentication)
    }

    /// Password is a fallback, never the opening move when biometrics can run.
    func testPasswordPolicyIsLastAndAppearsOnce() {
        let chain = KeychainStore.unlockPolicyChain(context: LAContext())
        let passwordIndexes = chain.enumerated()
            .filter { $0.element == .deviceOwnerAuthentication }
            .map(\.offset)
        XCTAssertEqual(passwordIndexes, [chain.count - 1])
    }

    func testChainHasNoDuplicatePolicies() {
        let chain = KeychainStore.unlockPolicyChain(context: LAContext())
        XCTAssertEqual(chain.count, Set(chain.map(\.rawValue)).count)
    }

    /// On hardware that can do biometrics, the first prompt must still be the
    /// single biometric sheet — the old behaviour, preserved.
    func testBiometricCapableMacIsPromptedForBiometricsFirst() throws {
        let context = LAContext()
        var error: NSError?
        let canBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        guard canBiometrics else {
            throw XCTSkip("No biometrics on this machine; chain is password-only by design.")
        }
        let chain = KeychainStore.unlockPolicyChain(context: context)
        XCTAssertNotEqual(chain.first, .deviceOwnerAuthentication)
        XCTAssertGreaterThan(chain.count, 1)
    }

    func testPreferredPolicyIsTheHeadOfTheChain() {
        let context = LAContext()
        XCTAssertEqual(
            KeychainStore.preferredUnlockPolicy(context: context),
            KeychainStore.unlockPolicyChain(context: context).first
        )
    }

    // MARK: - Error mapping
    //
    // These decide whether a failure escalates to the next policy, retries, or
    // stops, so the exact code-to-error mapping matters.

    func testSystemCancelMapsToInterruptedNotHardFailure() {
        // LA code -4 is systemCancel (focus/menu race), NOT userCancel (-2).
        let error = NSError(
            domain: LAErrorDomain,
            code: LAError.Code.systemCancel.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Authentication canceled."]
        )
        let mapped = KeychainStore.mapLocalAuthenticationError(error)
        XCTAssertEqual(mapped, .authenticationInterrupted)
        XCTAssertFalse(mapped.localizedDescription.hasPrefix("Unlock failed:"))
    }

    func testUserCancelMapsToSoftCanceled() {
        let error = NSError(
            domain: LAErrorDomain,
            code: LAError.Code.userCancel.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Canceled by user."]
        )
        let mapped = KeychainStore.mapLocalAuthenticationError(error)
        XCTAssertEqual(mapped, .authenticationCanceled)
        XCTAssertEqual(mapped.localizedDescription, "Unlock canceled.")
    }

    func testAppCancelMapsToInterrupted() {
        let error = NSError(
            domain: "com.apple.LocalAuthentication",
            code: LAError.Code.appCancel.rawValue,
            userInfo: nil
        )
        let mapped = KeychainStore.mapLocalAuthenticationError(error)
        XCTAssertEqual(mapped, .authenticationInterrupted)
    }

    /// These three are what make a Touch-ID-less Mac fall through to the password
    /// sheet instead of dead-ending.
    func testUnavailableBiometryMapsToBiometricRequiredSoItEscalates() {
        for code in [
            LAError.Code.biometryNotAvailable,
            LAError.Code.biometryNotEnrolled,
            LAError.Code.biometryLockout,
        ] {
            let error = NSError(domain: LAErrorDomain, code: code.rawValue, userInfo: nil)
            XCTAssertEqual(
                KeychainStore.mapLocalAuthenticationError(error),
                .biometricRequired,
                "code \(code.rawValue) should escalate to the next policy"
            )
        }
    }

    func testLAErrorCodesMatchAppleDocumentation() {
        XCTAssertEqual(LAError.Code.userCancel.rawValue, -2)
        XCTAssertEqual(LAError.Code.systemCancel.rawValue, -4)
        XCTAssertEqual(LAError.Code.appCancel.rawValue, -9)
    }
}

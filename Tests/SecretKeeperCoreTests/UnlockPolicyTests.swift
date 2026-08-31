import XCTest
import LocalAuthentication
@testable import SecretKeeperCore

final class UnlockPolicyTests: XCTestCase {
    func testPreferredPolicyNeverUsesPasswordCapableDeviceOwnerAuth() {
        let context = LAContext()
        let policy = KeychainStore.preferredUnlockPolicy(context: context)
        XCTAssertNotEqual(policy, .deviceOwnerAuthentication)
    }

    func testPreferredPolicyPrefersCompanionOrWatchOverBiometricsOnly() {
        let context = LAContext()
        var error: NSError?
        let policy = KeychainStore.preferredUnlockPolicy(context: context)

        if #available(macOS 15.0, *) {
            let canBioOrCompanion = context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometricsOrCompanion,
                error: &error
            )
            error = nil
            let canCompanion = context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithCompanion,
                error: &error
            )
            error = nil
            let canBio = context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                error: &error
            )

            if canBioOrCompanion {
                XCTAssertEqual(policy, .deviceOwnerAuthenticationWithBiometricsOrCompanion)
            } else if canCompanion {
                XCTAssertEqual(policy, .deviceOwnerAuthenticationWithCompanion)
            } else if canBio {
                XCTAssertEqual(policy, .deviceOwnerAuthenticationWithBiometrics)
            } else {
                // Fallback still must not be password-capable deviceOwnerAuthentication.
                XCTAssertNotEqual(policy, .deviceOwnerAuthentication)
            }
        } else {
            let canBioOrWatch = context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometricsOrWatch,
                error: &error
            )
            error = nil
            let canWatch = context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithWatch,
                error: &error
            )
            error = nil
            let canBio = context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                error: &error
            )

            if canBioOrWatch {
                XCTAssertEqual(policy, .deviceOwnerAuthenticationWithBiometricsOrWatch)
            } else if canWatch {
                XCTAssertEqual(policy, .deviceOwnerAuthenticationWithWatch)
            } else if canBio {
                XCTAssertEqual(policy, .deviceOwnerAuthenticationWithBiometrics)
            } else {
                XCTAssertNotEqual(policy, .deviceOwnerAuthentication)
            }
        }
    }

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

    func testLAErrorCodesMatchAppleDocumentation() {
        XCTAssertEqual(LAError.Code.userCancel.rawValue, -2)
        XCTAssertEqual(LAError.Code.systemCancel.rawValue, -4)
        XCTAssertEqual(LAError.Code.appCancel.rawValue, -9)
    }
}

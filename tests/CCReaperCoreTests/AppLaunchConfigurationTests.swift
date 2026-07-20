import XCTest
@testable import CCReaperCore

final class AppLaunchConfigurationTests: XCTestCase {
    func testBackgroundVerificationFlagSuppressesForegroundActivation() {
        let configuration = AppLaunchConfiguration(arguments: ["CCReaper", "--background-test"])

        XCTAssertFalse(configuration.activatesForeground)
    }

    func testNormalLaunchActivatesForeground() {
        let configuration = AppLaunchConfiguration(arguments: ["CCReaper"])

        XCTAssertTrue(configuration.activatesForeground)
    }
}

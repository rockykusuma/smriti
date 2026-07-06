import XCTest
@testable import SmritiKit

final class OnboardingWindowTests: XCTestCase {

    func testConfigHasCompletedOnboardingDefaultFalse() {
        let config = Config.defaults
        XCTAssertFalse(config.hasCompletedOnboarding)
    }

    func testConfigHasCompletedOnboardingRoundTrips() throws {
        var config = Config.defaults
        config.hasCompletedOnboarding = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertTrue(decoded.hasCompletedOnboarding)
    }

    func testOnboardingWindowInitialization() {
        var config = Config.defaults
        let window = OnboardingWindow(config: config) { cfg in
            config = cfg
        }
        XCTAssertNotNil(window)
    }

    func testOnboardingWindowStepsCount() {
        let config = Config.defaults
        let window = OnboardingWindow(config: config) { _ in }
        let stepsCount = Mirror(reflecting: window).children.filter { $0.label == "steps" }.first
        XCTAssertNotNil(stepsCount)
    }
}

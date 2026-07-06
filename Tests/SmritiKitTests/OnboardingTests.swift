import XCTest
@testable import SmritiKit

final class OnboardingWindowTests: XCTestCase {

    func testConfigHasCompletedOnboardingDefaultFalse() throws {
        let store = try Store(dbPath: ":memory:")
        let config = Config.defaults
        XCTAssertFalse(config.hasCompletedOnboarding)
    }

    func testConfigHasCompletedOnboardingPersistence() throws {
        let store = try Store(dbPath: ":memory:")
        var config = Config.defaults
        config.hasCompletedOnboarding = true
        try config.save()

        let loaded = try Config.load()
        XCTAssertTrue(loaded.hasCompletedOnboarding)
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
        // Access private steps via reflection for testing
        let stepsCount = Mirror(reflecting: window).children.filter { $0.label == "steps" }.first
        XCTAssertNotNil(stepsCount)
    }
}

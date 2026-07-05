import XCTest
@testable import SmritiKit

final class CloudLLMTests: XCTestCase {

    // MARK: - SSE line parsing

    private func line(_ s: String) -> Data { Data(s.utf8) }

    func testContentDelta() {
        let sse = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(CloudLLMClient.parse(line: line(sse))?.content, "Hello")
    }

    func testDoneSentinel() {
        let event = CloudLLMClient.parse(line: line("data: [DONE]"))
        XCTAssertEqual(event?.done, true)
        XCTAssertNil(event?.content)
    }

    func testRoleOnlyFirstChunkCarriesNothing() {
        let sse = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertNil(CloudLLMClient.parse(line: line(sse)))
    }

    func testBlankAndCommentLinesIgnored() {
        XCTAssertNil(CloudLLMClient.parse(line: line("")))
        XCTAssertNil(CloudLLMClient.parse(line: line(": keep-alive")))
    }

    func testErrorInsideDataLine() {
        let sse = #"data: {"error":{"message":"rate limited","code":429}}"#
        XCTAssertNotNil(CloudLLMClient.parse(line: line(sse))?.error)
    }

    func testBareJSONErrorObject() {
        let sse = #"{"error":{"message":"invalid api key"}}"#
        XCTAssertNotNil(CloudLLMClient.parse(line: line(sse))?.error)
    }

    func testCRLFTolerated() {
        // Buffer splitting is on \n; a trailing \r must not break parsing.
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\r"
        XCTAssertEqual(CloudLLMClient.parse(line: line(sse))?.content, "x")
    }

    // MARK: - Provider config

    func testLocalEndpointDetection() {
        XCTAssertTrue(CloudProviderConfig(
            baseURL: "http://localhost:11434/v1", model: "m").isLocal)
        XCTAssertTrue(CloudProviderConfig(
            baseURL: "http://127.0.0.1:8080/v1", model: "m").isLocal)
        XCTAssertFalse(CloudProviderConfig(
            baseURL: "https://api.groq.com/openai/v1", model: "m").isLocal)
    }

    func testPresetProvidersSurviveOldConfigs() throws {
        // A pre-cloud config decodes leniently and gains the presets.
        var config = Config.defaults
        config.cloudProviders = [:]
        config.ensurePresetProviders()
        XCTAssertNotNil(config.cloudProviders["groq"])
        XCTAssertNotNil(config.cloudProviders["openrouter"])
    }

    func testUserEditsToPresetWin() {
        var config = Config.defaults
        config.cloudProviders["groq"] =
            CloudProviderConfig(baseURL: "https://api.groq.com/openai/v1",
                                model: "openai/gpt-oss-20b")
        config.ensurePresetProviders()
        XCTAssertEqual(config.cloudProviders["groq"]?.model, "openai/gpt-oss-20b")
    }

    // MARK: - .env fallback

    func testEnvVarName() {
        XCTAssertEqual(CloudKeyStore.envVarName(provider: "groq"), "GROQ_API_KEY")
        XCTAssertEqual(CloudKeyStore.envVarName(provider: "openrouter"), "OPENROUTER_API_KEY")
        XCTAssertEqual(CloudKeyStore.envVarName(provider: "ollama-v1"), "OLLAMA_V1_API_KEY")
    }

    func testParseEnvBasics() {
        let env = CloudKeyStore.parseEnv("""
        # cloud keys
        GROQ_API_KEY=gsk_abc123
        export OPENROUTER_API_KEY="sk-or-xyz"
        QUOTED='single'
        EMPTY=
        NOEQUALS
          SPACED  =  padded
        """)
        XCTAssertEqual(env["GROQ_API_KEY"], "gsk_abc123")
        XCTAssertEqual(env["OPENROUTER_API_KEY"], "sk-or-xyz") // export + quotes stripped
        XCTAssertEqual(env["QUOTED"], "single")
        XCTAssertNil(env["EMPTY"])   // empty values are treated as absent
        XCTAssertNil(env["NOEQUALS"])
        XCTAssertEqual(env["SPACED"], "padded")
    }

    // MARK: - Live streaming (runs only when a local Ollama is up; CI skips)

    func testLiveStreamAgainstLocalOpenAIEndpoint() throws {
        try XCTSkipUnless(OllamaClient.isReachable(), "Ollama not running")
        let model = OllamaClient.listModels().first
        try XCTSkipUnless(model != nil, "no local models")
        let spec = CloudLLMClient.Spec(
            name: "ollama-v1",
            config: CloudProviderConfig(baseURL: "http://localhost:11434/v1", model: model!),
            apiKey: nil)
        var deltas = 0
        let reply = CloudLLMClient(spec: spec)
            .request("Reply with exactly: pong", timeout: 60) { _ in deltas += 1 }
        XCTAssertNotNil(reply)
        XCTAssertGreaterThan(deltas, 0, "expected streamed deltas, not one blob")
    }

    func testCloudConfigRoundTripsThroughJSON() throws {
        var config = Config.defaults
        config.assistBackend = "cloud"
        config.cloudProvider = "openrouter"
        config.cloudProviders["custom"] =
            CloudProviderConfig(baseURL: "https://api.together.xyz/v1", model: "llama-x")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.assistBackend, "cloud")
        XCTAssertEqual(decoded.cloudProvider, "openrouter")
        XCTAssertEqual(decoded.cloudProviders["custom"]?.model, "llama-x")
    }
}

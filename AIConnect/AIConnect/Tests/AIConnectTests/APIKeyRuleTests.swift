// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// PR #231 review (B2, S1): a key is required only by the known cloud providers. Every other
/// server (LM Studio, Ollama, llama.cpp, a proxy) decides for itself: a blank key sends no
/// `Authorization` header, and a 401 is shown as a setup problem. Never decided by port.
final class APIKeyRuleTests: XCTestCase {
    /// Addresses a keyless self-hosted server can have. None of them may require a key.
    static let keyOptional = [
        "http://192.168.1.100:1234/v1",        // LAN IP (LM Studio on the LAN)
        "http://localhost:1234/v1",
        "http://169.254.12.7:1234/v1",          // link-local (direct cable, Thunderbolt bridge)
        "http://mac-mini:1234/v1",             // bare name (router DNS, MagicDNS short name)
        "http://studio.home.arpa:1234/v1",
        "http://gpu.internal:8080/v1",
        "https://lmstudio.example.com/v1",      // reverse proxy
        "http://203.0.113.7:1234/v1",          // public IP
        "http://100.101.102.103:1234/v1",       // Tailscale 100.x
        "http://mac-mini.tail1234.ts.net:1234/v1",
        "http://[fd00::12]:1234/v1",
        "http://[::ffff:192.168.1.100]:1234/v1",
        "http://localhost:11434/api",           // Ollama
    ]

    /// The cloud providers that always need a key.
    static let keyRequired = [
        "https://api.openai.com/v1",
        "https://api.x.ai/v1",
        "https://api.anthropic.com/v1",
        "https://generativelanguage.googleapis.com/v1beta/openai",
        "https://openrouter.ai/api/v1",
    ]

    func testOnlyKnownCloudProvidersRequireAKey() {
        for url in Self.keyOptional {
            XCTAssertFalse(OpenAICompatibleAPI.requiresAPIKey(baseURL: url), url)
        }
        for url in Self.keyRequired {
            XCTAssertTrue(OpenAICompatibleAPI.requiresAPIKey(baseURL: url), url)
        }
    }

    /// The port never decides: the same hosts on other ports give the same answer.
    func testThePortNeverDecides() {
        for port in ["", ":1234", ":41234", ":443", ":8080"] {
            XCTAssertFalse(OpenAICompatibleAPI.requiresAPIKey(baseURL: "http://mac-mini\(port)/v1"), port)
            XCTAssertTrue(OpenAICompatibleAPI.requiresAPIKey(baseURL: "https://api.x.ai\(port)/v1"), port)
        }
    }

    /// A look-alike host isn't a cloud provider: only the provider's own domain counts.
    func testLookAlikeHostsAreNotCloudProviders() {
        XCTAssertFalse(OpenAICompatibleAPI.requiresAPIKey(baseURL: "http://192.168.1.5/proxy/api.openai.com/v1"))
        XCTAssertFalse(OpenAICompatibleAPI.requiresAPIKey(baseURL: "https://notopenai.com/v1"))
    }

    /// isConfigured (model refresh, the picker) agrees with the rule.
    func testIsConfiguredAgreesWithTheRule() {
        for url in Self.keyOptional {
            XCTAssertTrue(OpenAICompatibleAPI.isConfigured(baseURL: url, apiKey: ""), url)
            XCTAssertTrue(OpenAICompatibleAPI.isConfigured(baseURL: url, apiKey: "   "), url)
        }
        for url in Self.keyRequired {
            XCTAssertFalse(OpenAICompatibleAPI.isConfigured(baseURL: url, apiKey: ""), url)
            XCTAssertFalse(OpenAICompatibleAPI.isConfigured(baseURL: url, apiKey: "  \n"), url)
            XCTAssertTrue(OpenAICompatibleAPI.isConfigured(baseURL: url, apiKey: "sk-1"), url)
        }
    }

    /// A blank or whitespace-only key sends no Authorization header anywhere.
    func testBlankKeySendsNoAuthorizationHeader() {
        for key in ["", "  ", "\n\t"] {
            let headers = OpenAICompatibleAPI.requestHeaders(baseURL: "http://mac-mini:1234/v1", apiKey: key, streaming: false)
            XCTAssertNil(headers["Authorization"], "key \(key.debugDescription)")
        }
    }

    /// The connection-level rule the apps use: a ChatGPT sign-in uses its token, never a key.
    func testConnectionRule() {
        XCTAssertFalse(RemoteConnection(name: "LM", apiBaseURL: "http://192.168.1.100:1234/v1", encoding: .openAIChatCompletions).requiresAPIKey)
        XCTAssertFalse(RemoteConnection(name: "Proxy", apiBaseURL: "https://lmstudio.example.com/v1", encoding: .automatic).requiresAPIKey)
        XCTAssertTrue(RemoteConnection(name: "xAI", apiBaseURL: "https://api.x.ai/v1", encoding: .openAIChatCompletions).requiresAPIKey)
        var chatGPT = RemoteConnection(name: "ChatGPT", apiBaseURL: "https://api.openai.com/v1", encoding: .openAIChatCompletions)
        chatGPT.chatgptIssuedClientID = "client-123"
        XCTAssertTrue(chatGPT.usesChatGPTAccount)
        XCTAssertFalse(chatGPT.requiresAPIKey)
        // A server the app identified as LM Studio on a public host is still key-optional.
        var detected = RemoteConnection(name: "LM", apiBaseURL: "http://203.0.113.7:47213/v1", encoding: .automatic)
        detected.recordServer(isLMStudio: true, isOllama: false)
        XCTAssertFalse(detected.requiresAPIKey)
    }

    /// UX: the key field's label and footer follow the same rule as the requests.
    func testKeyFieldLabelMatchesTheRule() {
        for url in Self.keyOptional + Self.keyRequired {
            let c = RemoteConnection(name: "c", apiBaseURL: url, encoding: .openAIChatCompletions)
            if c.requiresAPIKey {
                XCTAssertEqual(c.apiKeyFieldLabel, "API Key", url)
                XCTAssertNil(c.apiKeyFieldFooter, url)
            } else {
                XCTAssertEqual(c.apiKeyFieldLabel, "API Key (optional)", url)
                XCTAssertEqual(c.apiKeyFieldFooter, "Leave blank if your server doesn't use one, like LM Studio.", url)
            }
        }
        XCTAssertEqual(RemoteConnection(name: "c", apiBaseURL: "https://api.openai.com/v1", encoding: .openAIChatCompletions).apiKeyFieldLabel,
                       "API Key")
        XCTAssertEqual(RemoteConnection(name: "c", apiBaseURL: "http://192.168.1.100:1234/v1", encoding: .openAIChatCompletions).apiKeyFieldLabel,
                       "API Key (optional)")
    }

    /// S5: clearing a connection's saved failures keeps its passes and other connections' results.
    @MainActor
    func testClearFailuresKeepsPasses() {
        let store = ToolCallVerificationStore(defaults: UserDefaults(suiteName: "keyrule-\(UUID().uuidString)")!)
        func key(_ connection: String, _ model: String) -> String {
            ConfiguredModelRegistry.selectionKey(modelID: model, backend: .remote, connectionID: connection)
        }
        store.record(passed: false, for: key("lm", "qwen/qwen3.8-27b"))
        store.record(passed: true, for: key("lm", "qwen/qwen3.6-27b"))
        store.record(passed: false, for: key("other", "gpt-oss"))
        store.clearFailures(connectionID: "lm")
        XCTAssertNil(store.result(for: key("lm", "qwen/qwen3.8-27b")), "the failure is cleared, so the model is untested")
        XCTAssertEqual(store.result(for: key("lm", "qwen/qwen3.6-27b")), true)
        XCTAssertEqual(store.result(for: key("other", "gpt-oss")), false)
    }
}

// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// PR #219 re-review: R1 (object arguments only on LM Studio, never Ollama or vLLM), Qwen3-Coder,
/// and which hosts count as this Mac's network.
final class LocalServerHostTests: XCTestCase {
    private func connection(_ url: String, _ encoding: RemoteProtocolEncoding = .openAIChatCompletions) -> RemoteConnection {
        RemoteConnection(name: "c", apiBaseURL: url, encoding: encoding)
    }
    private func objects(_ url: String, _ model: String, _ encoding: RemoteProtocolEncoding = .openAIChatCompletions) -> Bool {
        LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: connection(url, encoding), modelID: model, usesResponsesAPI: false)
    }

    func testR1_OllamaAndVLLMKeepStringArguments() {
        // Ollama's OpenAI endpoint types `arguments` as a string and 400s on an object.
        XCTAssertFalse(objects("http://localhost:11434/v1", "qwen3.5:27b"))
        // Automatic on Ollama is still Ollama, once the server said so (/api/version), on any port.
        var ollama = connection("http://localhost:8080/v1", .automatic)
        ollama.recordServer(isLMStudio: false, isOllama: true)
        XCTAssertFalse(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: ollama, modelID: "qwen3.5:27b", usesResponsesAPI: false))
        XCTAssertEqual(ollama.apiProvider, .ollama)
        // A detected LM Studio row on the Standard Tool Format gets objects.
        var detected = connection("http://192.168.1.50:47213/v1", .openAIChatCompletions)
        detected.recordServer(isLMStudio: true, isOllama: false)
        XCTAssertTrue(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: detected, modelID: "qwen3.5-27b", usesResponsesAPI: false))
        XCTAssertFalse(objects("http://192.168.1.50:11434/v1", "qwen3.8:27b"))
        // vLLM on a LAN box also takes only strings.
        XCTAssertFalse(objects("http://192.168.1.50:8000/v1", "Qwen/Qwen3.8-27B"))
        XCTAssertFalse(objects("http://10.0.0.7:8000/v1", "Qwen/Qwen3.6-27B"))
        // LM Studio still gets objects.
        XCTAssertTrue(objects("http://localhost:1234/v1", "qwen/qwen3.8-27b", .automatic))
        XCTAssertTrue(objects("http://192.168.1.50:47213/v1", "qwen3.5-27b", .automatic), "LM Studio on any port")
    }

    func testQwen3CoderGetsObjectsOnLMStudio() {
        // Its template has the same `tool_call.arguments|items` loop.
        XCTAssertTrue(objects("http://localhost:1234/v1", "qwen/qwen3-coder-30b-a3b-instruct", .automatic))
        XCTAssertTrue(objects("http://localhost:1234/v1", "qwen3-coder-next", .automatic))
        XCTAssertFalse(objects("http://localhost:11434/v1", "qwen3-coder:30b"))
        XCTAssertFalse(objects("https://openrouter.ai/api/v1", "qwen/qwen3-coder", .automatic))
        XCTAssertFalse(objects("http://localhost:1234/v1", "qwen3-8b", .automatic))
    }

    func testTailscaleLMStudioGetsObjectsAndReasoning() {
        for url in ["http://100.101.102.103:1234/v1", "http://mac.tail1234.ts.net:1234/v1"] {
            XCTAssertTrue(objects(url, "qwen3.8-27b", .automatic), url)
            XCTAssertTrue(LocalChatHistoryPolicy.sendsReasoningContent(connection: connection(url, .automatic), usesResponsesAPI: false), url)
        }
    }

    func testPrivateHosts() {
        let privateHosts = [
            "http://localhost:1234/v1", "http://127.0.0.1:1234/v1", "http://127.0.0.2:1234/v1", "http://[::1]:1234/v1",
            "http://[fd00::5]:1234/v1", "http://[fdab:1::2]:1234/v1", "http://[fe80::1]:1234/v1",
            "http://100.64.0.1:1234/v1", "http://100.101.102.103:1234/v1", "http://100.127.255.254:1234/v1",
            "http://mac.tail1234.ts.net:1234/v1", "http://studio.lan:1234/v1", "http://studio.local:1234/v1",
            "http://10.0.0.7:1234/v1", "http://172.20.0.5:1234/v1", "http://192.168.1.20:1234/v1",
        ]
        for url in privateHosts { XCTAssertTrue(OpenAICompatibleAPI.isPrivateNetworkHost(url), url) }
        let publicHosts = [
            "http://10.foo.com/v1", "http://192.168.example.com/v1", "http://172.20.example.com/v1",
            "http://100.128.0.1:1234/v1", "http://100.63.255.255:1234/v1", "http://172.32.0.1/v1",
            "https://api.x.ai/v1", "https://openrouter.ai/api/v1", "http://[2001:db8::1]/v1", "http://notts.net/v1",
        ]
        for url in publicHosts { XCTAssertFalse(OpenAICompatibleAPI.isPrivateNetworkHost(url), url) }
    }

    /// Third-review host and server probes that hold today, pinned.
    func testReview3HostAndServerCases() {
        for url in ["http://[fe80::1%25en0]:1234/v1", "http://[fc00::1]/v1", "http://x.TS.NET/v1", "http://LOCALHOST:1234/v1"] {
            XCTAssertTrue(OpenAICompatibleAPI.isPrivateNetworkHost(url), url)
        }
        for url in ["http://[fbff::1]/v1", "http://[fec0::1]/v1", "http://10.0.0.1./v1", "http://1.2.3.4.nip.io/v1",
                    "http://192.168.1.5.example.com/v1", "http://ts.net/v1"] {
            XCTAssertFalse(OpenAICompatibleAPI.isPrivateNetworkHost(url), url)
        }
        XCTAssertTrue(objects("http://localhost:1235/v1", "qwen3.8-27b", .automatic), "LM Studio on another port, Automatic")
        XCTAssertTrue(objects("http://localhost:1234/v1", "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit", .automatic))
        XCTAssertFalse(objects("http://localhost:1234/v1", "qwen2.5-coder-32b", .automatic))
        XCTAssertFalse(objects("https://api.example.com:1234/v1", "qwen3-coder-next", .automatic))
        XCTAssertFalse(objects("http://192.168.1.50:8000/v1", "Qwen/Qwen3.8-27B", .openAIChatCompletions))
    }
}

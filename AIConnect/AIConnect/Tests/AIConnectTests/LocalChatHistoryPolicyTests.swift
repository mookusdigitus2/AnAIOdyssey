// SPDX-License-Identifier: MIT
import XCTest
@testable import AIConnect
import AIModelOptions

/// PR #219 review B2: tool arguments go back as a JSON object only to a local or private host
/// running Qwen3.5 or later; every other Chat Completions server keeps OpenAI's string.
final class LocalChatHistoryPolicyTests: XCTestCase {
    private func connection(_ url: String, _ encoding: RemoteProtocolEncoding = .automatic) -> RemoteConnection {
        RemoteConnection(name: "c", apiBaseURL: url, encoding: encoding)
    }

    func testObjectArgumentsOnlyForLocalQwen35AndLater() {
        let yes: [(String, String)] = [
            ("http://localhost:1234/v1", "qwen/qwen3.8-27b"),
            ("http://127.0.0.1:1234/v1", "Qwen3.8-Flash-Next"),
            ("http://192.168.1.20:1234/v1", "qwen3.6-27b"),
            ("http://mac-mini.local:1234/v1", "lmstudio-community/qwen3.5-27b-mlx"),
        ]
        for (url, model) in yes {
            XCTAssertTrue(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: connection(url), modelID: model, usesResponsesAPI: false),
                          "\(url) \(model)")
        }
        let no: [(String, String, RemoteProtocolEncoding)] = [
            ("https://openrouter.ai/api/v1", "qwen/qwen3.8-27b", .automatic),
            ("https://api.groq.com/openai/v1", "qwen/qwen3.6-32b", .automatic),
            ("https://api.deepseek.com/v1", "deepseek-chat", .automatic),
            ("https://api.together.xyz/v1", "Qwen/Qwen3.8-27B", .openAIChatCompletions),
            ("http://localhost:1234/v1", "openai/gpt-oss-20b", .automatic),
            ("http://localhost:1234/v1", "openai/gpt-oss-20b", .lmStudioHarmony),
            ("http://localhost:1234/v1", "qwen2.5-7b-instruct", .automatic),
            ("http://localhost:1234/v1", "qwen3-8b", .automatic),
            ("https://example.com:1234/v1", "qwen3.8-27b", .automatic),
        ]
        for (url, model, encoding) in no {
            XCTAssertFalse(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: connection(url, encoding), modelID: model, usesResponsesAPI: false),
                           "\(url) \(model)")
        }
        XCTAssertFalse(LocalChatHistoryPolicy.sendsToolArgumentsAsObjects(connection: connection("http://localhost:1234/v1"),
                                                                          modelID: "qwen3.8-27b", usesResponsesAPI: true))
    }

    func testReasoningContentOnlyForLocalLMStudioChat() {
        XCTAssertTrue(LocalChatHistoryPolicy.sendsReasoningContent(connection: connection("http://localhost:1234/v1"), usesResponsesAPI: false))
        var detected = connection("http://192.168.1.20:1234/v1", .openAIChatCompletions)
        XCTAssertFalse(LocalChatHistoryPolicy.sendsReasoningContent(connection: detected, usesResponsesAPI: false),
                       "Standard on an unknown server is not LM Studio, whatever the port")
        detected.recordServer(isLMStudio: true, isOllama: false)
        XCTAssertTrue(LocalChatHistoryPolicy.sendsReasoningContent(connection: detected, usesResponsesAPI: false))
        XCTAssertFalse(LocalChatHistoryPolicy.sendsReasoningContent(connection: connection("https://openrouter.ai/api/v1"), usesResponsesAPI: false),
                       "an Automatic row on a cloud host is not LM Studio")
        XCTAssertFalse(LocalChatHistoryPolicy.sendsReasoningContent(connection: connection("https://api.x.ai/v1", .openAIChatCompletions),
                                                                    usesResponsesAPI: false))
        XCTAssertFalse(LocalChatHistoryPolicy.sendsReasoningContent(connection: connection("http://localhost:1234/v1"), usesResponsesAPI: true))
    }
}

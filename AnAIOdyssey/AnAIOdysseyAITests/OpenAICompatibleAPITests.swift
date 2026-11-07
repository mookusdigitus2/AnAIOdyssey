// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AnAIOdysseyAI
import AnAIOdysseyCore

final class OpenAICompatibleAPITests: XCTestCase {
    func testNormalizeBaseStripsChatCompletionsPath() {
        XCTAssertEqual(
            OpenAICompatibleAPI.normalizeBaseURL("https://api.openai.com/v1/chat/completions"),
            "https://api.openai.com/v1"
        )
    }

    func testBuildChatURLForOpenAI() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildChatCompletionsURL(baseURL: "https://api.openai.com/v1")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }

    func testBuildResponsesURLForOpenAI() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildResponsesURL(baseURL: "https://api.openai.com/v1")?.absoluteString,
            "https://api.openai.com/v1/responses"
        )
        XCTAssertEqual(
            OpenAICompatibleAPI.buildConversationURL(
                baseURL: "https://api.openai.com/v1",
                model: "gpt-6-astra",
                hasTools: false,
                provider: .openAICompatible
            )?.absoluteString,
            "https://api.openai.com/v1/responses"
        )
        XCTAssertEqual(
            OpenAICompatibleAPI.buildConversationURL(
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4o",
                hasTools: false,
                provider: .openAICompatible
            )?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            OpenAICompatibleAPI.buildConversationURL(
                baseURL: "https://openrouter.ai/api/v1",
                model: "gpt-6-astra",
                hasTools: true,
                provider: .openAICompatible
            )?.absoluteString,
            "https://openrouter.ai/api/v1/chat/completions"
        )
    }

    func testBuildChatURLForOpenRouter() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildChatCompletionsURL(baseURL: "https://openrouter.ai/api/v1")?.absoluteString,
            "https://openrouter.ai/api/v1/chat/completions"
        )
    }

    func testBuildChatURLForDeepSeek() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildChatCompletionsURL(baseURL: "https://api.deepseek.com")?.absoluteString,
            "https://api.deepseek.com/chat/completions"
        )
    }

    func testBuildChatURLForLocalLMStudio() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildChatCompletionsURL(baseURL: "http://localhost:1234/v1")?.absoluteString,
            "http://localhost:1234/v1/chat/completions"
        )
    }

    func testBuildChatURLForGemini() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildChatCompletionsURL(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
            )?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
    }

    func testDetectGeminiProvider() {
        XCTAssertEqual(
            OpenAICompatibleAPI.detectProvider(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"
            ),
            .gemini
        )
    }

    func testLocalhostDoesNotRequireAPIKey() {
        XCTAssertTrue(
            OpenAICompatibleAPI.isConfigured(
                baseURL: "http://localhost:1234/v1",
                apiKey: ""
            )
        )
    }

    func testPrivateNetworkDoesNotRequireAPIKey() {
        XCTAssertTrue(
            OpenAICompatibleAPI.isConfigured(
                baseURL: "http://192.168.1.100:11435/v1",
                apiKey: ""
            )
        )
    }

    func testParseModelsResponseFromOpenAIStyleList() throws {
        let json = """
        {"object":"list","data":[{"id":"gpt-oss-120b"},{"id":"openai/gpt-oss-120b"}]}
        """
        let ids = try OpenAICompatibleAPI.parseModelsResponse(try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertTrue(ids.contains("gpt-oss-120b"))
        XCTAssertTrue(ids.contains("openai/gpt-oss-120b"))
    }

    func testParseModelsResponseFromOllamaStyleList() throws {
        let json = """
        {"models":[{"name":"llama3.2:latest"}]}
        """
        let ids = try OpenAICompatibleAPI.parseModelsResponse(try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(ids, ["llama3.2:latest"])
    }

    func testResolvedModelIDPrefersNamespacedMatch() {
        let available = ["gpt-oss-120b", "openai/gpt-oss-120b", "qwen/qwen3-coder-next"]
        XCTAssertEqual(
            OpenAICompatibleAPI.resolvedModelID(requested: "gpt-oss-120b", available: available),
            "openai/gpt-oss-120b"
        )
        XCTAssertEqual(
            OpenAICompatibleAPI.resolvedModelID(requested: "qwen3-coder-next", available: available),
            "qwen/qwen3-coder-next"
        )
    }

    func testCloudProviderRequiresAPIKey() {
        XCTAssertFalse(
            OpenAICompatibleAPI.isConfigured(
                baseURL: "https://api.openai.com/v1",
                apiKey: ""
            )
        )
    }

    func testOpenRouterHeadersIncludeAttribution() {
        let headers = OpenAICompatibleAPI.requestHeaders(
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "secret",
            streaming: true
        )
        XCTAssertEqual(headers["Authorization"], "Bearer secret")
        XCTAssertNotNil(headers["HTTP-Referer"])
        XCTAssertEqual(headers["X-OpenRouter-Title"], AIConnectBranding.appName)
    }

    func testParseStreamingChunkFromOpenAIStyleDelta() throws {
        let json = """
        {"choices":[{"delta":{"content":"Hello"}}]}
        """
        XCTAssertEqual(OpenAICompatibleAPI.parseStreamingChunk(json), "Hello")
    }

    func testParseCompletionResponseFromOpenAIStyleMessage() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"Hi there"}}]}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertEqual(try OpenAICompatibleAPI.parseCompletionResponse(data), "Hi there")
    }

    func testAppendUserTurnAvoidsDuplicatePrompt() {
        let history = [
            LLMChatTurn(role: "user", content: "Hello"),
            LLMChatTurn(role: "assistant", content: "Hi"),
            LLMChatTurn(role: "user", content: "Next question"),
        ]
        let messages = OpenAICompatibleAPI.appendUserTurn(history: history, prompt: "Next question")
        XCTAssertEqual(messages.count, 3)
    }

    func testAppendUserTurnSkipsEmptyPrompt() {
        let history = [LLMChatTurn(role: "user", content: "Hello")]
        let messages = OpenAICompatibleAPI.appendUserTurn(history: history, prompt: "")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.last?["content"], "Hello")
    }

    func testAppendUserTurnDropsBlankHistoryTurns() {
        let history = [
            LLMChatTurn(role: "user", content: "hello"),
            LLMChatTurn(role: "user", content: " "),
            LLMChatTurn(role: "user", content: ""),
        ]
        let messages = OpenAICompatibleAPI.appendUserTurn(history: history, prompt: "")
        XCTAssertEqual(messages.map(\.["content"]), ["hello"])
    }

    func testParseCompletionFallsBackToLMStudioReasoningField() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"","reasoning":"The answer is gecko."}}]}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertEqual(try OpenAICompatibleAPI.parseCompletionResponse(data), "The answer is gecko.")
    }

    func testParseStreamingReasoningReadsBothLMStudioFields() {
        let legacy = #"{"choices":[{"delta":{"reasoning_content":"think"}}]}"#
        let current = #"{"choices":[{"delta":{"reasoning":"think"}}]}"#
        XCTAssertEqual(OpenAICompatibleAPI.parseStreamingReasoning(legacy), "think")
        XCTAssertEqual(OpenAICompatibleAPI.parseStreamingReasoning(current), "think")
        XCTAssertNil(OpenAICompatibleAPI.parseStreamingChunk(current))
    }

    func testAppendUserTurnAddsNewPrompt() {
        let history = [
            LLMChatTurn(role: "user", content: "Hello"),
            LLMChatTurn(role: "assistant", content: "Hi"),
        ]
        let messages = OpenAICompatibleAPI.appendUserTurn(history: history, prompt: "Next")
        XCTAssertEqual(messages.last?["content"], "Next")
    }

    func testDetectsImageGenerationModels() {
        XCTAssertTrue(OpenAICompatibleAPI.isImageGenerationModel("dall-e-3"))
        XCTAssertTrue(OpenAICompatibleAPI.isImageGenerationModel("dall-e-2"))
        XCTAssertTrue(OpenAICompatibleAPI.isImageGenerationModel("gpt-image-1"))
        XCTAssertTrue(OpenAICompatibleAPI.isImageGenerationModel("openai/gpt-image-1"))
        XCTAssertTrue(OpenAICompatibleAPI.isImageGenerationModel("chatgpt-image-latest"))
        XCTAssertFalse(OpenAICompatibleAPI.isImageGenerationModel("gpt-4o-mini"))
        XCTAssertFalse(OpenAICompatibleAPI.isImageGenerationModel("o3-mini"))
    }

    func testDetectsImageEditModels() {
        XCTAssertTrue(OpenAICompatibleAPI.isImageEditModel("gpt-image-1"))
        XCTAssertTrue(OpenAICompatibleAPI.isImageEditModel("openai/gpt-image-1"))
        XCTAssertTrue(OpenAICompatibleAPI.isImageEditModel("dall-e-2"))
        XCTAssertTrue(OpenAICompatibleAPI.isImageEditModel("chatgpt-image-latest"))
        XCTAssertFalse(OpenAICompatibleAPI.isImageEditModel("dall-e-3"))
        XCTAssertFalse(OpenAICompatibleAPI.isImageEditModel("gpt-4o-mini"))
    }

    func testBuildImagesEditsURL() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildImagesEditsURL(
                baseURL: "https://api.openai.com/v1",
                provider: .openAICompatible
            )?.absoluteString,
            "https://api.openai.com/v1/images/edits"
        )
        XCTAssertNil(
            OpenAICompatibleAPI.buildImagesEditsURL(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                provider: .gemini
            )
        )
    }

    func testImageEditFormBodyIncludesPromptAndFile() {
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let form = OpenAICompatibleAPI.imageEditFormBody(
            model: "gpt-image-1",
            prompt: "make it night",
            imageData: image,
            filename: "photo.png",
            mimeType: "image/png"
        )
        XCTAssertTrue(form.contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: form.data, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"prompt\""))
        XCTAssertTrue(body.contains("make it night"))
        XCTAssertTrue(body.contains("name=\"model\""))
        XCTAssertTrue(body.contains("gpt-image-1"))
        XCTAssertTrue(body.contains("name=\"image[]\""))
        XCTAssertFalse(body.contains("name=\"image\";"))
        XCTAssertTrue(body.contains("filename=\"photo.png\""))
        XCTAssertTrue(body.contains("image/png"))
        XCTAssertTrue(body.contains("output_format"))
        XCTAssertFalse(body.contains("response_format"))
    }

    func testImageEditFormBodyUsesImageFieldForDallE2() {
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let form = OpenAICompatibleAPI.imageEditFormBody(
            model: "dall-e-2",
            prompt: "make it night",
            imageData: image,
            filename: "photo.png",
            mimeType: "image/png"
        )
        let body = String(decoding: form.data, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"image\"; filename=\"photo.png\""))
        XCTAssertFalse(body.contains("name=\"image[]\""))
        XCTAssertTrue(body.contains("response_format"))
    }

    func testDetectsNonConversationalModels() {
        XCTAssertTrue(OpenAICompatibleAPI.isNonConversationalModel("text-embedding-3-small"))
        XCTAssertTrue(OpenAICompatibleAPI.isNonConversationalModel("tts-1-hd"))
        XCTAssertTrue(OpenAICompatibleAPI.isNonConversationalModel("gpt-4o-mini-tts"))
        XCTAssertTrue(OpenAICompatibleAPI.isNonConversationalModel("whisper-1"))
        XCTAssertTrue(OpenAICompatibleAPI.isNonConversationalModel("gpt-4o-transcribe"))
        XCTAssertTrue(OpenAICompatibleAPI.isNonConversationalModel("omni-moderation-latest"))
        XCTAssertTrue(OpenAICompatibleAPI.isNonConversationalModel("gpt-4o-realtime-preview"))
        XCTAssertTrue(OpenAICompatibleAPI.isNonConversationalModel("davinci-002"))
        // Chat and image models must stay pickable.
        XCTAssertFalse(OpenAICompatibleAPI.isNonConversationalModel("gpt-4o-mini"))
        XCTAssertFalse(OpenAICompatibleAPI.isNonConversationalModel("gpt-5"))
        XCTAssertFalse(OpenAICompatibleAPI.isNonConversationalModel("dall-e-3"))
        XCTAssertFalse(OpenAICompatibleAPI.isNonConversationalModel("gpt-image-1"))
        XCTAssertFalse(OpenAICompatibleAPI.isNonConversationalModel("llama3.2:latest"))
    }

    func testBuildImagesGenerationsURL() {
        XCTAssertEqual(
            OpenAICompatibleAPI.buildImagesGenerationsURL(
                baseURL: "https://api.openai.com/v1",
                provider: .openAICompatible
            )?.absoluteString,
            "https://api.openai.com/v1/images/generations"
        )
        XCTAssertNil(
            OpenAICompatibleAPI.buildImagesGenerationsURL(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                provider: .gemini
            )
        )
    }

    func testImageGenerationPayloadRequestsBase64OnlyForDallE() throws {
        let dallE = OpenAICompatibleAPI.imageGenerationPayload(model: "dall-e-3", prompt: "a pig")
        XCTAssertEqual(dallE["model"] as? String, "dall-e-3")
        XCTAssertEqual(dallE["prompt"] as? String, "a pig")
        XCTAssertEqual(dallE["n"] as? Int, 1)
        XCTAssertEqual(dallE["response_format"] as? String, "b64_json")

        // gpt-image-* models reject response_format (they always return base64)
        // and should request PNG so gallery can decode the result.
        let gptImage = OpenAICompatibleAPI.imageGenerationPayload(model: "gpt-image-1", prompt: "a pig")
        XCTAssertNil(gptImage["response_format"])
        XCTAssertEqual(gptImage["output_format"] as? String, "png")
    }

    func testParseImageGenerationResponseBase64() throws {
        let pngByte = Data([0x89]).base64EncodedString()
        let json = """
        {"created":1,"data":[{"b64_json":"\(pngByte)"}]}
        """
        let payload = try OpenAICompatibleAPI.parseImageGenerationResponse(try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(payload, .imageData(Data([0x89])))
    }

    func testParseImageGenerationResponseURL() throws {
        let json = """
        {"created":1,"data":[{"url":"https://example.com/image.png"}]}
        """
        let payload = try OpenAICompatibleAPI.parseImageGenerationResponse(try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(payload, .remoteURL(try XCTUnwrap(URL(string: "https://example.com/image.png"))))
    }

    func testParseImageGenerationResponseSurfacesProviderError() {
        let json = """
        {"error":{"message":"Billing hard limit reached","type":"invalid_request_error"}}
        """
        XCTAssertThrowsError(
            try OpenAICompatibleAPI.parseImageGenerationResponse(json.data(using: .utf8)!)
        ) { error in
            XCTAssertTrue("\(error)".contains("Billing hard limit reached"))
        }
    }

    func testAnthropicMessagesPayloadHoistsSystemAndSetsMaxTokens() {
        let payload = OpenAICompatibleAPI.anthropicMessagesPayload(
            model: "claude-3-5-sonnet-latest",
            messages: [
                ["role": "system", "content": "Be concise."],
                ["role": "user", "content": "Hello"],
            ],
            stream: true,
            maxTokens: 2048
        )
        XCTAssertEqual(payload["model"] as? String, "claude-3-5-sonnet-latest")
        XCTAssertEqual(payload["max_tokens"] as? Int, 2048)
        XCTAssertEqual(payload["system"] as? String, "Be concise.")
        let messages = payload["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
    }
}

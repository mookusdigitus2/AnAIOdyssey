// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import AIModelOptions

final class VoiceTTSCodecTests: XCTestCase {
    func testElevenLabsStreamInputURLIncludesModelAndPCMFormat() throws {
        let url = try ElevenLabsTTSCodec.streamInputURL(
            voiceID: "21m00Tcm4TlvDq8ikWAM",
            modelID: "eleven_flash_v2_5"
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.elevenlabs.io")
        XCTAssertTrue(url.path.contains("/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM/stream-input"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "model_id" })?.value, "eleven_flash_v2_5")
        XCTAssertEqual(items.first(where: { $0.name == "output_format" })?.value, "pcm_24000")
    }

    func testElevenLabsTextPayloads() throws {
        let text = try VoiceJSON.encode(ElevenLabsTTSCodec.textPayload("Hello there. "))
        let object = VoiceJSON.object(from: text)
        XCTAssertEqual(object?["text"] as? String, "Hello there. ")
        XCTAssertNil(object?["flush"])

        let flush = VoiceJSON.object(from: try VoiceJSON.encode(ElevenLabsTTSCodec.flushPayload()))
        XCTAssertEqual(flush?["text"] as? String, " ")
        XCTAssertEqual(flush?["flush"] as? Bool, true)

        let close = VoiceJSON.object(from: try VoiceJSON.encode(ElevenLabsTTSCodec.closePayload()))
        XCTAssertEqual(close?["text"] as? String, "")
    }

    func testElevenLabsParsesAudioAndFinal() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let message = #"{"audio":"\#(pcm.base64EncodedString())","isFinal":true}"#
        let incoming = ElevenLabsTTSCodec.parseIncoming(message)
        XCTAssertEqual(incoming.audio, pcm)
        XCTAssertTrue(incoming.isFinal)
        XCTAssertNil(incoming.errorMessage)
    }

    func testElevenLabsParsesErrorWithoutAudio() {
        let incoming = ElevenLabsTTSCodec.parseIncoming(#"{"message":"quota exceeded"}"#)
        XCTAssertEqual(incoming.errorMessage, "quota exceeded")
        XCTAssertNil(incoming.audio)
        XCTAssertFalse(incoming.isFinal)
    }

    func testElevenLabsSafeBlockLength() {
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "The qui"), 0)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "Hello."), 0)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "Hello there. How are"), 13)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "One, two and thr"), 5)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "Line one\nnext"), 9)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "Line one\r\nnext"), 9)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "pi is 3.14159 and mo"), 0)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "see https://example.com/a.b?c=d"), 0)
        XCTAssertEqual(ElevenLabsTTSCodec.safeBlockLength(of: "He said \"stop.\" Then left"), 16)
    }

    func testXAIWebSocketURLRequiresQueryConfig() throws {
        let url = try XAITTSCodec.webSocketURL(
            XAITTSCodec.ConnectionConfig(language: "en", voice: "eve", codec: "pcm", sampleRate: 24_000)
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.x.ai")
        XCTAssertEqual(url.path, "/v1/tts")
        let query = url.query ?? ""
        XCTAssertFalse(query.isEmpty, "bare wss://api.x.ai/v1/tts is rejected with HTTP 400")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "language" })?.value, "en")
        XCTAssertEqual(items.first(where: { $0.name == "voice" })?.value, "eve")
        XCTAssertEqual(items.first(where: { $0.name == "codec" })?.value, "pcm")
        XCTAssertEqual(items.first(where: { $0.name == "sample_rate" })?.value, "24000")
        XCTAssertEqual(items.first(where: { $0.name == "optimize_streaming_latency" })?.value, "1")
    }

    func testXAIWebSocketURLRejectsMissingLanguage() {
        XCTAssertThrowsError(
            try XAITTSCodec.webSocketURL(XAITTSCodec.ConnectionConfig(language: "  ", voice: "eve"))
        )
    }

    func testXAITextDeltaThenDone() throws {
        let delta = VoiceJSON.object(from: try VoiceJSON.encode(XAITTSCodec.textDeltaMessage("Hello there. ")))
        XCTAssertEqual(delta?["type"] as? String, "text.delta")
        XCTAssertEqual(delta?["delta"] as? String, "Hello there. ")

        let done = VoiceJSON.object(from: try VoiceJSON.encode(XAITTSCodec.textDoneMessage()))
        XCTAssertEqual(done?["type"] as? String, "text.done")
        XCTAssertNil(done?["delta"])
    }

    func testXAIParsesAudioDeltaDoneAndError() {
        let pcm = Data([0x11, 0x22])
        let delta = XAITTSCodec.parseIncoming(
            #"{"type":"audio.delta","delta":"\#(pcm.base64EncodedString())"}"#
        )
        XCTAssertEqual(delta, .audioDelta(pcm))
        XCTAssertEqual(XAITTSCodec.parseIncoming(#"{"type":"audio.done","trace_id":"abc"}"#), .audioDone)
        XCTAssertEqual(XAITTSCodec.parseIncoming(#"{"type":"audio.clear"}"#), .audioClear)
        XCTAssertEqual(
            XAITTSCodec.parseIncoming(#"{"type":"error","message":"bad voice"}"#),
            .error("bad voice")
        )
        XCTAssertEqual(XAITTSCodec.parseIncoming(#"{"type":"session.updated"}"#), .ignored)
    }

    func testXAIParsesVoicesList() throws {
        let json = """
        {"voices":[{"voice_id":"eve","name":"Eve"},{"voice_id":"ara","name":"Ara","preview_url":"https://example.com/ara.mp3"}]}
        """.data(using: .utf8)!
        let voices = try XAITTSCodec.parseVoicesResponse(json)
        XCTAssertEqual(voices.map(\.id), ["eve", "ara"])
        XCTAssertEqual(voices.map(\.displayName), ["Eve", "Ara"])
        XCTAssertEqual(voices[1].previewURL, "https://example.com/ara.mp3")
        XCTAssertNil(voices[0].previewURL)
    }

    func testElevenLabsParsesVoicesWithPreviewURL() throws {
        let json = """
        {"voices":[{"voice_id":"21m00Tcm4TlvDq8ikWAM","name":"Rachel","preview_url":"https://example.com/rachel.mp3"}]}
        """.data(using: .utf8)!
        let voices = try ElevenLabsTTSCodec.parseVoicesResponse(json)
        XCTAssertEqual(voices[0].displayName, "Rachel")
        XCTAssertEqual(voices[0].previewURL, "https://example.com/rachel.mp3")
        XCTAssertFalse(voices[0].displayName.contains("21m00"))
    }

    func testElevenLabsV2VoicesURLPaginates() throws {
        let first = try ElevenLabsTTSCodec.voicesURL(pageSize: 100)
        XCTAssertEqual(first.scheme, "https")
        XCTAssertEqual(first.host, "api.elevenlabs.io")
        XCTAssertEqual(first.path, "/v2/voices")
        let firstItems = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(firstItems.first(where: { $0.name == "page_size" })?.value, "100")
        XCTAssertNil(firstItems.first(where: { $0.name == "next_page_token" }))

        let next = try ElevenLabsTTSCodec.voicesURL(pageSize: 50, nextPageToken: " page-2 ")
        let nextItems = URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(nextItems.first(where: { $0.name == "page_size" })?.value, "50")
        XCTAssertEqual(nextItems.first(where: { $0.name == "next_page_token" })?.value, "page-2")
    }

    func testElevenLabsParsesV2VoicesPage() throws {
        let json = """
        {
          "voices": [
            {"voice_id":"21m00Tcm4TlvDq8ikWAM","name":"Rachel","category":"premade"},
            {"voiceId":"VoiceIdPlaceholder01","name":"My custom voice","previewUrl":"https://example.com/custom.mp3"}
          ],
          "has_more": true,
          "next_page_token": "tok-2",
          "total_count": 40
        }
        """.data(using: .utf8)!
        let page = try ElevenLabsTTSCodec.parseVoicesPage(json)
        XCTAssertEqual(page.voices.map(\.id), ["21m00Tcm4TlvDq8ikWAM", "VoiceIdPlaceholder01"])
        XCTAssertEqual(page.voices[1].displayName, "My custom voice")
        XCTAssertEqual(page.voices[1].previewURL, "https://example.com/custom.mp3")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextPageToken, "tok-2")
        XCTAssertEqual(
            ElevenLabsTTSCodec.continuePageToken(
                hasMore: page.hasMore,
                nextPageToken: page.nextPageToken
            ),
            "tok-2"
        )
    }

    func testElevenLabsV2PaginationStopsWithoutTokenOrHasMore() {
        XCTAssertNil(
            ElevenLabsTTSCodec.continuePageToken(hasMore: false, nextPageToken: "tok-2")
        )
        XCTAssertNil(
            ElevenLabsTTSCodec.continuePageToken(hasMore: true, nextPageToken: "  ")
        )
        XCTAssertNil(
            ElevenLabsTTSCodec.continuePageToken(
                hasMore: true,
                nextPageToken: "tok-2",
                previousToken: "tok-2"
            )
        )
        XCTAssertEqual(
            ElevenLabsTTSCodec.continuePageToken(hasMore: true, nextPageToken: "tok-3", previousToken: "tok-2"),
            "tok-3"
        )
    }

    func testElevenLabsV1VoicesBodyStillParsesAsSinglePage() throws {
        let json = """
        {"voices":[{"voice_id":"21m00Tcm4TlvDq8ikWAM","name":"Rachel"}]}
        """.data(using: .utf8)!
        let page = try ElevenLabsTTSCodec.parseVoicesPage(json)
        XCTAssertEqual(page.voices.map(\.id), ["21m00Tcm4TlvDq8ikWAM"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextPageToken)
    }

    func testElevenLabsParsesVoiceDetailWithoutPreview() throws {
        let json = """
        {"voice_id":"VoiceIdPlaceholder01","name":"Odyssey","category":"professional"}
        """.data(using: .utf8)!
        let record = try ElevenLabsTTSCodec.parseVoiceDetail(json)
        XCTAssertEqual(record.voiceID, "VoiceIdPlaceholder01")
        XCTAssertEqual(record.name, "Odyssey")
        XCTAssertNil(record.previewURL)
    }

    func testElevenLabsParsesSharedVoicesAndMatchesID() throws {
        let json = """
        {
          "voices": [
            {
              "public_owner_id": "owner-1",
              "voice_id": "otherVoice",
              "name": "Other",
              "free_users_allowed": true
            },
            {
              "public_owner_id": "owner-123",
              "voice_id": "VoiceIdPlaceholder01",
              "name": "Odyssey",
              "preview_url": "https://example.com/odyssey.mp3",
              "free_users_allowed": false
            }
          ],
          "has_more": false
        }
        """.data(using: .utf8)!
        let voices = try ElevenLabsTTSCodec.parseSharedVoices(json)
        XCTAssertEqual(voices.count, 2)
        let match = ElevenLabsTTSCodec.matchingSharedVoice(
            in: voices,
            voiceID: "voiceidplaceholder01"
        )
        XCTAssertEqual(match?.name, "Odyssey")
        XCTAssertEqual(match?.publicOwnerID, "owner-123")
        XCTAssertEqual(match?.previewURL, "https://example.com/odyssey.mp3")
        XCTAssertEqual(match?.freeUsersAllowed, false)
        XCTAssertNil(ElevenLabsTTSCodec.matchingSharedVoice(in: voices, voiceID: "missing"))
    }

    func testElevenLabsSharedVoiceURLsAndAddBody() throws {
        let shared = try ElevenLabsTTSCodec.sharedVoicesURL(search: "VoiceIdPlaceholder01")
        XCTAssertEqual(shared.path, "/v1/shared-voices")
        let items = URLComponents(url: shared, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "search" })?.value, "VoiceIdPlaceholder01")

        let detail = try ElevenLabsTTSCodec.voiceDetailURL(voiceID: "VoiceIdPlaceholder01")
        XCTAssertEqual(detail.path, "/v1/voices/VoiceIdPlaceholder01")

        let add = try ElevenLabsTTSCodec.addSharedVoiceURL(
            publicOwnerID: "owner-123",
            voiceID: "VoiceIdPlaceholder01"
        )
        XCTAssertEqual(add.path, "/v1/voices/add/owner-123/VoiceIdPlaceholder01")
        XCTAssertEqual(ElevenLabsTTSCodec.addSharedVoiceBody(name: "Odyssey")["new_name"] as? String, "Odyssey")
    }

    func testElevenLabsPaidPlanErrorMapping() {
        XCTAssertTrue(
            ElevenLabsVoiceErrors.isPaidPlanRestriction(
                statusCode: 403,
                body: #"{"detail":{"status":"missing_permissions","message":"free users cannot use Voice Library voices"}}"#
            )
        )
        XCTAssertTrue(
            ElevenLabsVoiceErrors.isPaidPlanRestriction(
                statusCode: 402,
                body: "payment required"
            )
        )
        XCTAssertTrue(ElevenLabsVoiceErrors.isPaidPlanRestriction(freeUsersAllowed: false))
        XCTAssertFalse(ElevenLabsVoiceErrors.isPaidPlanRestriction(freeUsersAllowed: true))
        XCTAssertEqual(
            ElevenLabsVoiceErrors.userFacingMessage(
                statusCode: 403,
                body: "This voice is not available on your current plan."
            ),
            ElevenLabsVoiceErrors.paidPlanMessage
        )
        XCTAssertEqual(
            ElevenLabsVoiceErrors.userFacingTTSMessage("upgrade your subscription to use this voice"),
            ElevenLabsVoiceErrors.paidPlanMessage
        )
        XCTAssertEqual(
            ElevenLabsVoiceErrors.userFacingMessage(statusCode: 404, body: "missing"),
            ElevenLabsVoiceErrors.notFoundMessage
        )
        XCTAssertEqual(
            ElevenLabsVoiceErrors.userFacingMessage(statusCode: 401, body: "invalid api key"),
            ElevenLabsVoiceErrors.keyRejectedMessage
        )
        XCTAssertFalse(
            ElevenLabsVoiceErrors.isPaidPlanRestriction(statusCode: 401, body: "invalid api key")
        )
    }

    func testElevenLabsPickerKeepsSavedIDWhenFetchOmitsIt() {
        let fetched = [VoiceOption(id: "21m00Tcm4TlvDq8ikWAM", displayName: "Rachel")]
        let added = [VoiceOption(id: "added-1", displayName: "Pinned")]
        let sections = VoiceCatalog.elevenLabsPickerSections(
            fetched: fetched,
            added: added,
            currentID: "VoiceIdPlaceholder01"
        )
        XCTAssertEqual(sections.added.map(\.id), ["added-1", "VoiceIdPlaceholder01"])
        XCTAssertEqual(sections.added.last?.displayName, ElevenLabsVoiceErrors.customVoiceName)
        XCTAssertTrue(sections.catalog.contains(where: { $0.id == "21m00Tcm4TlvDq8ikWAM" }))
        XCTAssertFalse(sections.catalog.contains(where: { $0.id == "VoiceIdPlaceholder01" }))
        XCTAssertFalse(sections.catalog.contains(where: { $0.id == "added-1" }))

        let selected = VoiceCatalog.selectedVoice(
            currentID: "VoiceIdPlaceholder01",
            from: sections.added + sections.catalog
        )
        XCTAssertEqual(selected?.id, "VoiceIdPlaceholder01")
        XCTAssertNotEqual(selected?.id, sections.catalog.first?.id)

        let missing = VoiceCatalog.selectedVoice(currentID: "only-saved", from: fetched)
        XCTAssertEqual(missing?.id, "only-saved")
        XCTAssertEqual(missing?.displayName, ElevenLabsVoiceErrors.customVoiceName)
    }

    func testElevenLabsAddedVoicesRoundTrip() {
        let record = ElevenLabsVoiceRecord(
            voiceID: "VoiceIdPlaceholder01",
            name: "Odyssey",
            previewURL: "https://example.com/o.mp3",
            publicOwnerID: "owner-123",
            freeUsersAllowed: false
        )
        let encoded = ElevenLabsTTSCodec.encodeAddedVoices([record])
        let decoded = ElevenLabsTTSCodec.decodeAddedVoices(encoded)
        XCTAssertEqual(decoded, [record])
        XCTAssertTrue(ElevenLabsTTSCodec.decodeAddedVoices(nil).isEmpty)
    }

    func testXAIAuthorizationIsBearer() {
        XCTAssertEqual(XAITTSCodec.authorizationHeader(apiKey: "  sk-xai  "), "Bearer sk-xai")
    }

    func testOpenAISpeechURLAndBody() throws {
        let url = try OpenAITTSCodec.speechURL(baseURL: "https://api.openai.com/v1/")
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1/audio/speech")

        let body = OpenAITTSCodec.requestBody(
            model: "gpt-4o-mini-tts",
            voice: "coral",
            input: "Hello there."
        )
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(body["voice"] as? String, "coral")
        XCTAssertEqual(body["input"] as? String, "Hello there.")
        XCTAssertEqual(body["response_format"] as? String, "pcm")
        XCTAssertEqual(body["stream_format"] as? String, "audio")

        let preview = OpenAITTSCodec.previewBody(model: "gpt-4o-mini-tts", voice: "alloy")
        XCTAssertEqual(preview["response_format"] as? String, "mp3")
        XCTAssertNil(preview["stream_format"])
        XCTAssertEqual(preview["input"] as? String, VoiceCatalog.previewPhrase)
    }

    func testOpenAILegacyModelsOmitNewerVoices() {
        let mini = OpenAITTSCodec.voices(forModel: "gpt-4o-mini-tts").map(\.id)
        XCTAssertTrue(mini.contains("marin"))
        XCTAssertTrue(mini.contains("cedar"))
        XCTAssertTrue(mini.contains("verse"))
        XCTAssertTrue(mini.contains("ballad"))

        let tts1 = OpenAITTSCodec.voices(forModel: "tts-1").map(\.id)
        XCTAssertFalse(tts1.contains("marin"))
        XCTAssertTrue(tts1.contains("alloy"))
        XCTAssertEqual(OpenAITTSCodec.voices(forModel: "tts-1-hd").map(\.id), tts1)
    }

    func testOpenAIErrorBody() {
        let data = #"{"error":{"message":"Invalid voice"}}"#.data(using: .utf8)!
        XCTAssertEqual(OpenAITTSCodec.parseErrorBody(data), "Invalid voice")
    }

    func testPCMStreamFramerAlignsInt16AndFlushesRemainder() {
        var buffer = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let first = PCMStreamFramer.takeAlignedFrames(from: &buffer, minBytes: 4)
        XCTAssertEqual(first, Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(buffer, Data([0x05]))

        let none = PCMStreamFramer.takeAlignedFrames(from: &buffer, minBytes: 4)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(buffer, Data([0x05]))

        buffer.append(0x06)
        let flushed = PCMStreamFramer.takeAlignedFrames(from: &buffer, minBytes: 4, flushAll: true)
        XCTAssertEqual(flushed, Data([0x05, 0x06]))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testVoiceCatalogHidesProvidersWithoutKeys() {
        XCTAssertEqual(
            VoiceCatalog.availableProviders(
                elevenLabsKeyConfigured: false,
                openAIKeyConfigured: false,
                xaiKeyConfigured: false
            ),
            [.system]
        )
        XCTAssertEqual(
            VoiceCatalog.availableProviders(
                elevenLabsKeyConfigured: true,
                openAIKeyConfigured: true,
                xaiKeyConfigured: true
            ),
            [.system, .elevenLabs, .openai, .xai]
        )
        XCTAssertEqual(
            VoiceCatalog.resolvedProvider("openai", available: [.system, .elevenLabs]),
            .system
        )
        XCTAssertEqual(
            VoiceCatalog.resolvedProvider("xai", available: [.system, .xai]),
            .xai
        )
    }

    func testVoiceCatalogResolvesModelsAndCustomVoiceIDs() {
        XCTAssertEqual(
            VoiceCatalog.resolvedModelID("nope", for: .openai),
            "gpt-4o-mini-tts"
        )
        XCTAssertEqual(
            VoiceCatalog.resolvedVoiceID("", for: .xai),
            "eve"
        )
        let including = VoiceCatalog.voicesIncludingCurrent(
            "custom-voice",
            for: .elevenLabs
        )
        XCTAssertEqual(including.first?.id, "custom-voice")
    }

    func testVoiceListUsesFriendlyNamesWithoutProviderOrModelIDs() {
        for voice in VoiceCatalog.voices(for: .openai) {
            XCTAssertFalse(voice.displayName.contains("gpt-"))
            XCTAssertFalse(voice.displayName.contains("tts-"))
            XCTAssertFalse(voice.displayName.contains("openai"))
            XCTAssertEqual(voice.displayName, VoiceCatalog.friendlyName(fromID: voice.id))
        }
        XCTAssertEqual(VoiceCatalog.voices(for: .xai).map(\.displayName), ["Eve", "Ara"])
        XCTAssertEqual(VoiceCatalog.friendlyName(fromID: "alloy"), "Alloy")
        XCTAssertEqual(
            VoiceCatalog.previewCacheKey(provider: .openai, voiceID: "alloy"),
            "openai|alloy"
        )
    }

    func testPreviewSampleCacheDoesNotRequireASecondStore() {
        let cache = VoicePreviewSampleCache()
        let key = VoiceCatalog.previewCacheKey(provider: .xai, voiceID: "ara")
        XCTAssertNil(cache.data(for: key))
        cache.store(Data([0x01, 0x02]), for: key)
        XCTAssertEqual(cache.data(for: key), Data([0x01, 0x02]))
        cache.store(Data([0x03]), for: key)
        XCTAssertEqual(cache.data(for: key), Data([0x03]))
    }
}

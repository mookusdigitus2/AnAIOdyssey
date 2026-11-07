// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class ElevenLabsChunkScheduleTests: XCTestCase {
    func testChunkLengthScheduleWithinElevenLabsLimits() throws {
        let payload = ElevenLabsTTSCodec.bootstrapPayload(apiKey: "k")
        let config = try XCTUnwrap(payload["generation_config"] as? [String: Any])
        let schedule = try XCTUnwrap(config["chunk_length_schedule"] as? [Int])
        XCTAssertFalse(schedule.isEmpty)
        for value in schedule {
            XCTAssertTrue((50...500).contains(value), "chunk length \(value) outside 50...500")
        }
    }
}

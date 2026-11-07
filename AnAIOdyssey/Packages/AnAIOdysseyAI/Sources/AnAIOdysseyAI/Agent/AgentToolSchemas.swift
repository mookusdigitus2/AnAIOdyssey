// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Builds OpenAI-compatible JSON tool schemas for native tool calling.
enum AgentToolSchemas {
    static func openAITools(for toolNames: Set<String>) -> [[String: Any]] {
        toolNames.sorted().map { name in
            [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description(for: name),
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "input": [
                                "type": "string",
                                "description": "Tool input body (same format as the fenced-block body).",
                            ],
                        ],
                        "required": [] as [String],
                    ] as [String: Any],
                ] as [String: Any],
            ]
        }
    }

    private static func description(for name: String) -> String {
        "\(AppBranding.appName) agent tool: \(name)"
    }

    static func toolBlock(from call: [String: Any]) -> AgentToolBlock? {
        ToolCallParsing.toolBlock(from: call)
    }

    static func parseToolInput(from arguments: Any?) -> String {
        ToolCallParsing.parseToolInput(from: arguments)
    }
}

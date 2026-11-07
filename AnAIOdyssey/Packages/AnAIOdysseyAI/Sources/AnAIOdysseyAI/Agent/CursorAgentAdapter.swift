// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

#if os(macOS)
import AppKit
#endif

/// Invokes the Cursor CLI as an external coding agent (macOS).
@MainActor
public final class CursorAgentAdapter: AgentAdapter {
    public let attributes = AgentAttributes(
        id: "cursor",
        displayName: "Cursor",
        vendor: "Cursor",
        tags: ["cursor", "coding"],
        capabilities: ["code", "refactor", "cli"],
        isSwitchable: false
    )

    private let cliPath: () -> String

    public init(cliPath: @escaping () -> String) {
        self.cliPath = cliPath
    }

    public var isAvailable: Bool {
        #if os(macOS)
        return CursorCLILocator.isInstalled(configuredPath: cliPath())
        #else
        return false
        #endif
    }

    public func run(assignment: AgentAssignment) async throws -> AgentRunResult {
        #if os(macOS)
        let prompt = buildPrompt(assignment)
        let output = try await runCLI(prompt: prompt)
        return AgentRunResult(output: output, metadata: ["adapter": "cursor"])
        #else
        throw AgentAdapterError.notAvailable("Cursor CLI is only available on macOS.")
        #endif
    }

    #if os(macOS)
    private func resolvedCLIPath() -> String {
        CursorCLILocator.executablePath(configuredPath: cliPath()) ?? {
            let configured = cliPath().trimmingCharacters(in: .whitespacesAndNewlines)
            if configured.hasPrefix("/") { return configured }
            return configured.isEmpty ? "/usr/local/bin/cursor" : configured
        }()
    }

    private func buildPrompt(_ assignment: AgentAssignment) -> String {
        var parts: [String] = []
        if let context = assignment.context?.combinedText {
            parts.append(context)
        }
        if let prompt = assignment.prompt {
            parts.append(prompt)
        }
        return parts.joined(separator: "\n\n")
    }

    private func runCLI(prompt: String) async throws -> String {
        let path = resolvedCLIPath()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw AgentAdapterError.notAvailable("Cursor CLI not found at \(path). Set the path in Settings → Agents.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            // Cursor agent subcommand (passes prompt via stdin when supported).
            process.arguments = ["agent"]
            let stdin = Pipe()
            process.standardInput = stdin
            let stdout = Pipe()
            process.standardError = stdout
            process.standardOutput = stdout
            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: text.isEmpty ? "(Cursor completed with no output)" : text)
                } else {
                    continuation.resume(throwing: AgentAdapterError.executionFailed(text.isEmpty ? "Cursor exited with code \(proc.terminationStatus)" : text))
                }
            }
            do {
                try process.run()
                if let data = prompt.data(using: .utf8) {
                    stdin.fileHandleForWriting.write(data)
                }
                stdin.fileHandleForWriting.closeFile()
            } catch {
                continuation.resume(throwing: AgentAdapterError.executionFailed(error.localizedDescription))
            }
        }
    }
    #endif
}

import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("applescript")

final class AppleScriptService: Service {
    static let shared = AppleScriptService()

    private let osascriptPath = "/usr/bin/osascript"
    private let defaultTimeout: Duration = .seconds(30)
    private let maxTimeout: Duration = .seconds(300)

    var tools: [Tool] {
        Tool(
            name: "applescript_execute",
            description:
                "Execute AppleScript code and return the result. Use for automating any scriptable macOS application including Finder, System Events, Chrome, Messages, Mail, Notes, and more.",
            inputSchema: .object(
                properties: [
                    "source": .string(
                        description: "The AppleScript source code to execute"
                    ),
                    "timeout": .integer(
                        description:
                            "Timeout in seconds (default 30, max 300)",
                        default: .int(30)
                    ),
                ],
                required: ["source"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Execute AppleScript",
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case .string(let source) = arguments["source"], !source.isEmpty else {
                throw NSError(
                    domain: "AppleScriptError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "AppleScript source is required"]
                )
            }

            let timeoutSeconds: Int
            if case .int(let t) = arguments["timeout"] {
                timeoutSeconds = min(max(t, 1), 300)
            } else {
                timeoutSeconds = 30
            }

            return try await self.executeScript(
                source: source,
                timeout: .seconds(timeoutSeconds)
            )
        }

        Tool(
            name: "applescript_list_apps",
            description:
                "List currently running applications that can be automated via AppleScript",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Scriptable Apps",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.executeScript(
                source: """
                    tell application "System Events"
                        set appNames to name of every process whose background only is false
                        set output to ""
                        repeat with appName in appNames
                            set output to output & appName & linefeed
                        end repeat
                        return output
                    end tell
                    """,
                timeout: .seconds(10)
            )
        }
    }

    // MARK: - Private Implementation

    private func executeScript(source: String, timeout: Duration) async throws -> Value {
        log.info("Executing AppleScript (\(source.count) chars, timeout: \(timeout))")

        // Write script to temp file to handle multi-line scripts and special characters
        let tempDir = FileManager.default.temporaryDirectory
        let scriptFile = tempDir.appendingPathComponent(
            "applescript_\(UUID().uuidString).scpt"
        )

        defer {
            try? FileManager.default.removeItem(at: scriptFile)
        }

        try source.write(to: scriptFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = [scriptFile.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        defer {
            outputHandle.closeFile()
            errorHandle.closeFile()
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try process.run()
                    await withCheckedContinuation { continuation in
                        process.terminationHandler = { _ in
                            continuation.resume()
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: timeout)
                    process.terminate()
                    throw NSError(
                        domain: "AppleScriptError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "AppleScript timed out after \(Int(timeout.components.seconds)) seconds"
                        ]
                    )
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }

        let outputData = (try? outputHandle.readToEnd()) ?? Data()
        let errorData = (try? errorHandle.readToEnd()) ?? Data()

        let stdout = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            log.error("AppleScript failed: \(stderr, privacy: .public)")

            if stderr.contains("-1743") {
                throw NSError(
                    domain: "AppleScriptError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Not authorized to send Apple Events. Enable iMCP in System Settings > Privacy & Security > Automation."
                    ]
                )
            }

            throw NSError(
                domain: "AppleScriptError",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        stderr.isEmpty
                            ? "Script failed with exit code \(process.terminationStatus)"
                            : stderr
                ]
            )
        }

        log.info("AppleScript completed successfully")

        var result: [String: Value] = [
            "success": .bool(true),
            "output": .string(stdout),
        ]

        if !stderr.isEmpty {
            result["stderr"] = .string(stderr)
        }

        return Value.object(result)
    }
}

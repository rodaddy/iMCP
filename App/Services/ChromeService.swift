import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("chrome")

final class ChromeService: Service {
    static let shared = ChromeService()

    private let osascriptPath = "/usr/bin/osascript"

    var tools: [Tool] {
        Tool(
            name: "chrome_tabs_list",
            description:
                "List all Chrome windows and their tabs with URLs and titles",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Chrome Tabs",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let script = """
                tell application "Google Chrome"
                    set output to ""
                    set winIndex to 1
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            set tabTitle to title of t
                            set tabURL to URL of t
                            set isActive to (active tab index of w = tabIndex)
                            set output to output & winIndex & "\\t" & tabIndex & "\\t" & tabTitle & "\\t" & tabURL & "\\t" & isActive & linefeed
                            set tabIndex to tabIndex + 1
                        end repeat
                        set winIndex to winIndex + 1
                    end repeat
                    return output
                end tell
                """

            let result = try await self.runScript(script)
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }

            return Value.array(lines.map { line in
                let parts = line.components(separatedBy: "\t")
                return Value.object([
                    "window": .int(Int(parts.count > 0 ? parts[0] : "1") ?? 1),
                    "tab": .int(Int(parts.count > 1 ? parts[1] : "1") ?? 1),
                    "title": .string(parts.count > 2 ? parts[2] : ""),
                    "url": .string(parts.count > 3 ? parts[3] : ""),
                    "active": .bool(parts.count > 4 ? parts[4] == "true" : false),
                ])
            })
        }

        Tool(
            name: "chrome_navigate",
            description: "Navigate a Chrome tab to a specific URL",
            inputSchema: .object(
                properties: [
                    "url": .string(
                        description: "URL to navigate to"
                    ),
                    "window": .integer(
                        description: "Window index (1-based)",
                        default: .int(1)
                    ),
                    "tab": .integer(
                        description:
                            "Tab index (1-based). If omitted, navigates the active tab."
                    ),
                ],
                required: ["url"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Navigate Chrome Tab",
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case .string(let url) = arguments["url"], !url.isEmpty else {
                throw NSError(
                    domain: "ChromeError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "URL is required"]
                )
            }

            let windowIndex: Int
            if case .int(let w) = arguments["window"] {
                windowIndex = w
            } else {
                windowIndex = 1
            }

            let escapedURL = url.appleScriptEscaped
            let script: String

            if case .int(let tabIndex) = arguments["tab"] {
                script = """
                    tell application "Google Chrome"
                        set URL of tab \(tabIndex) of window \(windowIndex) to "\(escapedURL)"
                        return title of tab \(tabIndex) of window \(windowIndex)
                    end tell
                    """
            } else {
                script = """
                    tell application "Google Chrome"
                        set URL of active tab of window \(windowIndex) to "\(escapedURL)"
                        return title of active tab of window \(windowIndex)
                    end tell
                    """
            }

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "url": .string(url),
                "title": .string(result),
            ])
        }

        Tool(
            name: "chrome_tab_activate",
            description: "Switch to a specific tab in a Chrome window",
            inputSchema: .object(
                properties: [
                    "window": .integer(
                        description: "Window index (1-based)",
                        default: .int(1)
                    ),
                    "tab": .integer(
                        description: "Tab index (1-based) to activate"
                    ),
                ],
                required: ["tab"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Activate Chrome Tab",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .int(let tabIndex) = arguments["tab"] else {
                throw NSError(
                    domain: "ChromeError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Tab index is required"]
                )
            }

            let windowIndex: Int
            if case .int(let w) = arguments["window"] {
                windowIndex = w
            } else {
                windowIndex = 1
            }

            let script = """
                tell application "Google Chrome"
                    set active tab index of window \(windowIndex) to \(tabIndex)
                    return title of active tab of window \(windowIndex)
                end tell
                """

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "tab": .int(tabIndex),
                "title": .string(result),
            ])
        }

        Tool(
            name: "chrome_window_create",
            description: "Open a new Chrome window, optionally with a URL",
            inputSchema: .object(
                properties: [
                    "url": .string(
                        description: "URL to open in the new window"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "New Chrome Window",
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let script: String
            if case .string(let url) = arguments["url"], !url.isEmpty {
                let escapedURL = url.appleScriptEscaped
                script = """
                    tell application "Google Chrome"
                        set newWindow to make new window
                        set URL of active tab of newWindow to "\(escapedURL)"
                        return id of newWindow
                    end tell
                    """
            } else {
                script = """
                    tell application "Google Chrome"
                        set newWindow to make new window
                        return id of newWindow
                    end tell
                    """
            }

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "windowId": .string(result),
            ])
        }

        Tool(
            name: "chrome_execute_javascript",
            description:
                "Execute JavaScript in the active tab of a Chrome window",
            inputSchema: .object(
                properties: [
                    "code": .string(
                        description: "JavaScript code to execute"
                    ),
                    "window": .integer(
                        description: "Window index (1-based)",
                        default: .int(1)
                    ),
                    "tab": .integer(
                        description: "Tab index (1-based). Uses active tab if omitted."
                    ),
                ],
                required: ["code"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Execute JavaScript in Chrome",
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard case .string(let code) = arguments["code"], !code.isEmpty else {
                throw NSError(
                    domain: "ChromeError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "JavaScript code is required"]
                )
            }

            let windowIndex: Int
            if case .int(let w) = arguments["window"] {
                windowIndex = w
            } else {
                windowIndex = 1
            }

            let escapedCode = code.appleScriptEscaped
            let tabRef: String
            if case .int(let tabIndex) = arguments["tab"] {
                tabRef = "tab \(tabIndex) of window \(windowIndex)"
            } else {
                tabRef = "active tab of window \(windowIndex)"
            }

            let script = """
                tell application "Google Chrome"
                    set result to execute \(tabRef) javascript "\(escapedCode)"
                    return result
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(30))
            return Value.object([
                "success": .bool(true),
                "result": .string(result),
            ])
        }
    }

    // MARK: - Private Implementation

    private func runScript(_ source: String, timeout: Duration = .seconds(15)) async throws
        -> String
    {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptFile = tempDir.appendingPathComponent(
            "chrome_\(UUID().uuidString).scpt"
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
                        domain: "ChromeError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Chrome AppleScript timed out after \(Int(timeout.components.seconds)) seconds"
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

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            log.error("Chrome AppleScript failed: \(stderr, privacy: .public)")

            if stderr.contains("-1743") {
                throw NSError(
                    domain: "ChromeError",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Not authorized to send Apple Events to Google Chrome. Enable iMCP in System Settings > Privacy & Security > Automation."
                    ]
                )
            }

            throw NSError(
                domain: "ChromeError",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Chrome operation failed: \(stderr)"]
            )
        }

        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

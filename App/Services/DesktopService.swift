import AppKit
import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("desktop")

final class DesktopService: Service {
    static let shared = DesktopService()

    private let osascriptPath = "/usr/bin/osascript"

    var tools: [Tool] {
        uiScriptingTools

        Tool(
            name: "desktop_windows_list",
            description:
                "List all visible windows with their positions, sizes, and owning application",
            inputSchema: .object(
                properties: [
                    "app": .string(
                        description:
                            "Filter by application name (lists all apps if omitted)"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Windows",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let script: String
            if case .string(let app) = arguments["app"], !app.isEmpty {
                let escapedApp = app.appleScriptEscaped
                script = """
                    tell application "System Events"
                        set proc to first process whose name is "\(escapedApp)"
                        set output to ""
                        set winIndex to 1
                        repeat with w in windows of proc
                            set winName to name of w
                            set winPos to position of w
                            set winSize to size of w
                            set output to output & "\(escapedApp)" & "\\t" & winIndex & "\\t" & winName & "\\t" & (item 1 of winPos) & "," & (item 2 of winPos) & "\\t" & (item 1 of winSize) & "," & (item 2 of winSize) & linefeed
                            set winIndex to winIndex + 1
                        end repeat
                        return output
                    end tell
                    """
            } else {
                script = """
                    tell application "System Events"
                        set output to ""
                        repeat with proc in (every process whose visible is true)
                            set procName to name of proc
                            set winIndex to 1
                            repeat with w in windows of proc
                                set winName to name of w
                                set winPos to position of w
                                set winSize to size of w
                                set output to output & procName & "\\t" & winIndex & "\\t" & winName & "\\t" & (item 1 of winPos) & "," & (item 2 of winPos) & "\\t" & (item 1 of winSize) & "," & (item 2 of winSize) & linefeed
                                set winIndex to winIndex + 1
                            end repeat
                        end repeat
                        return output
                    end tell
                    """
            }

            let result = try await self.runScript(script)
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }

            return Value.array(lines.map { line in
                let parts = line.components(separatedBy: "\t")
                let pos = (parts.count > 3 ? parts[3] : "0,0").components(separatedBy: ",")
                let size = (parts.count > 4 ? parts[4] : "0,0").components(separatedBy: ",")
                return Value.object([
                    "app": .string(parts.count > 0 ? parts[0] : ""),
                    "index": .int(Int(parts.count > 1 ? parts[1] : "1") ?? 1),
                    "title": .string(parts.count > 2 ? parts[2] : ""),
                    "x": .int(Int(pos.first ?? "0") ?? 0),
                    "y": .int(Int(pos.count > 1 ? pos[1] : "0") ?? 0),
                    "width": .int(Int(size.first ?? "0") ?? 0),
                    "height": .int(Int(size.count > 1 ? size[1] : "0") ?? 0),
                ])
            })
        }

        Tool(
            name: "desktop_window_move",
            description:
                "Move and/or resize a window by application name and window index",
            inputSchema: .object(
                properties: [
                    "app": .string(
                        description: "Application name (e.g. 'Google Chrome', 'Finder')"
                    ),
                    "window": .integer(
                        description: "Window index (1-based, from desktop_windows_list)",
                        default: .int(1)
                    ),
                    "x": .integer(description: "New X position"),
                    "y": .integer(description: "New Y position"),
                    "width": .integer(description: "New width"),
                    "height": .integer(description: "New height"),
                ],
                required: ["app"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Move/Resize Window",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let app) = arguments["app"], !app.isEmpty else {
                throw NSError(
                    domain: "DesktopError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Application name is required"]
                )
            }

            let windowIndex: Int
            if case .int(let w) = arguments["window"] {
                windowIndex = w
            } else {
                windowIndex = 1
            }

            let escapedApp = app.appleScriptEscaped
            var commands: [String] = []

            if case .int(let x) = arguments["x"],
                case .int(let y) = arguments["y"]
            {
                commands.append("set position of w to {\(x), \(y)}")
            } else if case .int(let x) = arguments["x"] {
                commands.append(
                    "set position of w to {\(x), item 2 of (get position of w)}")
            } else if case .int(let y) = arguments["y"] {
                commands.append(
                    "set position of w to {item 1 of (get position of w), \(y)}")
            }

            if case .int(let width) = arguments["width"],
                case .int(let height) = arguments["height"]
            {
                commands.append("set size of w to {\(width), \(height)}")
            } else if case .int(let width) = arguments["width"] {
                commands.append(
                    "set size of w to {\(width), item 2 of (get size of w)}")
            } else if case .int(let height) = arguments["height"] {
                commands.append(
                    "set size of w to {item 1 of (get size of w), \(height)}")
            }

            guard !commands.isEmpty else {
                throw NSError(
                    domain: "DesktopError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "At least one of x, y, width, or height is required"
                    ]
                )
            }

            let commandBlock = commands.joined(separator: "\n                        ")
            let script = """
                tell application "System Events"
                    set proc to first process whose name is "\(escapedApp)"
                    set w to window \(windowIndex) of proc
                    \(commandBlock)
                    set newPos to position of w
                    set newSize to size of w
                    return (item 1 of newPos) & "," & (item 2 of newPos) & "\\t" & (item 1 of newSize) & "," & (item 2 of newSize)
                end tell
                """

            let result = try await self.runScript(script)
            let parts = result.components(separatedBy: "\t")
            let pos = (parts.first ?? "0,0").components(separatedBy: ",")
            let size = (parts.count > 1 ? parts[1] : "0,0").components(separatedBy: ",")

            return Value.object([
                "success": .bool(true),
                "app": .string(app),
                "x": .int(Int(pos.first ?? "0") ?? 0),
                "y": .int(Int(pos.count > 1 ? pos[1] : "0") ?? 0),
                "width": .int(Int(size.first ?? "0") ?? 0),
                "height": .int(Int(size.count > 1 ? size[1] : "0") ?? 0),
            ])
        }

        Tool(
            name: "desktop_window_focus",
            description: "Bring an application's window to the front",
            inputSchema: .object(
                properties: [
                    "app": .string(
                        description: "Application name to focus"
                    ),
                ],
                required: ["app"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Focus Window",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let app) = arguments["app"], !app.isEmpty else {
                throw NSError(
                    domain: "DesktopError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Application name is required"]
                )
            }

            let escapedApp = app.appleScriptEscaped
            let script = """
                tell application "\(escapedApp)"
                    activate
                end tell
                """

            let _ = try await self.runScript(script)

            return Value.object([
                "success": .bool(true),
                "app": .string(app),
            ])
        }

        Tool(
            name: "desktop_app_launch",
            description: "Launch an application by name or bundle ID",
            inputSchema: .object(
                properties: [
                    "app": .string(
                        description:
                            "Application name (e.g. 'Safari') or bundle ID (e.g. 'com.apple.Safari')"
                    ),
                ],
                required: ["app"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Launch App",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let app) = arguments["app"], !app.isEmpty else {
                throw NSError(
                    domain: "DesktopError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Application name is required"]
                )
            }

            // Try bundle ID first, then name
            if app.contains(".") {
                if let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: app
                ) {
                    try await NSWorkspace.shared.openApplication(
                        at: url,
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                    return Value.object([
                        "success": .bool(true),
                        "app": .string(app),
                    ])
                }
            }

            // Fall back to AppleScript
            let escapedApp = app.appleScriptEscaped
            let script = """
                tell application "\(escapedApp)"
                    activate
                end tell
                """
            let _ = try await self.runScript(script)

            return Value.object([
                "success": .bool(true),
                "app": .string(app),
            ])
        }

        Tool(
            name: "desktop_app_quit",
            description: "Quit an application by name",
            inputSchema: .object(
                properties: [
                    "app": .string(
                        description: "Application name to quit"
                    ),
                ],
                required: ["app"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Quit App",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let app) = arguments["app"], !app.isEmpty else {
                throw NSError(
                    domain: "DesktopError",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Application name is required"]
                )
            }

            let escapedApp = app.appleScriptEscaped
            let script = """
                tell application "\(escapedApp)"
                    quit
                end tell
                """
            let _ = try await self.runScript(script)

            return Value.object([
                "success": .bool(true),
                "app": .string(app),
            ])
        }

        Tool(
            name: "desktop_clipboard_read",
            description: "Read the current contents of the system clipboard",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Clipboard",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let pasteboard = NSPasteboard.general
            let content = pasteboard.string(forType: .string) ?? ""

            return Value.object([
                "content": .string(content),
                "types": .array(
                    pasteboard.types?.map { .string($0.rawValue) } ?? []
                ),
            ])
        }

        Tool(
            name: "desktop_clipboard_write",
            description: "Write text to the system clipboard",
            inputSchema: .object(
                properties: [
                    "text": .string(
                        description: "Text to write to the clipboard"
                    ),
                ],
                required: ["text"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Write Clipboard",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let text) = arguments["text"] else {
                throw NSError(
                    domain: "DesktopError",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Text is required"]
                )
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            return Value.object([
                "success": .bool(true),
                "length": .int(text.count),
            ])
        }
    }

    // MARK: - Private Implementation

    func runScript(_ source: String, timeout: Duration = .seconds(15)) async throws
        -> String
    {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptFile = tempDir.appendingPathComponent(
            "desktop_\(UUID().uuidString).scpt"
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
                        domain: "DesktopError",
                        code: 7,
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

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            log.error("Desktop AppleScript failed: \(stderr, privacy: .public)")

            if stderr.contains("-1743") {
                throw NSError(
                    domain: "DesktopError",
                    code: 8,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Not authorized to send Apple Events to System Events. Enable iMCP in System Settings > Privacy & Security > Automation."
                    ]
                )
            }

            throw NSError(
                domain: "DesktopError",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Desktop operation failed: \(stderr)"]
            )
        }

        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

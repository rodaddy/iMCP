import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("notes")

final class NotesService: Service {
    static let shared = NotesService()

    private let osascriptPath = "/usr/bin/osascript"

    var tools: [Tool] {
        Tool(
            name: "notes_list",
            description:
                "List notes from the Notes app with optional folder filtering",
            inputSchema: .object(
                properties: [
                    "folder": .string(
                        description: "Folder name to filter by (lists all if omitted)"
                    ),
                    "limit": .integer(
                        description: "Maximum notes to return",
                        default: .int(50)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Notes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit: Int
            if case .int(let l) = arguments["limit"] {
                limit = l
            } else {
                limit = 50
            }

            var script: String
            if case .string(let folder) = arguments["folder"], !folder.isEmpty {
                let escapedFolder = folder.appleScriptEscaped
                script = """
                    tell application "Notes"
                        set noteList to notes of folder "\(escapedFolder)"
                        set output to ""
                        set noteCount to 0
                        repeat with n in noteList
                            if noteCount >= \(limit) then exit repeat
                            set noteId to id of n
                            set noteName to name of n
                            try
                            set noteFolder to name of container of n
                        on error
                            set noteFolder to "Notes"
                        end try
                            set noteDate to modification date of n
                            set output to output & noteId & "\\t" & noteName & "\\t" & noteFolder & "\\t" & (noteDate as string) & linefeed
                            set noteCount to noteCount + 1
                        end repeat
                        return output
                    end tell
                    """
            } else {
                script = """
                    tell application "Notes"
                        set noteList to every note
                        set output to ""
                        set noteCount to 0
                        repeat with n in noteList
                            if noteCount >= \(limit) then exit repeat
                            set noteId to id of n
                            set noteName to name of n
                            try
                            set noteFolder to name of container of n
                        on error
                            set noteFolder to "Notes"
                        end try
                            set noteDate to modification date of n
                            set output to output & noteId & "\\t" & noteName & "\\t" & noteFolder & "\\t" & (noteDate as string) & linefeed
                            set noteCount to noteCount + 1
                        end repeat
                        return output
                    end tell
                    """
            }

            let result = try await self.runScript(script)
            return self.parseNotesList(result)
        }

        Tool(
            name: "notes_search",
            description: "Search notes by text content or title",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "Search text to find in note titles and content"
                    ),
                    "limit": .integer(
                        description: "Maximum results to return",
                        default: .int(20)
                    ),
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Notes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let query) = arguments["query"], !query.isEmpty else {
                throw NSError(
                    domain: "NotesError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Search query is required"]
                )
            }

            let limit: Int
            if case .int(let l) = arguments["limit"] {
                limit = l
            } else {
                limit = 20
            }

            let escapedQuery = query.appleScriptEscaped
            let script = """
                tell application "Notes"
                    set matchingNotes to every note whose name contains "\(escapedQuery)" or plaintext contains "\(escapedQuery)"
                    set output to ""
                    set noteCount to 0
                    repeat with n in matchingNotes
                        if noteCount >= \(limit) then exit repeat
                        set noteId to id of n
                        set noteName to name of n
                        try
                            set noteFolder to name of container of n
                        on error
                            set noteFolder to "Notes"
                        end try
                        set noteDate to modification date of n
                        set output to output & noteId & "\\t" & noteName & "\\t" & noteFolder & "\\t" & (noteDate as string) & linefeed
                        set noteCount to noteCount + 1
                    end repeat
                    return output
                end tell
                """

            let result = try await self.runScript(script)
            return self.parseNotesList(result)
        }

        Tool(
            name: "notes_read",
            description: "Read the full content of a note by its name or ID",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name/title of the note to read"
                    ),
                    "id": .string(
                        description: "Note ID (from notes_list or notes_search)"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Note",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let script: String
            if case .string(let noteId) = arguments["id"], !noteId.isEmpty {
                let escapedId = noteId.appleScriptEscaped
                script = """
                    tell application "Notes"
                        set n to first note whose id is "\(escapedId)"
                        set noteName to name of n
                        set noteBody to plaintext of n
                        try
                            set noteFolder to name of container of n
                        on error
                            set noteFolder to "Notes"
                        end try
                        set noteDate to modification date of n
                        set noteCreated to creation date of n
                        return noteName & "\\n---SEPARATOR---\\n" & noteBody & "\\n---SEPARATOR---\\n" & noteFolder & "\\n---SEPARATOR---\\n" & (noteDate as string) & "\\n---SEPARATOR---\\n" & (noteCreated as string)
                    end tell
                    """
            } else if case .string(let name) = arguments["name"], !name.isEmpty {
                let escapedName = name.appleScriptEscaped
                script = """
                    tell application "Notes"
                        set n to first note whose name is "\(escapedName)"
                        set noteName to name of n
                        set noteBody to plaintext of n
                        try
                            set noteFolder to name of container of n
                        on error
                            set noteFolder to "Notes"
                        end try
                        set noteDate to modification date of n
                        set noteCreated to creation date of n
                        return noteName & "\\n---SEPARATOR---\\n" & noteBody & "\\n---SEPARATOR---\\n" & noteFolder & "\\n---SEPARATOR---\\n" & (noteDate as string) & "\\n---SEPARATOR---\\n" & (noteCreated as string)
                    end tell
                    """
            } else {
                throw NSError(
                    domain: "NotesError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Either name or id is required"]
                )
            }

            let result = try await self.runScript(script)
            let parts = result.components(separatedBy: "\n---SEPARATOR---\n")

            guard parts.count >= 5 else {
                return Value.object([
                    "content": .string(result),
                ])
            }

            return Value.object([
                "name": .string(parts[0]),
                "body": .string(parts[1]),
                "folder": .string(parts[2]),
                "modified": .string(parts[3]),
                "created": .string(parts[4]),
            ])
        }

        Tool(
            name: "notes_create",
            description: "Create a new note in the Notes app",
            inputSchema: .object(
                properties: [
                    "title": .string(
                        description: "Title for the new note"
                    ),
                    "body": .string(
                        description: "Content body of the note (plain text or HTML)"
                    ),
                    "folder": .string(
                        description: "Folder to create the note in (uses default if omitted)"
                    ),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Note",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let title) = arguments["title"], !title.isEmpty else {
                throw NSError(
                    domain: "NotesError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Note title is required"]
                )
            }

            let escapedTitle = title.appleScriptEscaped
            let body: String
            if case .string(let b) = arguments["body"] {
                body = b.appleScriptEscaped
            } else {
                body = ""
            }

            // Build HTML content with title as h1
            let htmlContent = "<h1>\(escapedTitle)</h1><br>\(body)"

            let script: String
            if case .string(let folder) = arguments["folder"], !folder.isEmpty {
                let escapedFolder = folder.appleScriptEscaped
                script = """
                    tell application "Notes"
                        set targetFolder to folder "\(escapedFolder)"
                        set newNote to make new note at targetFolder with properties {body:"\(htmlContent)"}
                        return name of newNote & "\\t" & id of newNote
                    end tell
                    """
            } else {
                script = """
                    tell application "Notes"
                        set newNote to make new note with properties {body:"\(htmlContent)"}
                        return name of newNote & "\\t" & id of newNote
                    end tell
                    """
            }

            let result = try await self.runScript(script)
            let parts = result.components(separatedBy: "\t")

            return Value.object([
                "success": .bool(true),
                "name": .string(parts.first ?? title),
                "id": .string(parts.count > 1 ? parts[1] : ""),
            ])
        }

        Tool(
            name: "notes_update",
            description: "Update an existing note's content",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name/title of the note to update"
                    ),
                    "id": .string(
                        description: "Note ID (from notes_list)"
                    ),
                    "body": .string(
                        description: "New body content (replaces existing)"
                    ),
                    "append": .string(
                        description: "Text to append to the existing note body"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Note",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let noteRef: String
            if case .string(let noteId) = arguments["id"], !noteId.isEmpty {
                noteRef = "first note whose id is \"\(noteId.appleScriptEscaped)\""
            } else if case .string(let name) = arguments["name"], !name.isEmpty {
                noteRef = "first note whose name is \"\(name.appleScriptEscaped)\""
            } else {
                throw NSError(
                    domain: "NotesError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Either name or id is required"]
                )
            }

            let script: String
            if case .string(let newBody) = arguments["body"] {
                let escapedBody = newBody.appleScriptEscaped
                script = """
                    tell application "Notes"
                        set n to \(noteRef)
                        set body of n to "\(escapedBody)"
                        return name of n
                    end tell
                    """
            } else if case .string(let appendText) = arguments["append"] {
                let escapedAppend = appendText.appleScriptEscaped
                script = """
                    tell application "Notes"
                        set n to \(noteRef)
                        set body of n to (body of n) & "<br>\(escapedAppend)"
                        return name of n
                    end tell
                    """
            } else {
                throw NSError(
                    domain: "NotesError",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Either body or append is required"
                    ]
                )
            }

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "name": .string(result),
            ])
        }

        Tool(
            name: "notes_delete",
            description: "Delete a note by name or ID",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name/title of the note to delete"
                    ),
                    "id": .string(
                        description: "Note ID (from notes_list)"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Note",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let noteRef: String
            if case .string(let noteId) = arguments["id"], !noteId.isEmpty {
                noteRef = "first note whose id is \"\(noteId.appleScriptEscaped)\""
            } else if case .string(let name) = arguments["name"], !name.isEmpty {
                noteRef = "first note whose name is \"\(name.appleScriptEscaped)\""
            } else {
                throw NSError(
                    domain: "NotesError",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Either name or id is required"]
                )
            }

            let script = """
                tell application "Notes"
                    set n to \(noteRef)
                    set noteName to name of n
                    delete n
                    return noteName
                end tell
                """

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "deleted": .string(result),
            ])
        }

        Tool(
            name: "notes_folders_list",
            description: "List all folders in the Notes app",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Note Folders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let script = """
                tell application "Notes"
                    set folderList to every folder
                    set output to ""
                    repeat with f in folderList
                        set folderName to name of f
                        set noteCount to count of notes of f
                        set output to output & folderName & "\\t" & noteCount & linefeed
                    end repeat
                    return output
                end tell
                """

            let result = try await self.runScript(script)
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }

            return Value.array(lines.map { line in
                let parts = line.components(separatedBy: "\t")
                return Value.object([
                    "name": .string(parts.first ?? ""),
                    "noteCount": .int(Int(parts.count > 1 ? parts[1] : "0") ?? 0),
                ])
            })
        }

        Tool(
            name: "notes_folders_create",
            description: "Create a new folder in the Notes app",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name for the new folder"
                    ),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Note Folder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let name) = arguments["name"], !name.isEmpty else {
                throw NSError(
                    domain: "NotesError",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Folder name is required"]
                )
            }

            let escapedName = name.appleScriptEscaped
            let script = """
                tell application "Notes"
                    make new folder with properties {name:"\(escapedName)"}
                    return "\(escapedName)"
                end tell
                """

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "name": .string(result),
            ])
        }
    }

    // MARK: - Private Implementation

    private func runScript(_ source: String, timeout: Duration = .seconds(30)) async throws
        -> String
    {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptFile = tempDir.appendingPathComponent(
            "notes_\(UUID().uuidString).scpt"
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
                        domain: "NotesError",
                        code: 8,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Notes AppleScript timed out after \(Int(timeout.components.seconds)) seconds"
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
            log.error("Notes AppleScript failed: \(stderr, privacy: .public)")

            if stderr.contains("-1743") {
                throw NSError(
                    domain: "NotesError",
                    code: 9,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Not authorized to send Apple Events to Notes. Enable iMCP in System Settings > Privacy & Security > Automation."
                    ]
                )
            }

            throw NSError(
                domain: "NotesError",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Notes operation failed: \(stderr)"]
            )
        }

        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func parseNotesList(_ output: String) -> Value {
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        return Value.array(lines.map { line in
            let parts = line.components(separatedBy: "\t")
            var note: [String: Value] = [:]
            if parts.count > 0 { note["id"] = .string(parts[0]) }
            if parts.count > 1 { note["name"] = .string(parts[1]) }
            if parts.count > 2 { note["folder"] = .string(parts[2]) }
            if parts.count > 3 { note["modified"] = .string(parts[3]) }
            return Value.object(note)
        })
    }
}

import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("notes")

extension NotesService {
    @ToolBuilder var additionalTools: [Tool] {
        Tool(
            name: "notes_attach",
            description:
                "Attach a file to an existing note. The file is embedded as a true attachment that syncs via iCloud.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Note ID (from notes_list or notes_search)"
                    ),
                    "name": .string(
                        description: "Note name/title (alternative to id)"
                    ),
                    "filePath": .string(
                        description:
                            "Absolute path to the file to attach (e.g. /Users/rico/Downloads/report.pdf)"
                    ),
                ],
                required: ["filePath"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Attach File to Note",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let filePath) = arguments["filePath"], !filePath.isEmpty else {
                throw NSError(
                    domain: "NotesError", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "File path is required"])
            }

            // Verify file exists
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw NSError(
                    domain: "NotesError", code: 12,
                    userInfo: [
                        NSLocalizedDescriptionKey: "File not found at path: \(filePath)"
                    ])
            }

            let noteRef: String
            if case .string(let noteId) = arguments["id"], !noteId.isEmpty {
                noteRef = "first note whose id is \"\(noteId.appleScriptEscaped)\""
            } else if case .string(let name) = arguments["name"], !name.isEmpty {
                noteRef = "first note whose name is \"\(name.appleScriptEscaped)\""
            } else {
                throw NSError(
                    domain: "NotesError", code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Either name or id is required"])
            }

            let escapedPath = filePath.appleScriptEscaped
            let script = """
                tell application "Notes"
                    set n to \(noteRef)
                    make new attachment at n with data (POSIX file "\(escapedPath)")
                    return name of n
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(30))
            return Value.object([
                "success": .bool(true),
                "note": .string(result),
                "attached": .string(
                    (filePath as NSString).lastPathComponent),
            ])
        }

        Tool(
            name: "notes_move",
            description:
                "Move a note to a different folder. Useful for moving notes to shared/collaborative folders for cross-device sync.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Note ID (from notes_list or notes_search)"
                    ),
                    "name": .string(
                        description: "Note name/title (alternative to id)"
                    ),
                    "folder": .string(
                        description:
                            "Destination folder name (must already exist)"
                    ),
                ],
                required: ["folder"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Move Note to Folder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let folder) = arguments["folder"], !folder.isEmpty else {
                throw NSError(
                    domain: "NotesError", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Destination folder is required"])
            }

            let noteRef: String
            if case .string(let noteId) = arguments["id"], !noteId.isEmpty {
                noteRef = "first note whose id is \"\(noteId.appleScriptEscaped)\""
            } else if case .string(let name) = arguments["name"], !name.isEmpty {
                noteRef = "first note whose name is \"\(name.appleScriptEscaped)\""
            } else {
                throw NSError(
                    domain: "NotesError", code: 15,
                    userInfo: [NSLocalizedDescriptionKey: "Either name or id is required"])
            }

            let escapedFolder = folder.appleScriptEscaped
            let script = """
                tell application "Notes"
                    set n to \(noteRef)
                    set noteName to name of n
                    set targetFolder to folder "\(escapedFolder)"
                    move n to targetFolder
                    return noteName
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(30))
            return Value.object([
                "success": .bool(true),
                "note": .string(result),
                "movedTo": .string(folder),
            ])
        }
    }
}

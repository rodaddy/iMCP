import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("mail")

/// Robust delimiters for AppleScript output parsing (avoids tab/newline corruption in subjects)
private let fieldSep = "---FIELD---"
private let recordSep = "---RECORD---"

final class MailService: Service {
    static let shared = MailService()

    private let osascriptPath = "/usr/bin/osascript"

    var tools: [Tool] {
        readTools
        mutationTools
    }

    // MARK: - Read Tools

    @ToolBuilder var readTools: [Tool] {
        Tool(
            name: "mail_mailboxes_list",
            description: "List mailboxes/folders in Mail with optional account filtering",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Filter by account name (lists all if omitted)"
                    ),
                    "counts": .boolean(
                        description:
                            "Include message counts (slower for large IMAP mailboxes)"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Mailboxes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let includeCounts: Bool
            if case .bool(let c) = arguments["counts"] {
                includeCounts = c
            } else {
                includeCounts = false
            }

            let outputLine: String
            if includeCounts {
                outputLine = """
                                    set msgCount to count of messages of mb
                                    set output to output & acctName & "\(fieldSep)" & mbName & "\(fieldSep)" & msgCount & "\(recordSep)"
                    """
            } else {
                outputLine = """
                                    set output to output & acctName & "\(fieldSep)" & mbName & "\(recordSep)"
                    """
            }

            let script: String
            if case .string(let account) = arguments["account"], !account.isEmpty {
                let escaped = account.appleScriptEscaped
                script = """
                    tell application "Mail"
                        set acct to first account whose name is "\(escaped)"
                        set acctName to name of acct
                        set output to ""
                        repeat with mb in every mailbox of acct
                            set mbName to name of mb
                    \(outputLine)
                        end repeat
                        return output
                    end tell
                    """
            } else {
                script = """
                    tell application "Mail"
                        set output to ""
                        repeat with acct in every account
                            set acctName to name of acct
                            repeat with mb in every mailbox of acct
                                set mbName to name of mb
                    \(outputLine)
                            end repeat
                        end repeat
                        return output
                    end tell
                    """
            }

            let result = try await self.runScript(script)
            let records = result.components(separatedBy: recordSep).filter { !$0.isEmpty }
            return Value.array(records.map { record in
                let fields = record.components(separatedBy: fieldSep)
                var mailbox: [String: Value] = [
                    "account": .string(fields.count > 0 ? fields[0] : ""),
                    "mailbox": .string(fields.count > 1 ? fields[1] : ""),
                ]
                if includeCounts, fields.count > 2 {
                    mailbox["messageCount"] = .int(Int(fields[2]) ?? 0)
                }
                return Value.object(mailbox)
            })
        }

        Tool(
            name: "mail_search",
            description:
                "Search for messages in Mail by subject, sender, or content with optional account/mailbox scoping",
            inputSchema: .object(
                properties: [
                    "subject": .string(description: "Search in message subjects"),
                    "sender": .string(description: "Search by sender name or email"),
                    "content": .string(
                        description:
                            "Search in message body content (slow on large mailboxes)"
                    ),
                    "mailbox": .string(
                        description:
                            "Mailbox to search in (e.g. 'INBOX'). Pair with account to avoid ambiguity"
                    ),
                    "account": .string(description: "Account to scope search to"),
                    "limit": .integer(
                        description: "Maximum results to return",
                        default: .int(20)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Mail",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit: Int
            if case .int(let l) = arguments["limit"] { limit = l } else { limit = 20 }

            var conditions: [String] = []
            if case .string(let s) = arguments["subject"], !s.isEmpty {
                conditions.append("subject contains \"\(s.appleScriptEscaped)\"")
            }
            if case .string(let s) = arguments["sender"], !s.isEmpty {
                conditions.append("sender contains \"\(s.appleScriptEscaped)\"")
            }
            if case .string(let c) = arguments["content"], !c.isEmpty {
                conditions.append("content contains \"\(c.appleScriptEscaped)\"")
            }

            guard !conditions.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "At least one search criterion (subject, sender, or content) is required"
                    ])
            }

            let whereClause = conditions.joined(separator: " and ")

            let accountName: String?
            if case .string(let a) = arguments["account"], !a.isEmpty {
                accountName = a
            } else {
                accountName = nil
            }
            let mailboxName: String?
            if case .string(let m) = arguments["mailbox"], !m.isEmpty {
                mailboxName = m
            } else {
                mailboxName = nil
            }

            let msgOutput = """
                                set msgId to id of m
                                set msgSubject to subject of m
                                set msgSender to sender of m
                                set msgDate to date received of m
                                set msgRead to read status of m
                                set output to output & msgId & "\(fieldSep)" & msgSubject & "\(fieldSep)" & msgSender & "\(fieldSep)" & (msgDate as string) & "\(fieldSep)" & msgRead & "\(recordSep)"
                                set msgCount to msgCount + 1
                """

            let script: String
            if let acct = accountName {
                let ea = acct.appleScriptEscaped
                if let mb = mailboxName {
                    let em = mb.appleScriptEscaped
                    script = """
                        tell application "Mail"
                            set acct to first account whose name is "\(ea)"
                            set msgs to (every message of mailbox "\(em)" of acct whose \(whereClause))
                            set output to ""
                            set msgCount to 0
                            repeat with m in msgs
                                if msgCount >= \(limit) then exit repeat
                        \(msgOutput)
                            end repeat
                            return output
                        end tell
                        """
                } else {
                    script = """
                        tell application "Mail"
                            set acct to first account whose name is "\(ea)"
                            set output to ""
                            set msgCount to 0
                            repeat with mb in every mailbox of acct
                                if msgCount >= \(limit) then exit repeat
                                set matchMsgs to (every message of mb whose \(whereClause))
                                repeat with m in matchMsgs
                                    if msgCount >= \(limit) then exit repeat
                        \(msgOutput)
                                end repeat
                            end repeat
                            return output
                        end tell
                        """
                }
            } else if let mb = mailboxName {
                let em = mb.appleScriptEscaped
                script = """
                    tell application "Mail"
                        set output to ""
                        set msgCount to 0
                        repeat with acct in every account
                            if msgCount >= \(limit) then exit repeat
                            try
                                set mb to mailbox "\(em)" of acct
                                set matchMsgs to (every message of mb whose \(whereClause))
                                repeat with m in matchMsgs
                                    if msgCount >= \(limit) then exit repeat
                    \(msgOutput)
                                end repeat
                            end try
                        end repeat
                        return output
                    end tell
                    """
            } else {
                script = """
                    tell application "Mail"
                        set output to ""
                        set msgCount to 0
                        repeat with acct in every account
                            if msgCount >= \(limit) then exit repeat
                            repeat with mb in every mailbox of acct
                                if msgCount >= \(limit) then exit repeat
                                try
                                    set matchMsgs to (every message of mb whose \(whereClause))
                                    repeat with m in matchMsgs
                                        if msgCount >= \(limit) then exit repeat
                    \(msgOutput)
                                    end repeat
                                end try
                            end repeat
                        end repeat
                        return output
                    end tell
                    """
            }

            let result = try await self.runScript(script, timeout: .seconds(60))
            let records = result.components(separatedBy: recordSep).filter { !$0.isEmpty }
            return Value.array(records.map { record in
                let fields = record.components(separatedBy: fieldSep)
                return Value.object([
                    "id": .string(fields.count > 0 ? fields[0] : ""),
                    "subject": .string(fields.count > 1 ? fields[1] : ""),
                    "sender": .string(fields.count > 2 ? fields[2] : ""),
                    "date": .string(fields.count > 3 ? fields[3] : ""),
                    "isRead": .bool(fields.count > 4 ? fields[4] == "true" : false),
                ])
            })
        }

        Tool(
            name: "mail_read",
            description:
                "Read the full content of an email including all recipients and attachment info",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message ID (from mail_search results)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox the message is in (speeds up lookup)"
                    ),
                    "account": .string(
                        description: "Account the message is in"
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Email",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let messageId) = arguments["id"], !messageId.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"])
            }

            let escapedId = messageId.appleScriptEscaped
            let sep = "\\n---SEPARATOR---\\n"
            let scope = self.buildScope(arguments)

            // When no scope given, search across all accounts/mailboxes for the message by ID
            let findMsg: String
            if scope.isEmpty {
                findMsg = """
                    set m to missing value
                    repeat with acct in every account
                        repeat with mb in every mailbox of acct
                            try
                                set m to first message of mb whose id is \(escapedId)
                                exit repeat
                            end try
                        end repeat
                        if m is not missing value then exit repeat
                    end repeat
                    if m is missing value then error "Message not found with id \(escapedId)" number -1728
                """
            } else {
                findMsg = "set m to first message\(scope) whose id is \(escapedId)"
            }

            let script = """
                tell application "Mail"
                    \(findMsg)
                    set msgSubject to subject of m
                    set msgSender to sender of m
                    set msgDate to date received of m
                    set msgContent to content of m
                    set toList to ""
                    repeat with r in to recipients of m
                        set toList to toList & address of r & ", "
                    end repeat
                    set ccList to ""
                    repeat with r in cc recipients of m
                        set ccList to ccList & address of r & ", "
                    end repeat
                    set bccList to ""
                    try
                        repeat with r in bcc recipients of m
                            set bccList to bccList & address of r & ", "
                        end repeat
                    end try
                    set attInfo to ""
                    set attCount to count of mail attachments of m
                    if attCount > 0 then
                        repeat with a in mail attachments of m
                            set attName to name of a
                            set attType to ""
                            try
                                set attType to MIME type of a
                            end try
                            set attInfo to attInfo & attName & "\(fieldSep)" & attType & ","
                        end repeat
                    end if
                    set msgFlagged to flagged status of m
                    set msgRead to read status of m
                    return msgSubject & "\(sep)" & msgSender & "\(sep)" & (msgDate as string) & "\(sep)" & toList & "\(sep)" & ccList & "\(sep)" & bccList & "\(sep)" & msgContent & "\(sep)" & attCount & "\(sep)" & attInfo & "\(sep)" & msgFlagged & "\(sep)" & msgRead
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(30))
            let parts = result.components(separatedBy: "\n---SEPARATOR---\n")

            guard parts.count >= 11 else {
                return Value.object(["content": .string(result)])
            }

            var response: [String: Value] = [
                "subject": .string(parts[0]),
                "sender": .string(parts[1]),
                "date": .string(parts[2]),
                "to": .string(
                    parts[3].trimmingCharacters(in: CharacterSet(charactersIn: ", "))),
                "cc": .string(
                    parts[4].trimmingCharacters(in: CharacterSet(charactersIn: ", "))),
                "bcc": .string(
                    parts[5].trimmingCharacters(in: CharacterSet(charactersIn: ", "))),
                "body": .string(parts[6]),
                "flagged": .bool(parts[9] == "true"),
                "isRead": .bool(parts[10] == "true"),
            ]

            let attCount = Int(parts[7]) ?? 0
            response["attachmentCount"] = .int(attCount)
            if attCount > 0 {
                let attEntries = parts[8].components(separatedBy: ",").filter { !$0.isEmpty }
                response["attachments"] = .array(attEntries.map { entry in
                    let attParts = entry.components(separatedBy: fieldSep)
                    return Value.object([
                        "name": .string(attParts.count > 0 ? attParts[0] : ""),
                        "mimeType": .string(attParts.count > 1 ? attParts[1] : ""),
                    ])
                })
            }

            return Value.object(response)
        }
    }

    // MARK: - Script Execution (internal for extension access)

    func runScript(_ source: String, timeout: Duration = .seconds(30)) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptFile = tempDir.appendingPathComponent(
            "mail_\(UUID().uuidString).scpt"
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
                        domain: "MailError", code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Mail AppleScript timed out after \(Int(timeout.components.seconds)) seconds"
                        ])
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
            log.error("Mail AppleScript failed: \(stderr, privacy: .public)")

            if stderr.contains("-1743") {
                throw NSError(
                    domain: "MailError", code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Not authorized to send Apple Events to Mail. Enable iMCP in System Settings > Privacy & Security > Automation."
                    ])
            }

            throw NSError(
                domain: "MailError", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Mail operation failed: \(stderr)"])
        }

        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Helpers

    /// Generates AppleScript to find a message by ID, optionally scoped by mailbox/account.
    /// Returns a block that sets `m` to the found message.
    func findMessageScript(id: String, arguments: [String: Value]) -> String {
        let escapedId = id.appleScriptEscaped
        let scope = buildScope(arguments)
        if scope.isEmpty {
            return """
                set m to missing value
                    repeat with acct in every account
                        repeat with mb in every mailbox of acct
                            try
                                set m to first message of mb whose id is \(escapedId)
                                exit repeat
                            end try
                        end repeat
                        if m is not missing value then exit repeat
                    end repeat
                    if m is missing value then error "Message not found" number -1728
            """
        } else {
            return "set m to first message\(scope) whose id is \(escapedId)"
        }
    }

    func buildScope(_ arguments: [String: Value]) -> String {
        if case .string(let account) = arguments["account"], !account.isEmpty {
            if case .string(let mailbox) = arguments["mailbox"], !mailbox.isEmpty {
                return " of mailbox \"\(mailbox.appleScriptEscaped)\" of account \"\(account.appleScriptEscaped)\""
            }
        } else if case .string(let mailbox) = arguments["mailbox"], !mailbox.isEmpty {
            return " of mailbox \"\(mailbox.appleScriptEscaped)\""
        }
        return ""
    }
}

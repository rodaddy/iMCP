import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("mail")

final class MailService: Service {
    static let shared = MailService()

    private let osascriptPath = "/usr/bin/osascript"

    var tools: [Tool] {
        Tool(
            name: "mail_mailboxes_list",
            description: "List all mailboxes/folders in the Mail app",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Filter by account name (lists all accounts if omitted)"
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
            let script: String
            if case .string(let account) = arguments["account"], !account.isEmpty {
                let escapedAccount = account.appleScriptEscaped
                script = """
                    tell application "Mail"
                        set acct to first account whose name is "\(escapedAccount)"
                        set boxList to every mailbox of acct
                        set output to ""
                        repeat with mb in boxList
                            set mbName to name of mb
                            set msgCount to count of messages of mb
                            set output to output & "\(escapedAccount)" & "\\t" & mbName & "\\t" & msgCount & linefeed
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
                                set msgCount to count of messages of mb
                                set output to output & acctName & "\\t" & mbName & "\\t" & msgCount & linefeed
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
                return Value.object([
                    "account": .string(parts.count > 0 ? parts[0] : ""),
                    "mailbox": .string(parts.count > 1 ? parts[1] : ""),
                    "messageCount": .int(Int(parts.count > 2 ? parts[2] : "0") ?? 0),
                ])
            })
        }

        Tool(
            name: "mail_search",
            description:
                "Search for messages in Mail by subject, sender, or content",
            inputSchema: .object(
                properties: [
                    "subject": .string(
                        description: "Search in message subjects"
                    ),
                    "sender": .string(
                        description: "Search by sender name or email"
                    ),
                    "content": .string(
                        description: "Search in message body content"
                    ),
                    "mailbox": .string(
                        description: "Mailbox to search in (e.g. 'INBOX'). Searches all if omitted."
                    ),
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
            if case .int(let l) = arguments["limit"] {
                limit = l
            } else {
                limit = 20
            }

            // Build filter conditions
            var conditions: [String] = []
            if case .string(let subject) = arguments["subject"], !subject.isEmpty {
                conditions.append("subject contains \"\(subject.appleScriptEscaped)\"")
            }
            if case .string(let sender) = arguments["sender"], !sender.isEmpty {
                conditions.append("sender contains \"\(sender.appleScriptEscaped)\"")
            }
            if case .string(let content) = arguments["content"], !content.isEmpty {
                conditions.append("content contains \"\(content.appleScriptEscaped)\"")
            }

            guard !conditions.isEmpty else {
                throw NSError(
                    domain: "MailError",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "At least one search criterion (subject, sender, or content) is required"
                    ]
                )
            }

            let whereClause = conditions.joined(separator: " and ")

            let mailboxFilter: String
            if case .string(let mailbox) = arguments["mailbox"], !mailbox.isEmpty {
                mailboxFilter = " of mailbox \"\(mailbox.appleScriptEscaped)\""
            } else {
                mailboxFilter = ""
            }

            let script = """
                tell application "Mail"
                    set msgs to (every message\(mailboxFilter) whose \(whereClause))
                    set output to ""
                    set msgCount to 0
                    repeat with m in msgs
                        if msgCount >= \(limit) then exit repeat
                        set msgId to id of m
                        set msgSubject to subject of m
                        set msgSender to sender of m
                        set msgDate to date received of m
                        set msgRead to read status of m
                        set output to output & msgId & "\\t" & msgSubject & "\\t" & msgSender & "\\t" & (msgDate as string) & "\\t" & msgRead & linefeed
                        set msgCount to msgCount + 1
                    end repeat
                    return output
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(60))
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }

            return Value.array(lines.map { line in
                let parts = line.components(separatedBy: "\t")
                return Value.object([
                    "id": .string(parts.count > 0 ? parts[0] : ""),
                    "subject": .string(parts.count > 1 ? parts[1] : ""),
                    "sender": .string(parts.count > 2 ? parts[2] : ""),
                    "date": .string(parts.count > 3 ? parts[3] : ""),
                    "isRead": .bool(parts.count > 4 ? parts[4] == "true" : false),
                ])
            })
        }

        Tool(
            name: "mail_read",
            description:
                "Read the full content of an email message by its ID",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message ID (from mail_search results)"
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
                    domain: "MailError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"]
                )
            }

            let escapedId = messageId.appleScriptEscaped
            let script = """
                tell application "Mail"
                    set m to first message whose id is \(escapedId)
                    set msgSubject to subject of m
                    set msgSender to sender of m
                    set msgDate to date received of m
                    set msgContent to content of m
                    set recipientList to ""
                    repeat with r in to recipients of m
                        set recipientList to recipientList & address of r & ", "
                    end repeat
                    return msgSubject & "\\n---SEPARATOR---\\n" & msgSender & "\\n---SEPARATOR---\\n" & (msgDate as string) & "\\n---SEPARATOR---\\n" & recipientList & "\\n---SEPARATOR---\\n" & msgContent
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(30))
            let parts = result.components(separatedBy: "\n---SEPARATOR---\n")

            guard parts.count >= 5 else {
                return Value.object([
                    "content": .string(result),
                ])
            }

            return Value.object([
                "subject": .string(parts[0]),
                "sender": .string(parts[1]),
                "date": .string(parts[2]),
                "to": .string(parts[3].trimmingCharacters(in: CharacterSet(charactersIn: ", "))),
                "body": .string(parts[4]),
            ])
        }

        Tool(
            name: "mail_send",
            description: "Compose and send an email via the Mail app",
            inputSchema: .object(
                properties: [
                    "to": .string(
                        description: "Recipient email address"
                    ),
                    "subject": .string(
                        description: "Email subject line"
                    ),
                    "body": .string(
                        description: "Email body content"
                    ),
                    "cc": .string(
                        description: "CC recipient email address"
                    ),
                ],
                required: ["to", "subject", "body"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Email",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let to) = arguments["to"], !to.isEmpty else {
                throw NSError(
                    domain: "MailError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Recipient email is required"]
                )
            }

            guard case .string(let subject) = arguments["subject"] else {
                throw NSError(
                    domain: "MailError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Subject is required"]
                )
            }

            guard case .string(let body) = arguments["body"] else {
                throw NSError(
                    domain: "MailError",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Body is required"]
                )
            }

            let escapedTo = to.appleScriptEscaped
            let escapedSubject = subject.appleScriptEscaped
            let escapedBody = body.appleScriptEscaped

            var ccBlock = ""
            if case .string(let cc) = arguments["cc"], !cc.isEmpty {
                let escapedCc = cc.appleScriptEscaped
                ccBlock = """
                    make new cc recipient at end of cc recipients with properties {address:"\(escapedCc)"}
                    """
            }

            let script = """
                tell application "Mail"
                    set newMessage to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:false}
                    tell newMessage
                        make new to recipient at end of to recipients with properties {address:"\(escapedTo)"}
                        \(ccBlock)
                    end tell
                    send newMessage
                end tell
                return "sent"
                """

            let _ = try await self.runScript(script, timeout: .seconds(30))

            log.info("Email sent to \(to, privacy: .private)")

            return Value.object([
                "success": .bool(true),
                "to": .string(to),
                "subject": .string(subject),
            ])
        }
    }

    // MARK: - Private Implementation

    private func runScript(_ source: String, timeout: Duration = .seconds(30)) async throws
        -> String
    {
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
                        domain: "MailError",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Mail AppleScript timed out after \(Int(timeout.components.seconds)) seconds"
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
            log.error("Mail AppleScript failed: \(stderr, privacy: .public)")

            if stderr.contains("-1743") {
                throw NSError(
                    domain: "MailError",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Not authorized to send Apple Events to Mail. Enable iMCP in System Settings > Privacy & Security > Automation."
                    ]
                )
            }

            throw NSError(
                domain: "MailError",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Mail operation failed: \(stderr)"]
            )
        }

        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

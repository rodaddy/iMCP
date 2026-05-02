import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("mail")

extension MailService {
    @ToolBuilder var mutationTools: [Tool] {
        Tool(
            name: "mail_send",
            description:
                "Compose and send an email with support for multiple recipients, attachments, and HTML",
            inputSchema: .object(
                properties: [
                    "to": .string(
                        description:
                            "Recipient email address(es), comma-separated for multiple"
                    ),
                    "subject": .string(description: "Email subject line"),
                    "body": .string(description: "Email body content"),
                    "cc": .string(
                        description: "CC recipient(s), comma-separated"
                    ),
                    "bcc": .string(
                        description: "BCC recipient(s), comma-separated"
                    ),
                    "from": .string(
                        description:
                            "Sender email address (chooses which account to send from)"
                    ),
                    "attachments": .array(
                        description: "Absolute file paths to attach",
                        items: .string(description: "File path")
                    ),
                    "isHTML": .boolean(
                        description: "Treat body as HTML content"
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
                    domain: "MailError", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Recipient email is required"])
            }
            guard case .string(let subject) = arguments["subject"] else {
                throw NSError(
                    domain: "MailError", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Subject is required"])
            }
            guard case .string(let body) = arguments["body"] else {
                throw NSError(
                    domain: "MailError", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Body is required"])
            }

            let isHTML: Bool
            if case .bool(let h) = arguments["isHTML"] { isHTML = h } else { isHTML = false }

            let escapedSubject = subject.appleScriptEscaped
            let escapedBody = body.appleScriptEscaped

            // Build recipient lines
            let toAddresses = to.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var recipientLines = toAddresses.map { addr in
                "make new to recipient at end of to recipients with properties {address:\"\(addr.appleScriptEscaped)\"}"
            }.joined(separator: "\n            ")

            if case .string(let cc) = arguments["cc"], !cc.isEmpty {
                let ccLines = cc.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { addr in
                        "make new cc recipient at end of cc recipients with properties {address:\"\(addr.appleScriptEscaped)\"}"
                    }.joined(separator: "\n            ")
                recipientLines += "\n            " + ccLines
            }

            if case .string(let bcc) = arguments["bcc"], !bcc.isEmpty {
                let bccLines = bcc.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { addr in
                        "make new bcc recipient at end of bcc recipients with properties {address:\"\(addr.appleScriptEscaped)\"}"
                    }.joined(separator: "\n            ")
                recipientLines += "\n            " + bccLines
            }

            // Message creation properties
            let msgProps: String
            if isHTML {
                msgProps = "{subject:\"\(escapedSubject)\", visible:false}"
            } else {
                msgProps =
                    "{subject:\"\(escapedSubject)\", content:\"\(escapedBody)\", visible:false}"
            }

            // Optional sender/from
            var senderLine = ""
            if case .string(let from) = arguments["from"], !from.isEmpty {
                senderLine = "\n        set sender of newMsg to \"\(from.appleScriptEscaped)\""
            }

            // Optional HTML content
            var htmlLine = ""
            if isHTML {
                htmlLine =
                    "\n        set html content of newMsg to \"\(escapedBody)\""
            }

            // Optional attachments
            var attachLines = ""
            if case .array(let attachments) = arguments["attachments"] {
                for att in attachments {
                    if case .string(let path) = att, !path.isEmpty {
                        attachLines +=
                            "\n            make new attachment with properties {file name:(POSIX file \"\(path.appleScriptEscaped)\")}"
                    }
                }
            }

            let script = """
                tell application "Mail"
                    set newMsg to make new outgoing message with properties \(msgProps)\(senderLine)\(htmlLine)
                    tell newMsg
                        \(recipientLines)\(attachLines)
                    end tell
                    send newMsg
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

        Tool(
            name: "mail_reply",
            description: "Reply to an email message",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message ID to reply to (from mail_search)"
                    ),
                    "body": .string(description: "Reply body text"),
                    "replyAll": .boolean(
                        description:
                            "Reply to all recipients instead of just the sender"
                    ),
                    "mailbox": .string(
                        description: "Mailbox the message is in (speeds up lookup)"
                    ),
                    "account": .string(
                        description: "Account the message is in"
                    ),
                ],
                required: ["id", "body"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Reply to Email",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let messageId) = arguments["id"], !messageId.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"])
            }
            guard case .string(let body) = arguments["body"], !body.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Reply body is required"])
            }

            let replyAll: Bool
            if case .bool(let r) = arguments["replyAll"] { replyAll = r } else { replyAll = false }

            let escapedBody = body.appleScriptEscaped
            let findMsg = self.findMessageScript(id: messageId, arguments: arguments)
            let replyCmd = replyAll ? "reply origMsg with reply to all" : "reply origMsg"

            let script = """
                tell application "Mail"
                    \(findMsg)
                    set origMsg to m
                    set replyMsg to \(replyCmd)
                    tell replyMsg
                        set visible to false
                        set content to "\(escapedBody)" & return & return & content
                    end tell
                    send replyMsg
                    return subject of replyMsg
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(30))
            return Value.object([
                "success": .bool(true),
                "subject": .string(result),
            ])
        }

        Tool(
            name: "mail_forward",
            description: "Forward an email message to new recipients",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message ID to forward (from mail_search)"
                    ),
                    "to": .string(
                        description:
                            "Recipient email address(es), comma-separated"
                    ),
                    "body": .string(
                        description:
                            "Additional text to prepend above the forwarded message"
                    ),
                    "mailbox": .string(
                        description: "Mailbox the message is in"
                    ),
                    "account": .string(
                        description: "Account the message is in"
                    ),
                ],
                required: ["id", "to"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Forward Email",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let messageId) = arguments["id"], !messageId.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"])
            }
            guard case .string(let to) = arguments["to"], !to.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Forward recipient is required"])
            }

            let findMsg = self.findMessageScript(id: messageId, arguments: arguments)

            let recipientLines = to.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { addr in
                    "make new to recipient at end of to recipients with properties {address:\"\(addr.appleScriptEscaped)\"}"
                }.joined(separator: "\n                ")

            var bodyLine = ""
            if case .string(let body) = arguments["body"], !body.isEmpty {
                bodyLine =
                    "\n                set content to \"\(body.appleScriptEscaped)\" & return & return & content"
            }

            let script = """
                tell application "Mail"
                    \(findMsg)
                    set origMsg to m
                    set fwdMsg to forward origMsg
                    tell fwdMsg
                        set visible to false
                        \(recipientLines)\(bodyLine)
                    end tell
                    send fwdMsg
                    return subject of fwdMsg
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(30))
            return Value.object([
                "success": .bool(true),
                "to": .string(to),
                "subject": .string(result),
            ])
        }

        Tool(
            name: "mail_delete",
            description: "Move an email message to the Trash",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message ID to delete (from mail_search)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox the message is in"
                    ),
                    "account": .string(
                        description: "Account the message is in"
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Email",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let messageId) = arguments["id"], !messageId.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"])
            }

            let findMsg = self.findMessageScript(id: messageId, arguments: arguments)

            let script = """
                tell application "Mail"
                    \(findMsg)
                    set msgSubject to subject of m
                    delete m
                    return msgSubject
                end tell
                """

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "deleted": .string(result),
            ])
        }

        Tool(
            name: "mail_move",
            description: "Move an email message to a different mailbox",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message ID to move (from mail_search)"
                    ),
                    "targetMailbox": .string(
                        description:
                            "Destination mailbox name (e.g. 'Archive', 'Important')"
                    ),
                    "targetAccount": .string(
                        description:
                            "Destination account (required if multiple accounts have same mailbox name)"
                    ),
                    "mailbox": .string(
                        description: "Source mailbox the message is currently in"
                    ),
                    "account": .string(description: "Source account"),
                ],
                required: ["id", "targetMailbox"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Move Email",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let messageId) = arguments["id"], !messageId.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 15,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"])
            }
            guard case .string(let targetMailbox) = arguments["targetMailbox"],
                !targetMailbox.isEmpty
            else {
                throw NSError(
                    domain: "MailError", code: 16,
                    userInfo: [NSLocalizedDescriptionKey: "Target mailbox is required"])
            }

            let findMsg = self.findMessageScript(id: messageId, arguments: arguments)

            let targetRef: String
            if case .string(let targetAccount) = arguments["targetAccount"],
                !targetAccount.isEmpty
            {
                targetRef =
                    "mailbox \"\(targetMailbox.appleScriptEscaped)\" of account \"\(targetAccount.appleScriptEscaped)\""
            } else {
                targetRef = "mailbox \"\(targetMailbox.appleScriptEscaped)\""
            }

            let script = """
                tell application "Mail"
                    \(findMsg)
                    set msgSubject to subject of m
                    set targetBox to \(targetRef)
                    move m to targetBox
                    return msgSubject
                end tell
                """

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "moved": .string(result),
                "to": .string(targetMailbox),
            ])
        }

        Tool(
            name: "mail_flag",
            description: "Set or clear the flag on an email message",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message ID (from mail_search)"
                    ),
                    "flagged": .boolean(
                        description: "Set to true to flag, false to unflag"
                    ),
                    "mailbox": .string(
                        description: "Mailbox the message is in"
                    ),
                    "account": .string(
                        description: "Account the message is in"
                    ),
                ],
                required: ["id", "flagged"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Flag Email",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let messageId) = arguments["id"], !messageId.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 17,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"])
            }
            guard case .bool(let flagged) = arguments["flagged"] else {
                throw NSError(
                    domain: "MailError", code: 18,
                    userInfo: [NSLocalizedDescriptionKey: "Flagged status is required"])
            }

            let findMsg = self.findMessageScript(id: messageId, arguments: arguments)

            let script = """
                tell application "Mail"
                    \(findMsg)
                    set flagged status of m to \(flagged)
                    return subject of m
                end tell
                """

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "subject": .string(result),
                "flagged": .bool(flagged),
            ])
        }

        Tool(
            name: "mail_mark_read",
            description: "Mark an email message as read or unread",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message ID (from mail_search)"
                    ),
                    "read": .boolean(
                        description: "Set to true for read, false for unread"
                    ),
                    "mailbox": .string(
                        description: "Mailbox the message is in"
                    ),
                    "account": .string(
                        description: "Account the message is in"
                    ),
                ],
                required: ["id", "read"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Mark Read/Unread",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let messageId) = arguments["id"], !messageId.isEmpty else {
                throw NSError(
                    domain: "MailError", code: 19,
                    userInfo: [NSLocalizedDescriptionKey: "Message ID is required"])
            }
            guard case .bool(let read) = arguments["read"] else {
                throw NSError(
                    domain: "MailError", code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Read status is required"])
            }

            let findMsg = self.findMessageScript(id: messageId, arguments: arguments)

            let script = """
                tell application "Mail"
                    \(findMsg)
                    set read status of m to \(read)
                    return subject of m
                end tell
                """

            let result = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "subject": .string(result),
                "isRead": .bool(read),
            ])
        }
    }
}

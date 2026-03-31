import AppKit
import JSONSchema
import OSLog
import UserNotifications

private let log = Logger.service("utilities")

final class UtilitiesService: Service {
    static let shared = UtilitiesService()

    var tools: [Tool] {
        Tool(
            name: "utilities_notification",
            description: "Post a macOS notification with title and optional body",
            inputSchema: .object(
                properties: [
                    "title": .string(
                        description: "Notification title"
                    ),
                    "body": .string(
                        description: "Notification body text"
                    ),
                    "sound": .boolean(
                        description: "Play notification sound",
                        default: true
                    ),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Notification",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let title) = arguments["title"], !title.isEmpty else {
                throw NSError(
                    domain: "UtilitiesError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Notification title is required"]
                )
            }

            let content = UNMutableNotificationContent()
            content.title = title

            if case .string(let body) = arguments["body"] {
                content.body = body
            }

            if case .bool(false) = arguments["sound"] {
                // No sound
            } else {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )

            try await UNUserNotificationCenter.current().add(request)

            return Value.object([
                "success": .bool(true),
                "title": .string(title),
            ])
        }

        Tool(
            name: "utilities_beep",
            description: "Play a system sound",
            inputSchema: .object(
                properties: [
                    "sound": .string(
                        default: .string(Sound.default.rawValue),
                        enum: Sound.allCases.map { .string($0.rawValue) }
                    )
                ],
                required: ["sound"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Play System Sound",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { input in
            let rawValue = input["sound"]?.stringValue ?? Sound.default.rawValue
            guard let sound = Sound(rawValue: rawValue) else {
                log.error("Invalid sound: \(rawValue)")
                throw NSError(
                    domain: "SoundError",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Invalid sound"
                    ]
                )
            }

            return NSSound.play(sound)
        }
    }
}

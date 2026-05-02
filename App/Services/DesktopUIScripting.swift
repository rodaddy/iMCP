import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("desktop")

private let fieldSep = "---FIELD---"

/// Key code mapping for special keys
private let keyCodes: [String: Int] = [
    "return": 36, "enter": 76, "tab": 48, "escape": 53,
    "delete": 51, "forwarddelete": 117,
    "up": 126, "down": 125, "left": 123, "right": 124,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118,
    "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "space": 49,
]

extension DesktopService {
    @ToolBuilder var uiScriptingTools: [Tool] {
        Tool(
            name: "desktop_ui_elements",
            description:
                "List UI elements of an application window. Shows role, name, value, position, and child count for each element. Use to discover clickable buttons, text fields, and other controls. Requires Accessibility permission.",
            inputSchema: .object(
                properties: [
                    "app": .string(
                        description: "Application name (e.g. 'Safari', 'System Settings')"
                    ),
                    "window": .integer(
                        description: "Window index (1-based)",
                        default: .int(1)
                    ),
                    "element": .string(
                        description:
                            "Parent element to list children of (e.g. 'group 1', 'toolbar 1'). Lists window's direct children if omitted."
                    ),
                ],
                required: ["app"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List UI Elements",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let app) = arguments["app"], !app.isEmpty else {
                throw NSError(
                    domain: "DesktopError", code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Application name is required"])
            }

            let windowIndex: Int
            if case .int(let w) = arguments["window"] { windowIndex = w } else { windowIndex = 1 }

            let escapedApp = app.appleScriptEscaped
            let container: String
            if case .string(let elem) = arguments["element"], !elem.isEmpty {
                container = "\(elem) of window \(windowIndex)"
            } else {
                container = "window \(windowIndex)"
            }

            let script = """
                tell application "System Events"
                    tell process "\(escapedApp)"
                        set targetContainer to \(container)
                        set elems to every UI element of targetContainer
                        set output to ""
                        repeat with e in elems
                            set elemRole to role of e
                            set elemName to ""
                            try
                                set elemName to name of e
                            end try
                            set elemDesc to ""
                            try
                                set elemDesc to description of e
                            end try
                            set elemValue to ""
                            try
                                set elemValue to value of e as text
                            end try
                            set elemPos to position of e
                            set elemSize to size of e
                            set childCount to count of UI elements of e
                            set output to output & elemRole & "\(fieldSep)" & elemName & "\(fieldSep)" & elemDesc & "\(fieldSep)" & elemValue & "\(fieldSep)" & (item 1 of elemPos) & "," & (item 2 of elemPos) & "\(fieldSep)" & (item 1 of elemSize) & "," & (item 2 of elemSize) & "\(fieldSep)" & childCount & linefeed
                        end repeat
                        return output
                    end tell
                end tell
                """

            let result = try await self.runScript(script, timeout: .seconds(15))
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }

            return Value.array(lines.map { line in
                let fields = line.components(separatedBy: fieldSep)
                let pos = (fields.count > 4 ? fields[4] : "0,0").components(separatedBy: ",")
                let size = (fields.count > 5 ? fields[5] : "0,0").components(separatedBy: ",")
                return Value.object([
                    "role": .string(fields.count > 0 ? fields[0] : ""),
                    "name": .string(fields.count > 1 ? fields[1] : ""),
                    "description": .string(fields.count > 2 ? fields[2] : ""),
                    "value": .string(fields.count > 3 ? fields[3] : ""),
                    "x": .int(Int(pos.first ?? "0") ?? 0),
                    "y": .int(Int(pos.count > 1 ? pos[1] : "0") ?? 0),
                    "width": .int(Int(size.first ?? "0") ?? 0),
                    "height": .int(Int(size.count > 1 ? size[1] : "0") ?? 0),
                    "children": .int(Int(fields.count > 6 ? fields[6] : "0") ?? 0),
                ])
            })
        }

        Tool(
            name: "desktop_ui_click",
            description:
                "Click a UI element in an application via System Events. Use desktop_ui_elements first to discover available elements. Requires Accessibility permission.",
            inputSchema: .object(
                properties: [
                    "app": .string(
                        description: "Application name"
                    ),
                    "element": .string(
                        description:
                            "UI element reference (e.g. 'button \"Done\" of window 1', 'menu item \"Preferences\" of menu \"App\" of menu bar 1', 'checkbox 1 of group 1 of window 1')"
                    ),
                ],
                required: ["app", "element"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Click UI Element",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let app) = arguments["app"], !app.isEmpty else {
                throw NSError(
                    domain: "DesktopError", code: 21,
                    userInfo: [NSLocalizedDescriptionKey: "Application name is required"])
            }
            guard case .string(let element) = arguments["element"], !element.isEmpty else {
                throw NSError(
                    domain: "DesktopError", code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "Element reference is required"])
            }

            let escapedApp = app.appleScriptEscaped
            let script = """
                tell application "System Events"
                    tell process "\(escapedApp)"
                        click \(element)
                    end tell
                end tell
                return "clicked"
                """

            let _ = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
                "app": .string(app),
                "element": .string(element),
            ])
        }

        Tool(
            name: "desktop_ui_type",
            description:
                "Type text or press keys via System Events. Types into whichever application/field currently has focus. Use desktop_window_focus first to target a specific app.",
            inputSchema: .object(
                properties: [
                    "text": .string(
                        description: "Text to type"
                    ),
                    "key": .string(
                        description:
                            "Special key to press: return, tab, escape, delete, up, down, left, right, home, end, pageup, pagedown, space, f1-f8"
                    ),
                    "modifiers": .string(
                        description:
                            "Modifier keys: 'command', 'shift', 'option', 'control', or comma-separated combo (e.g. 'command,shift')"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Type Text/Keys",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let hasText = {
                if case .string(let t) = arguments["text"], !t.isEmpty { return true }
                return false
            }()
            let hasKey = {
                if case .string(let k) = arguments["key"], !k.isEmpty { return true }
                return false
            }()

            guard hasText || hasKey else {
                throw NSError(
                    domain: "DesktopError", code: 23,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Either text or key is required"
                    ])
            }

            // Build modifier clause
            var modifierClause = ""
            if case .string(let mods) = arguments["modifiers"], !mods.isEmpty {
                let modList = mods.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .map { "\($0) down" }
                    .joined(separator: ", ")
                modifierClause = " using {\(modList)}"
            }

            let script: String
            if case .string(let key) = arguments["key"], !key.isEmpty {
                guard let code = keyCodes[key.lowercased()] else {
                    throw NSError(
                        domain: "DesktopError", code: 24,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unknown key: \(key). Available: \(keyCodes.keys.sorted().joined(separator: ", "))"
                        ])
                }
                script = """
                    tell application "System Events"
                        key code \(code)\(modifierClause)
                    end tell
                    return "pressed"
                    """
            } else if case .string(let text) = arguments["text"] {
                let escapedText = text.appleScriptEscaped
                script = """
                    tell application "System Events"
                        keystroke "\(escapedText)"\(modifierClause)
                    end tell
                    return "typed"
                    """
            } else {
                throw NSError(
                    domain: "DesktopError", code: 25,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Either text or key is required"
                    ])
            }

            let _ = try await self.runScript(script)
            return Value.object([
                "success": .bool(true),
            ])
        }

        Tool(
            name: "desktop_ui_read",
            description:
                "Read the value, title, or content of a UI element. Use desktop_ui_elements to find the element reference first.",
            inputSchema: .object(
                properties: [
                    "app": .string(
                        description: "Application name"
                    ),
                    "element": .string(
                        description:
                            "UI element reference (e.g. 'text field 1 of window 1', 'static text 2 of group 1 of window 1')"
                    ),
                ],
                required: ["app", "element"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read UI Element",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let app) = arguments["app"], !app.isEmpty else {
                throw NSError(
                    domain: "DesktopError", code: 26,
                    userInfo: [NSLocalizedDescriptionKey: "Application name is required"])
            }
            guard case .string(let element) = arguments["element"], !element.isEmpty else {
                throw NSError(
                    domain: "DesktopError", code: 27,
                    userInfo: [NSLocalizedDescriptionKey: "Element reference is required"])
            }

            let escapedApp = app.appleScriptEscaped
            let sep = "\\n---SEPARATOR---\\n"
            let script = """
                tell application "System Events"
                    tell process "\(escapedApp)"
                        set e to \(element)
                        set elemRole to role of e
                        set elemName to ""
                        try
                            set elemName to name of e
                        end try
                        set elemValue to ""
                        try
                            set elemValue to value of e as text
                        end try
                        set elemDesc to ""
                        try
                            set elemDesc to description of e
                        end try
                        return elemRole & "\(sep)" & elemName & "\(sep)" & elemValue & "\(sep)" & elemDesc
                    end tell
                end tell
                """

            let result = try await self.runScript(script)
            let parts = result.components(separatedBy: "\n---SEPARATOR---\n")

            return Value.object([
                "role": .string(parts.count > 0 ? parts[0] : ""),
                "name": .string(parts.count > 1 ? parts[1] : ""),
                "value": .string(parts.count > 2 ? parts[2] : ""),
                "description": .string(parts.count > 3 ? parts[3] : ""),
            ])
        }
    }
}

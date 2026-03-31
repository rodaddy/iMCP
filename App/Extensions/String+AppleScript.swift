import Foundation

extension String {
    /// Escapes a string for safe interpolation into AppleScript source code.
    /// Handles backslashes, double quotes, newlines, carriage returns, and tabs
    /// which would break or escape AppleScript string literals.
    var appleScriptEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\0", with: "")
    }
}

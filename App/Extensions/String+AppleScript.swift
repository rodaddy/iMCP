import Foundation

extension String {
    /// Escapes a string for safe interpolation into AppleScript source code.
    /// Handles backslashes and double quotes which would break AppleScript string literals.
    var appleScriptEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

import Foundation

/// A single new terminal, without replaying the command in restored windows.
enum GhosttyLaunch {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func arguments(directory: String? = nil, command: String, shell: String = "/bin/zsh") -> [String] {
        var arguments = ["-na", "Ghostty.app", "--args", "--window-save-state=never"]
        var script = command
        if let directory {
            arguments.append("--working-directory=\(directory)")
            script = "cd \(quote(directory)) && " + script
        }
        arguments.append("--initial-command=\(quote(shell)) -lic \(quote(script))")
        return arguments
    }
}

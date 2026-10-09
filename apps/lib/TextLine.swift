import Foundation

extension String {
    /// One line of at most `limit` characters. A request can be a whole pasted log: shown in full, its tooltip would
    /// fill the screen and every layout pass would measure all of it, and with line breaks a one-line row shows only
    /// the first line, which may be blank.
    func oneLine(limit: Int) -> String {
        let line = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? line.prefix(limit - 1) + "…" : line
    }
}

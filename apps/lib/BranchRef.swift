// Shared by Worktree Manager and Agent Control Center.
import SwiftUI

/// GitHub's blue branch label; missing names and detached HEADs stay plain text.
struct BranchRef: View {
    let name: String
    var font: Font = .caption.monospaced()

    var body: some View {
        if name.isEmpty || name == "-" || name == "detached" || name == "HEAD" || name.hasPrefix("@") {
            Text(name.isEmpty ? "—" : name).font(font).lineLimit(1)
        } else {
            Text(name).font(font).foregroundStyle(.blue).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

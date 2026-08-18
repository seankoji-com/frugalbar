import SwiftUI

/// Footer with preferences shortcut and quit button.
struct FooterActionsView: View {
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.caption2)
                Text("Preferences")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button(action: onQuit) {
                Text("Quit")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.3))
    }
}

import SwiftUI

struct StatusBanner: View {
    let icon: String
    let title: String
    let message: String
    var tint: Color = .yellow
    var primaryAction: (label: String, action: () -> Void)? = nil
    var secondaryAction: (label: String, action: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let secondary = secondaryAction {
                Button(secondary.label, action: secondary.action)
                    .controlSize(.small)
            }
            if let primary = primaryAction {
                Button(primary.label, action: primary.action)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.4), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

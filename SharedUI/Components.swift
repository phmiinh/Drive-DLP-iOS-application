import SwiftUI

struct BrandHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct EmptyStateCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct InlineMessageBanner: View {
    let title: String
    let message: String
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct ServerBadgeView: View {
    let server: ServerDescriptor?
    let session: AccountSession

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(serverColor)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.serverLabel)
                    .font(.subheadline.weight(.semibold))
                Text(server?.hostDisplayName ?? session.serverURL.host ?? session.serverURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.isLegacy ? "Legacy" : "Cells")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
    }

    private var serverColor: Color {
        if let hex = session.customPrimaryColor, let color = Color(hex: hex) {
            return color
        }
        return .accentColor
    }
}

struct LoadingCard: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "#", with: "")

        guard value.count == 6 || value.count == 8 else {
            return nil
        }

        var raw: UInt64 = 0
        guard Scanner(string: value).scanHexInt64(&raw) else {
            return nil
        }

        let r: Double
        let g: Double
        let b: Double
        let a: Double

        if value.count == 8 {
            r = Double((raw & 0xFF00_0000) >> 24) / 255
            g = Double((raw & 0x00FF_0000) >> 16) / 255
            b = Double((raw & 0x0000_FF00) >> 8) / 255
            a = Double(raw & 0x0000_00FF) / 255
        } else {
            r = Double((raw & 0xFF00_00) >> 16) / 255
            g = Double((raw & 0x00FF_00) >> 8) / 255
            b = Double(raw & 0x0000_FF) / 255
            a = 1
        }

        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

func formattedBytes(_ value: Int64?) -> String {
    guard let value else {
        return "Unknown size"
    }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: value)
}

func formattedDate(_ date: Date?) -> String {
    guard let date else {
        return "Unknown"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

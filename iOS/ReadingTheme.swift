import SwiftUI

enum ShennaoTheme {
    static let blue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemBlue : UIColor(red: 0.08, green: 0.32, blue: 0.75, alpha: 1)
    })
    static let canvas = Color(uiColor: .systemBackground)
    static let grouped = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let quiet = Color(uiColor: .secondarySystemBackground)
    static let supportingText = Color.primary.opacity(0.68)
}

enum ReadingAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct ReadingSectionHeading: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    var detail: String? = nil
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(ShennaoTheme.supportingText) }
        }
    }
}

struct NoticeView: View {
    let title: String
    let message: String
    var symbol = "info.circle"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(ShennaoTheme.supportingText).lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(ShennaoTheme.quiet, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func readingCard(tinted: Bool = false) -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(tinted ? ShennaoTheme.blue.opacity(0.07) : ShennaoTheme.quiet, in: .rect(cornerRadius: 16))
    }
}

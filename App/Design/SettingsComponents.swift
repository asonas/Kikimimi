import SwiftUI

struct SettingsPage<Content: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let content: Content
    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.description = description; self.content = content()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).kikimimiText(.title)
                    if let description { Text(description).kikimimiText(.small).foregroundStyle(KikimimiColor.secondary) }
                }
                content
            }
            .frame(maxWidth: 792, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(KikimimiColor.ink)
        .background(KikimimiColor.surface)
        .buttonStyle(KikimimiButtonStyle.secondary)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).kikimimiText(.heading)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KikimimiColor.paper, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let label: String
    let description: String?
    @ViewBuilder let trailing: Trailing
    init(_ label: String, description: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.label = label; self.description = description; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).kikimimiText(.label)
                if let description { Text(description).kikimimiText(.small).foregroundStyle(KikimimiColor.secondary).textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing.font(KikimimiFont.label.font)
        }
        .padding(16)
    }
}

struct SettingsDivider: View {
    var body: some View { KikimimiColor.line.frame(height: 1) }
}

struct SettingsStatus: View {
    let text: String
    var ready = true
    var showsDot = false
    var body: some View {
        HStack(spacing: 8) {
            if showsDot { Circle().fill(ready ? KikimimiColor.success : KikimimiColor.danger).frame(width: 7, height: 7) }
            Text(text).kikimimiText(.label)
        }
        .foregroundStyle(ready ? KikimimiColor.success : KikimimiColor.danger)
        .fixedSize(horizontal: true, vertical: false)
    }
}

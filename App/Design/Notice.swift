import SwiftUI

enum NoticeTone {
    case success, warning, danger
    var foreground: Color {
        switch self {
        case .success: KikimimiColor.success
        case .warning: KikimimiColor.warning
        case .danger: KikimimiColor.danger
        }
    }
    var background: Color {
        switch self {
        case .success: KikimimiColor.successBg
        case .warning: KikimimiColor.warningBg
        case .danger: KikimimiColor.dangerBg
        }
    }
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.circle.fill"
        }
    }
}

struct Notice: View {
    struct Action {
        let label: String
        var isEnabled = true
        let perform: () -> Void
    }
    let tone: NoticeTone
    let title: String
    var message: String? = nil
    var action: Action? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone.symbol).font(KikimimiFont.label.font).foregroundStyle(tone.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).kikimimiText(.label).foregroundStyle(tone.foreground)
                if let message { Text(message).kikimimiText(.small).foregroundStyle(KikimimiColor.secondary) }
            }
            Spacer(minLength: 12)
            if let action {
                Button(action.label, action: action.perform).buttonStyle(KikimimiButtonStyle.secondary)
                    .disabled(!action.isEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PermissionRelaunchNotice: View {
    let env: AppEnvironment
    var body: some View {
        Notice(tone: .warning, title: "許可を反映するため再起動が必要です",
               message: "Kikimimiを再起動すると、相手のアプリの音声を録音できるようになります。",
               action: .init(label: "再起動") { env.readiness.relaunchApp() })
    }
}

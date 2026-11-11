import SwiftUI

struct KikimimiButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, text }
    let kind: Kind
    static let primary = Self(kind: .primary)
    static let secondary = Self(kind: .secondary)
    static let danger = Self(kind: .danger)
    static let text = Self(kind: .text)

    func makeBody(configuration: Configuration) -> some View {
        StyledButtonLabel(configuration: configuration, kind: kind)
    }

    private struct StyledButtonLabel: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        private var fill: Color {
            switch kind {
            case .primary: KikimimiColor.ink
            case .secondary: KikimimiColor.surface
            case .danger: KikimimiColor.dangerFill
            case .text: .clear
            }
        }
        var body: some View {
            configuration.label.font(KikimimiFont.label.font)
                .foregroundStyle(kind == .danger ? Color.white : (kind == .primary ? KikimimiColor.surface : KikimimiColor.ink))
                .padding(.horizontal, 16).frame(minHeight: 40)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay { if kind == .secondary { RoundedRectangle(cornerRadius: 8).strokeBorder(KikimimiColor.control, lineWidth: 1) } }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(!enabled ? 0.4 : (configuration.isPressed ? 0.75 : 1))
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 10).stroke(KikimimiColor.ink, lineWidth: 2).padding(-2)
                        RoundedRectangle(cornerRadius: 12).stroke(KikimimiColor.focus, lineWidth: 2).padding(-5)
                    }
                }
                .focusEffectDisabled()
        }
    }
}

struct KikimimiSegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 12) {
            ForEach(options, id: \.0) { value, label in
                Button(label) { selection = value }
                    .buttonStyle(selection == value ? KikimimiButtonStyle.primary : .secondary)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
    }
}

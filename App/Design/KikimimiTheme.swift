import SwiftUI

enum KikimimiColor {
    static let paper = Color("Kikimimi/paper")
    static let surface = Color("Kikimimi/surface")
    static let ink = Color("Kikimimi/ink")
    static let secondary = Color("Kikimimi/secondary")
    static let line = Color("Kikimimi/line")
    static let control = Color("Kikimimi/control")
    static let selected = Color("Kikimimi/selected")
    static let success = Color("Kikimimi/success")
    static let successBg = Color("Kikimimi/successBg")
    static let warning = Color("Kikimimi/warning")
    static let warningBg = Color("Kikimimi/warningBg")
    static let danger = Color("Kikimimi/danger")
    static let dangerBg = Color("Kikimimi/dangerBg")
    static let dangerFill = Color("Kikimimi/dangerFill")
    static let focus = Color("Kikimimi/focus")
    static let meterPanel = Color("Kikimimi/meterPanel")
    static let meterOff = Color("Kikimimi/meterOff")
    static let meterGreen = Color("Kikimimi/meterGreen")
    static let meterAmber = Color("Kikimimi/meterAmber")
    static let meterRed = Color("Kikimimi/meterRed")
}

enum KikimimiFont {
    case title, heading, body, label, small, time, number
    var size: CGFloat {
        switch self {
        case .title: 28
        case .heading: 18
        case .body: 16
        case .label, .number: 14
        case .small: 13
        case .time: 48
        }
    }
    var lineHeight: CGFloat {
        switch self {
        case .title: 40
        case .heading, .body: 28
        case .label, .number: 22
        case .small: 20
        case .time: 56
        }
    }
    var font: Font {
        let weight: Font.Weight = switch self {
        case .title, .heading: .bold
        case .label, .number: .medium
        default: .regular
        }
        let font = Font.system(size: size, weight: weight)
        return self == .time || self == .number ? font.monospacedDigit() : font
    }
}

struct KikimimiTypography: ViewModifier {
    let style: KikimimiFont
    func body(content: Content) -> some View {
        content.font(style.font).lineSpacing(max(0, style.lineHeight - style.size * 1.2))
            .frame(minHeight: style.lineHeight, alignment: .leading)
    }
}

extension View {
    func kikimimiText(_ style: KikimimiFont) -> some View { modifier(KikimimiTypography(style: style)) }
    func kikimimiField() -> some View {
        textFieldStyle(.plain).font(KikimimiFont.body.font).padding(12)
            .background(KikimimiColor.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(KikimimiColor.control, lineWidth: 1) }
    }
}

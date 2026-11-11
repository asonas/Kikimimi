import SwiftUI
import RecorderCore

struct LevelMeter: View {
    let channel: String
    let dbFS: Float?
    var peakDBFS: Float? = nil
    var accessibilityState: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(channel).frame(maxWidth: .infinity, alignment: .leading)
                Text(LevelMeterScale.valueText(dbFS: dbFS)).monospacedDigit()
            }
            .kikimimiText(.label)
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(0..<LevelMeterScale.segmentCount, id: \.self) { index in
                        Rectangle().fill(segmentColor(index)).frame(maxWidth: .infinity)
                    }
                }
                if let peakDBFS, peakDBFS.isFinite, let dbFS, dbFS > -120 {
                    Rectangle().fill(.white).frame(width: 2)
                        .offset(x: max(0, (geometry.size.width - 2) * LevelMeterScale.position(dbFS: peakDBFS)))
                }
            }
            .frame(height: 18)
            HStack {
                ForEach(Array(["−60", "−48", "−36", "−24", "−12", "0"].enumerated()), id: \.offset) { index, label in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(label).kikimimiText(.small).monospacedDigit()
                }
            }
        }
        .foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 20)
        .background(KikimimiColor.meterPanel, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channel)、\(accessibilityState.isEmpty ? coarseState : accessibilityState)")
    }
    private var coarseState: String { LevelMeterScale.litSegments(dbFS: dbFS) > 0 ? "入力あり" : "小さい入力または音声待ち" }
    private func segmentColor(_ index: Int) -> Color {
        guard index < LevelMeterScale.litSegments(dbFS: dbFS) else { return KikimimiColor.meterOff }
        switch LevelMeterScale.band(segment: index) {
        case .green: return KikimimiColor.meterGreen
        case .amber: return KikimimiColor.meterAmber
        case .red: return KikimimiColor.meterRed
        }
    }
}

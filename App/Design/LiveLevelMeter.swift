import Foundation
import AppKit
import Observation
import SwiftUI
import RecorderCore

/// Owns only display ballistics; leaving the view cancels its frame loop.
@MainActor @Observable
private final class MeterDisplay {
    private(set) var reading: MeterReading = {
        var meter = MeterBallistics()
        return meter.frame(dbFS: nil, at: 0, reducedMotion: false, stale: false)
    }()
    @ObservationIgnored private var ballistics = MeterBallistics()
    @ObservationIgnored var sample: MeterSample?
    @ObservationIgnored var expectedLive = false
    @ObservationIgnored var failed = false
    @ObservationIgnored var reducedMotion = false
    @ObservationIgnored private var startedAt = ProcessInfo.processInfo.systemUptime

    func update(_ input: MeterInput) {
        if input.expectedLive != expectedLive { startedAt = ProcessInfo.processInfo.systemUptime; ballistics = MeterBallistics() }
        sample = input.sample; expectedLive = input.expectedLive
        failed = input.failed; reducedMotion = input.reducedMotion
    }
    func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        let stale = failed || (expectedLive && now - (sample?.at ?? startedAt) > 0.3)
        let next = ballistics.frame(dbFS: expectedLive ? sample?.dbFS : nil, at: now, reducedMotion: reducedMotion, stale: stale)
        if next != reading { reading = next }
    }
    func run() async {
        while !Task.isCancelled {
            frame()
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
        }
    }
}

private struct MeterInput: Equatable {
    let sample: MeterSample?
    let expectedLive: Bool
    let failed: Bool
    let reducedMotion: Bool
}

struct LiveLevelMeter: View {
    let channel: String
    let sample: MeterSample?
    var expectedLive = true
    var failed = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var display = MeterDisplay()
    var body: some View {
        LevelMeter(channel: channel, dbFS: display.reading.level, peakDBFS: display.reading.peak,
                   accessibilityState: stateText, valueText: display.reading.valueText, compact: compact)
            .onChange(of: display.reading.state) { _, _ in
                guard NSWorkspace.shared.isVoiceOverEnabled else { return }
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: "\(channel)、\(stateText)",
                                                .priority: NSAccessibilityPriorityLevel.low.rawValue])
            }
            .onChange(of: MeterInput(sample: sample, expectedLive: expectedLive, failed: failed, reducedMotion: reducedMotion), initial: true) { _, input in
                display.update(input)
            }
            .task { await display.run() }
    }
    private var stateText: String {
        switch display.reading.state {
        case .unmeasured: "未測定"
        case .silent: "無音"
        case .live: "入力あり"
        case .inputLost: "入力停止"
        }
    }
}

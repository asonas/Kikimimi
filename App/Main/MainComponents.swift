import SwiftUI
import RecorderCore

struct MainPage<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: 992, alignment: .leading)
                .padding(.horizontal, 64).padding(.vertical, 32)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .foregroundStyle(KikimimiColor.ink).background(KikimimiColor.surface)
    }
}

struct MainDivider: View {
    var body: some View { KikimimiColor.line.frame(height: 1).accessibilityHidden(true) }
}

struct MainSheet<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 24) { content }
            .padding(32).frame(width: 620, alignment: .leading)
            .foregroundStyle(KikimimiColor.ink).background(KikimimiColor.surface)
    }
}

struct RecordingListRow: View {
    let session: SessionListing
    let job: TranscriptionJobState?
    let localCapture: LocalCapture
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 24) {
                Text(SessionDate.day(session.startedAt)).kikimimiText(.label)
                    .foregroundStyle(KikimimiColor.secondary).frame(width: 88, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.company).kikimimiText(.heading)
                    if let title = session.title { Text(title).kikimimiText(.small).foregroundStyle(KikimimiColor.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(session.durationSeconds.map(SessionDate.duration) ?? "—")
                    .kikimimiText(.number).foregroundStyle(KikimimiColor.secondary).frame(width: 100, alignment: .leading)
                Text(SessionPage.statusText(state: session.state, job: job, localCapture: localCapture, hasSummary: session.hasSummary))
                    .kikimimiText(.small).foregroundStyle(KikimimiColor.secondary).frame(width: 140, alignment: .leading)
                Text("開く").kikimimiText(.label).frame(width: 48)
            }
            .padding(.vertical, 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension AppEnvironment {
    func localCapture(for ref: SessionRef) -> LocalCapture {
        switch recorder.phase {
        case .recording(let value) where value.ref == ref: .recording
        case .stopping(let value) where value.ref == ref: .stopping
        default: .none
        }
    }
}

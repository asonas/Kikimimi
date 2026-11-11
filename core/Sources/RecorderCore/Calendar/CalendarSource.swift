import Foundation

public struct CalendarEvent: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendarID: String
    public let calendarTitle: String
    public let meetingURL: URL?
    public let isAllDay: Bool

    public init(id: String, title: String, start: Date, end: Date, calendarID: String,
                calendarTitle: String, meetingURL: URL?, isAllDay: Bool = false) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.calendarID = calendarID; self.calendarTitle = calendarTitle
        self.meetingURL = meetingURL; self.isAllDay = isAllDay
    }
}

public enum CalendarAccess: Sendable, Equatable {
    case notDetermined, denied, restricted, authorized
}

public struct CalendarInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let source: String
    public init(id: String, title: String, source: String) {
        self.id = id; self.title = title; self.source = source
    }
}

@MainActor
public protocol CalendarSource: Sendable {
    func access() -> CalendarAccess
    func requestAccess() async -> CalendarAccess
    func calendars() -> [CalendarInfo]
    func events(from: Date, to: Date) -> [CalendarEvent]
}

public enum MeetingLink {
    public static func find(url: URL?, location: String?, notes: String?) -> URL? {
        func supported(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
            return host == "meet.google.com" || host == "zoom.us" || host.hasSuffix(".zoom.us")
                || host == "teams.microsoft.com" || host == "teams.live.com"
        }
        if let url, supported(url) { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in [location, notes].compactMap({ $0 }) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, supported(url) { return url }
            }
        }
        return nil
    }
}

public enum UpcomingEvents {
    public static func select(_ events: [CalendarEvent], now: Date, calendars: Set<String>?) -> [CalendarEvent] {
        events.filter { !$0.isAllDay && $0.end >= now && (calendars?.contains($0.calendarID) ?? true) }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.title != $1.title { return $0.title < $1.title }
                return $0.id < $1.id
            }
    }
}

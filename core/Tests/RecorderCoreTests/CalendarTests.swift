import Foundation
import Testing
@testable import RecorderCore

@Test func meetingLinkPrefersURLThenFirstSupportedLocationLinkThenNotes() {
    let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
    let zoom = URL(string: "https://us02web.zoom.us/j/123")!
    let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!
    #expect(MeetingLink.find(url: meet, location: zoom.absoluteString, notes: teams.absoluteString) == meet)
    #expect(MeetingLink.find(url: URL(string: "https://example.com"),
                            location: "会議 https://example.com 次に \(zoom) または \(meet)", notes: teams.absoluteString) == zoom)
    #expect(MeetingLink.find(url: nil, location: "会議室A", notes: "参加: \(teams)") == teams)
    #expect(MeetingLink.find(url: nil, location: nil, notes: nil) == nil)
}

@Test func meetingLinkAllowsOnlyHTTPSAndExactSupportedHostsOrZoomSubdomains() {
    for host in ["meet.google.com", "zoom.us", "a.b.zoom.us", "teams.microsoft.com", "teams.live.com"] {
        let url = URL(string: "https://\(host)/meeting")!
        #expect(MeetingLink.find(url: url, location: nil, notes: nil) == url)
    }
    for text in ["http://meet.google.com/abc", "https://meet.google.com.evil.example/abc",
                 "https://notzoom.us/abc", "https://zoom.us.evil.example/abc", "https://sub.teams.live.com/abc",
                 "https://example.com/meet.google.com", "ftp://zoom.us/abc"] {
        #expect(MeetingLink.find(url: URL(string: text), location: text, notes: text) == nil)
    }
}

private func calendarEvent(_ id: String, title: String = "面接", start: Double = 100, end: Double = 200,
                           calendar: String = "work", allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, title: title, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                  calendarID: calendar, calendarTitle: calendar, meetingURL: nil, isAllDay: allDay)
}

@Test func upcomingEventsDropAllDayAndExpiredButKeepOngoingAndEndBoundary() {
    let rows = [calendarEvent("expired", end: 149), calendarEvent("boundary", end: 150),
                calendarEvent("allDay", allDay: true), calendarEvent("ongoing"),
                calendarEvent("future", start: 180, end: 220)]
    #expect(UpcomingEvents.select(rows, now: Date(timeIntervalSince1970: 150), calendars: nil).map(\.id)
            == ["boundary", "ongoing", "future"])
}

@Test func upcomingEventsFilterCalendarsAndSortByStartThenTitle() {
    let rows = [calendarEvent("later", start: 120), calendarEvent("b", title: "B"),
                calendarEvent("a", title: "A"), calendarEvent("personal", start: 90, calendar: "personal")]
    let now = Date(timeIntervalSince1970: 100)
    #expect(UpcomingEvents.select(rows, now: now, calendars: nil).map(\.id) == ["personal", "a", "b", "later"])
    #expect(UpcomingEvents.select(rows, now: now, calendars: ["work"]).map(\.id) == ["a", "b", "later"])
    #expect(UpcomingEvents.select(rows, now: now, calendars: []).isEmpty)
}

@Test func oldSettingsDecodeWithCalendarAndSummaryDefaultsAndRoundTrip() throws {
    let old = Data(#"{"language":"en","modelVariant":"test-model","screenCaptureRequested":true,"mic":{"deviceUID":"mic","deviceName":"Microphone","channel":1}}"#.utf8)
    var settings = try JSONDecoder().decode(Settings.self, from: old)
    #expect(settings.calendarIDs == nil)
    #expect(settings.summaryModel == "gpt-6.1-sol")
    #expect(!settings.summaryConsent)
    #expect(settings.summaryProvider == .apiKey)
    #expect(settings.language == "en")
    #expect(settings.modelVariant == "test-model")
    #expect(settings.screenCaptureRequested)
    #expect(settings.mic?.deviceUID == "mic")
    settings.summaryModel = "custom-model"
    settings.summaryConsent = true
    settings.summaryProvider = .chatGPT
    for ids: Set<String>? in [nil, [], ["work", "personal"]] {
        settings.calendarIDs = ids
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
    }
}

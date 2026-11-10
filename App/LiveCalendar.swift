import EventKit
import Foundation
import Observation
import OSLog
import RecorderCore

@MainActor
final class LiveCalendar: CalendarSource {
    static let changedNotification = Notification.Name.EKEventStoreChanged
    private let store = EKEventStore()

    func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied, .writeOnly: .denied
        case .fullAccess: .authorized
        @unknown default: .denied
        }
    }

    func requestAccess() async -> CalendarAccess {
        do { _ = try await store.requestFullAccessToEvents() }
        catch { Logger(subsystem: "as.ason.Kikimimi", category: "calendar").error("Calendar access request failed: \(error)") }
        return access()
    }

    func calendars() -> [CalendarInfo] {
        guard access() == .authorized else { return [] }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title)
        }.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }

    func events(from: Date, to: Date) -> [CalendarEvent] {
        guard access() == .authorized, from < to else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)/\(event.startDate.timeIntervalSinceReferenceDate)",
                          title: event.title ?? "（タイトルなし）", start: event.startDate, end: event.endDate,
                          calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                          meetingURL: MeetingLink.find(url: event.url, location: event.location, notes: event.notes),
                          isAllDay: event.isAllDay)
        }
    }
}

@MainActor @Observable
final class CalendarModel {
    private let source: any CalendarSource
    private(set) var access: CalendarAccess = .notDetermined
    private(set) var calendars: [CalendarInfo] = []
    private(set) var events: [CalendarEvent] = []
    private(set) var requesting = false

    init(source: any CalendarSource) { self.source = source }

    func refresh(calendars selected: Set<String>?, now: Date = Date()) {
        access = source.access()
        guard access == .authorized else { calendars = []; events = []; return }
        calendars = source.calendars()
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else {
            events = []; return
        }
        events = UpcomingEvents.select(source.events(from: now, to: end), now: now, calendars: selected)
    }

    func requestAccess(calendars selected: Set<String>?) async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        _ = await source.requestAccess()
        refresh(calendars: selected)
    }
}

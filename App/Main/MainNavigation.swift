import Observation
import RecorderCore

enum MainRoute: Hashable {
    case session(SessionRef)
    case prepare(CalendarEvent?)
}

@MainActor @Observable
final class MainNavigation {
    var path: [MainRoute] = []
    func prepare(event: CalendarEvent? = nil) { path = [.prepare(event)] }
    func showSession(_ ref: SessionRef) { path = [.session(ref)] }
    func showList() { path.removeAll() }
    func cancelPrepare() { if case .prepare = path.last { path.removeLast() } }
}

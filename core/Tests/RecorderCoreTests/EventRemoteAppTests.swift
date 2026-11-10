import Foundation
import Testing
@testable import RecorderCore

@Test func eventRemoteAppPrefersRunningZoomAndTeamsOverSavedChoice() {
    for (url, candidates, expected) in [
        ("https://us02web.zoom.us/j/123", ["browser", "us.zoom.xos"], "us.zoom.xos"),
        ("https://zoom.us/j/123", ["browser", "us.zoom.xos"], "us.zoom.xos"),
        ("https://teams.microsoft.com/l/meetup-join/123", ["browser", "com.microsoft.teams"], "com.microsoft.teams"),
        ("https://teams.live.com/meet/123", ["com.microsoft.teams", "browser", "com.microsoft.teams2"], "com.microsoft.teams2")
    ] {
        #expect(EventRemoteApp.select(meetingURL: URL(string: url), candidateBundleIDs: candidates, savedID: "browser") == expected)
    }
}

@Test func eventRemoteAppFallsBackToSavedThenFirstForMeetUnknownMissingAndUnavailableApps() {
    for url in [nil, "https://meet.google.com/abc", "https://example.com/meeting", "https://zoom.us/j/123",
                "https://teams.microsoft.com/l/meetup-join/123", "https://notzoom.us/123"] {
        let meeting = url.flatMap(URL.init(string:))
        #expect(EventRemoteApp.select(meetingURL: meeting, candidateBundleIDs: ["first", "saved"], savedID: "saved") == "saved")
        #expect(EventRemoteApp.select(meetingURL: meeting, candidateBundleIDs: ["first", "saved"], savedID: "absent") == "first")
        #expect(EventRemoteApp.select(meetingURL: meeting, candidateBundleIDs: ["first"], savedID: nil) == "first")
        #expect(EventRemoteApp.select(meetingURL: meeting, candidateBundleIDs: [], savedID: "saved") == nil)
    }
    #expect(EventRemoteApp.select(meetingURL: nil, candidateBundleIDs: ["browser", "all-system-audio"],
                                 savedID: "all-system-audio") == "all-system-audio")
}

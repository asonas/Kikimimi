import Foundation

public enum EventRemoteApp {
    public static func select(meetingURL: URL?, candidateBundleIDs: [String], savedID: String?) -> String? {
        let host = meetingURL?.host?.lowercased()
        let preferred: [String]
        if let host, host == "zoom.us" || host.hasSuffix(".zoom.us") {
            preferred = ["us.zoom.xos"]
        } else if host == "teams.microsoft.com" || host == "teams.live.com" {
            preferred = ["com.microsoft.teams2", "com.microsoft.teams"]
        } else { preferred = [] }
        return preferred.first(where: candidateBundleIDs.contains)
            ?? savedID.flatMap { candidateBundleIDs.contains($0) ? $0 : nil }
            ?? candidateBundleIDs.first
    }
}

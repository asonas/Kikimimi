import Foundation

/// A setting the automatic summary and export after transcription needs. The settings screen disables the switch while
/// any is missing, and the app checks again when a transcript is ready, because a setting can be undone in between.
public enum AutoFollowUpRequirement: Sendable, Equatable, CaseIterable {
    case transcriptionModel
    case summaryProvider
    case summaryModel
    case exportFolder

    /// Missing requirements in `allCases` order. Empty means the automatic run can start.
    public static func missing(modelReady: Bool, providerReady: Bool, summaryModel: String,
                               exportFolder: String?) -> [AutoFollowUpRequirement] {
        allCases.filter { requirement in
            switch requirement {
            case .transcriptionModel: !modelReady
            case .summaryProvider: !providerReady
            case .summaryModel: summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .exportFolder: exportFolder == nil
            }
        }
    }
}

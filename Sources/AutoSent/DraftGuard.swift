import Foundation

enum DraftGuard {
    static let maximumLateness: TimeInterval = 15

    static func isBindableRoomTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("LINE") != .orderedSame
    }

    static func isDueAndFresh(scheduledDate: Date, now: Date) -> Bool {
        let lateness = now.timeIntervalSince(scheduledDate)
        return lateness >= 0 && lateness <= maximumLateness
    }

    static func mainRoomIsUnchanged(
        expectedName: String,
        currentName: String?,
        sameSelectedRow: Bool,
        expectedIdentifier: String?,
        currentIdentifier: String?
    ) -> Bool {
        sameSelectedRow
            && isBindableRoomTitle(expectedName)
            && currentName == expectedName
            && currentIdentifier == expectedIdentifier
    }

    static func allowsSend(
        expectedDraft: String,
        currentDraft: String?,
        sameComposer: Bool,
        sameRoomWindow: Bool,
        expectedRoomTitle: String,
        currentRoomTitle: String?,
        lineIsFrontmost: Bool,
        originalProcessIsRunning: Bool
    ) -> Bool {
        originalProcessIsRunning
            && lineIsFrontmost
            && sameComposer
            && sameRoomWindow
            && isBindableRoomTitle(expectedRoomTitle)
            && currentRoomTitle == expectedRoomTitle
            && !expectedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && currentDraft == expectedDraft
    }
}

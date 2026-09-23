import Foundation

enum DraftGuard {
    static func allowsSend(
        expectedDraft: String,
        currentDraft: String?,
        sameComposer: Bool,
        lineIsFrontmost: Bool,
        originalProcessIsRunning: Bool
    ) -> Bool {
        originalProcessIsRunning
            && lineIsFrontmost
            && sameComposer
            && !expectedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && currentDraft == expectedDraft
    }
}

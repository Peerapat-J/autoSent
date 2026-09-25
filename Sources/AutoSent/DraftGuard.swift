import Foundation

struct LatenessDuration: Equatable {
    let hours: Int
    let minutes: Int
    let seconds: Int

    init?(hoursText: String, minutesText: String, secondsText: String) {
        func number(_ text: String) -> Int? {
            let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digits.isEmpty,
                  digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(digits)
        }

        guard let hours = number(hoursText), (0...4).contains(hours),
              let minutes = number(minutesText), (0...59).contains(minutes),
              let seconds = number(secondsText), (0...59).contains(seconds),
              (1...14_400).contains(hours * 3_600 + minutes * 60 + seconds) else {
            return nil
        }
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }

    var totalSeconds: TimeInterval { TimeInterval(hours * 3_600 + minutes * 60 + seconds) }
    var displayText: String { "\(hours) ชม. \(minutes) นาที \(seconds) วิ" }
}

enum DraftGuard {
    static func isBindableRoomTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("LINE") != .orderedSame
    }

    static func isDueAndFresh(
        scheduledDate: Date,
        now: Date,
        maximumLateness: TimeInterval
    ) -> Bool {
        guard maximumLateness.isFinite, maximumLateness >= 0 else { return false }
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

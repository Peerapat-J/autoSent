import Foundation
import XCTest

final class DraftGuardXCTests: XCTestCase {
    func testSeparateDayAndTimeKeepTheOtherPart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let original = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 9, minute: 15)))
        let otherDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 18, minute: 45)))
        let changedDay = try XCTUnwrap(ScheduleDate.replacingDay(in: original, with: otherDay, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: changedDay),
                       DateComponents(year: 2026, month: 10, day: 3, hour: 9, minute: 15))

        let changedTime = try XCTUnwrap(ScheduleDate.replacingTime(in: original, with: otherDay, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: changedTime),
                       DateComponents(year: 2026, month: 9, day: 25, hour: 18, minute: 45))
    }

    private func allowsSend(
        draft: String? = "งานตอนเช้า",
        sameComposer: Bool = true,
        sameRoomWindow: Bool = true,
        roomTitle: String? = "ทีมพัฒนา",
        lineIsFrontmost: Bool = true,
        processIsRunning: Bool = true
    ) -> Bool {
        DraftGuard.allowsSend(
            expectedDraft: "งานตอนเช้า",
            currentDraft: draft,
            sameComposer: sameComposer,
            sameRoomWindow: sameRoomWindow,
            expectedRoomTitle: "ทีมพัฒนา",
            currentRoomTitle: roomTitle,
            lineIsFrontmost: lineIsFrontmost,
            originalProcessIsRunning: processIsRunning
        )
    }

    func testOnlyUnchangedDraftInOriginalRoomCanSend() {
        XCTAssertTrue(allowsSend())
        XCTAssertFalse(allowsSend(draft: "แก้ไขแล้ว"))
        XCTAssertFalse(allowsSend(draft: nil))
        XCTAssertFalse(allowsSend(sameComposer: false))
        XCTAssertFalse(allowsSend(sameRoomWindow: false))
        XCTAssertFalse(allowsSend(roomTitle: "ห้องอื่น"))
        XCTAssertFalse(allowsSend(lineIsFrontmost: false))
        XCTAssertFalse(allowsSend(processIsRunning: false))
    }

    func testRoomTitleMustIdentifySeparateChatWindow() {
        XCTAssertFalse(DraftGuard.isBindableRoomTitle(nil))
        XCTAssertFalse(DraftGuard.isBindableRoomTitle(" LINE "))
        XCTAssertTrue(DraftGuard.isBindableRoomTitle("ทีมพัฒนา"))
    }

    func testMainRoomRejectsDifferentSelectedRowEvenWithSameName() {
        XCTAssertTrue(DraftGuard.mainRoomIsUnchanged(
            expectedName: "ทีมพัฒนา", currentName: "ทีมพัฒนา", sameSelectedRow: true,
            expectedIdentifier: "room-1", currentIdentifier: "room-1"
        ))
        XCTAssertFalse(DraftGuard.mainRoomIsUnchanged(
            expectedName: "ทีมพัฒนา", currentName: "ทีมพัฒนา", sameSelectedRow: false,
            expectedIdentifier: "room-1", currentIdentifier: "room-1"
        ))
        XCTAssertFalse(DraftGuard.mainRoomIsUnchanged(
            expectedName: "ทีมพัฒนา", currentName: "ห้องอื่น", sameSelectedRow: true,
            expectedIdentifier: "room-1", currentIdentifier: "room-1"
        ))
        XCTAssertFalse(DraftGuard.mainRoomIsUnchanged(
            expectedName: "ทีมพัฒนา", currentName: "ทีมพัฒนา", sameSelectedRow: true,
            expectedIdentifier: "room-1", currentIdentifier: "room-2"
        ))
    }

    func testDeadlineRejectsLateWake() {
        let deadline = Date(timeIntervalSince1970: 1_000)
        let tolerance: TimeInterval = 15 * 60
        XCTAssertFalse(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(-1), maximumLateness: tolerance))
        XCTAssertTrue(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline, maximumLateness: tolerance))
        XCTAssertTrue(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(15 * 60), maximumLateness: tolerance))
        XCTAssertFalse(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(15 * 60 + 1), maximumLateness: tolerance))
        XCTAssertFalse(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(3 * 3_600), maximumLateness: tolerance))
        XCTAssertFalse(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline, maximumLateness: .nan))
    }

    func testEditableHoursMinutesSecondsHaveExactBoundary() throws {
        let duration = try XCTUnwrap(LatenessDuration(hoursText: "1", minutesText: "3", secondsText: "7"))
        XCTAssertEqual(duration.totalSeconds, 3_787)
        XCTAssertEqual(duration.displayText, "1 hr 3 min 7 sec")
        let deadline = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(3_787), maximumLateness: duration.totalSeconds))
        XCTAssertFalse(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(3_788), maximumLateness: duration.totalSeconds))
        XCTAssertNil(LatenessDuration(hoursText: "0", minutesText: "0", secondsText: "0"))
        XCTAssertNil(LatenessDuration(hoursText: "0", minutesText: "60", secondsText: "0"))
        XCTAssertNil(LatenessDuration(hoursText: "4", minutesText: "0", secondsText: "1"))
        XCTAssertNil(LatenessDuration(hoursText: "oops", minutesText: "1", secondsText: "0"))
        XCTAssertEqual(LatenessDuration(hoursText: "4", minutesText: "0", secondsText: "0")?.totalSeconds, 14_400)
    }

    func testResultDistinguishesNoKeyPressFromPostedKeyPress() throws {
        let result = SendResult(outcome: .notPressed, reason: "The selected time has passed.", date: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(result.summary.contains("Enter was not pressed"))
        XCTAssertEqual(try JSONDecoder().decode(SendResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertTrue(SendResult(outcome: .enterPosted, reason: "Check LINE", date: result.date)
            .summary.contains("Enter was pressed"))
        let savedResult = SendResult(
            outcome: .notPressed,
            reason: "เครื่องตื่นหรือแอปทำงานช้ากว่าเวลาที่ตั้งไว้เกิน 0 ชม. 15 นาที 0 วิ",
            date: result.date
        )
        XCTAssertEqual(
            savedResult.displayReason,
            "The Mac woke or the app resumed more than 0 hr 15 min 0 sec after the scheduled time."
        )
    }

    func testAlarmOnlyRunsWhenKeyPressNeedsUserAttention() {
        XCTAssertTrue(FailureAlertMode.alarm.requiresAlarm(for: .notPressed))
        XCTAssertTrue(FailureAlertMode.alarm.requiresAlarm(for: .uncertain))
        XCTAssertFalse(FailureAlertMode.alarm.requiresAlarm(for: .cancelled))
        XCTAssertFalse(FailureAlertMode.alarm.requiresAlarm(for: .enterPosted))
        XCTAssertFalse(FailureAlertMode.notification.requiresAlarm(for: .notPressed))
    }

    func testUnacknowledgedAlarmSurvivesRestartUntilAcknowledged() throws {
        let suite = "autoSent.alarm-journal.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PendingStage.postingEnter.rawValue, forKey: AlarmJournal.pendingStageKey)
        defaults.set(FailureAlertMode.alarm.rawValue, forKey: AlarmJournal.pendingAlertModeKey)

        let uncertain = SendResult(
            outcome: .uncertain,
            reason: "The app stopped while pressing Enter. Check LINE before sending manually.",
            date: Date(timeIntervalSince1970: 1_000)
        )
        AlarmJournal.record(uncertain, needsAlarm: true, in: defaults)
        XCTAssertNil(defaults.string(forKey: AlarmJournal.pendingStageKey))
        XCTAssertNil(defaults.string(forKey: AlarmJournal.pendingAlertModeKey))

        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AlarmJournal.unacknowledgedResult(in: reopenedDefaults), uncertain)
        XCTAssertEqual(AlarmJournal.lastResult(in: reopenedDefaults), uncertain)

        AlarmJournal.acknowledge(in: reopenedDefaults)
        XCTAssertNil(AlarmJournal.unacknowledgedResult(in: defaults))
        XCTAssertEqual(AlarmJournal.lastResult(in: defaults), uncertain)
    }

    func testStandardNotificationDoesNotPersistAlarm() throws {
        let suite = "autoSent.alarm-journal.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let result = SendResult(outcome: .notPressed, reason: "The deadline was missed.", date: .now)
        AlarmJournal.record(result, needsAlarm: false, in: defaults)
        XCTAssertNil(AlarmJournal.unacknowledgedResult(in: defaults))
        XCTAssertEqual(AlarmJournal.lastResult(in: defaults), result)
    }
}

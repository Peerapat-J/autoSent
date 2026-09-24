import Foundation
import XCTest

final class DraftGuardXCTests: XCTestCase {
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

    func testResultDistinguishesNoKeyPressFromPostedKeyPress() throws {
        let result = SendResult(outcome: .notPressed, reason: "เลยเวลาที่เลือก", date: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(result.summary.contains("ยังไม่ได้กด Enter"))
        XCTAssertEqual(try JSONDecoder().decode(SendResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertTrue(SendResult(outcome: .enterPosted, reason: "ตรวจ LINE", date: result.date)
            .summary.contains("โพสต์ปุ่ม Enter แล้ว"))
    }

    func testAlarmOnlyRunsWhenKeyPressNeedsUserAttention() {
        XCTAssertTrue(FailureAlertMode.alarm.requiresAlarm(for: .notPressed))
        XCTAssertTrue(FailureAlertMode.alarm.requiresAlarm(for: .uncertain))
        XCTAssertFalse(FailureAlertMode.alarm.requiresAlarm(for: .cancelled))
        XCTAssertFalse(FailureAlertMode.alarm.requiresAlarm(for: .enterPosted))
        XCTAssertFalse(FailureAlertMode.notification.requiresAlarm(for: .notPressed))
    }
}

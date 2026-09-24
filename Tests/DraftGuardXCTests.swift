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
        XCTAssertFalse(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(-1)))
        XCTAssertTrue(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline))
        XCTAssertTrue(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(15)))
        XCTAssertFalse(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(16)))
        XCTAssertFalse(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(3_600)))
    }
}

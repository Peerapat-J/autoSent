import Foundation

@main
struct DraftGuardTests {
    static func main() {
        func accepts(
            _ current: String?,
            _ sameComposer: Bool,
            _ sameRoomWindow: Bool,
            _ currentRoomTitle: String?,
            _ front: Bool,
            _ running: Bool
        ) -> Bool {
            DraftGuard.allowsSend(
                expectedDraft: "งานตอนเช้า",
                currentDraft: current,
                sameComposer: sameComposer,
                sameRoomWindow: sameRoomWindow,
                expectedRoomTitle: "ทีมพัฒนา",
                currentRoomTitle: currentRoomTitle,
                lineIsFrontmost: front,
                originalProcessIsRunning: running
            )
        }

        precondition(accepts("งานตอนเช้า", true, true, "ทีมพัฒนา", true, true))
        precondition(!accepts("แก้ไขแล้ว", true, true, "ทีมพัฒนา", true, true))
        precondition(!accepts(nil, true, true, "ทีมพัฒนา", true, true))
        precondition(!accepts("งานตอนเช้า", false, true, "ทีมพัฒนา", true, true))
        // Another room with the same composer and identical draft must still fail.
        precondition(!accepts("งานตอนเช้า", true, false, "ทีมพัฒนา", true, true))
        precondition(!accepts("งานตอนเช้า", true, true, "ห้องอื่น", true, true))
        precondition(!accepts("งานตอนเช้า", true, true, "ทีมพัฒนา", false, true))
        precondition(!accepts("งานตอนเช้า", true, true, "ทีมพัฒนา", true, false))
        precondition(!DraftGuard.isBindableRoomTitle(nil))
        precondition(!DraftGuard.isBindableRoomTitle(" LINE "))
        precondition(DraftGuard.isBindableRoomTitle("ทีมพัฒนา"))

        let deadline = Date(timeIntervalSince1970: 1_000)
        precondition(!DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(-1)))
        precondition(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline))
        precondition(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(14)))
        precondition(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(15)))
        precondition(!DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(16)))
        precondition(!DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(3_600)))
        precondition(!DraftGuard.allowsSend(
            expectedDraft: "  \n",
            currentDraft: "  \n",
            sameComposer: true,
            sameRoomWindow: true,
            expectedRoomTitle: "ทีมพัฒนา",
            currentRoomTitle: "ทีมพัฒนา",
            lineIsFrontmost: true,
            originalProcessIsRunning: true
        ))
        print("DraftGuard tests passed")
    }
}

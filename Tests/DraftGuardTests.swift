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
        precondition(DraftGuard.mainRoomIsUnchanged(
            expectedName: "ทีมพัฒนา", currentName: "ทีมพัฒนา", sameSelectedRow: true,
            expectedIdentifier: nil, currentIdentifier: nil
        ))
        precondition(!DraftGuard.mainRoomIsUnchanged(
            expectedName: "ทีมพัฒนา", currentName: "ทีมพัฒนา", sameSelectedRow: false,
            expectedIdentifier: nil, currentIdentifier: nil
        ))

        let deadline = Date(timeIntervalSince1970: 1_000)
        let tolerance: TimeInterval = 15 * 60
        precondition(!DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(-1), maximumLateness: tolerance))
        precondition(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline, maximumLateness: tolerance))
        precondition(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(14 * 60), maximumLateness: tolerance))
        precondition(DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(15 * 60), maximumLateness: tolerance))
        precondition(!DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(15 * 60 + 1), maximumLateness: tolerance))
        precondition(!DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline.addingTimeInterval(3 * 3_600), maximumLateness: tolerance))
        precondition(!DraftGuard.isDueAndFresh(scheduledDate: deadline, now: deadline, maximumLateness: -.infinity))
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
        let result = SendResult(outcome: .notPressed, reason: "เลยเวลาที่เลือก", date: deadline)
        precondition(result.summary.contains("ยังไม่ได้กด Enter"))
        precondition(try! JSONDecoder().decode(SendResult.self, from: JSONEncoder().encode(result)) == result)
        precondition(SendResult(outcome: .enterPosted, reason: "ตรวจ LINE", date: deadline)
            .summary.contains("โพสต์ปุ่ม Enter แล้ว"))
        print("DraftGuard tests passed")
    }
}

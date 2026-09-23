import Foundation

@main
struct DraftGuardTests {
    static func main() {
        func accepts(_ current: String?, _ same: Bool, _ front: Bool, _ running: Bool) -> Bool {
            DraftGuard.allowsSend(
                expectedDraft: "งานตอนเช้า",
                currentDraft: current,
                sameComposer: same,
                lineIsFrontmost: front,
                originalProcessIsRunning: running
            )
        }

        precondition(accepts("งานตอนเช้า", true, true, true))
        precondition(!accepts("แก้ไขแล้ว", true, true, true))
        precondition(!accepts(nil, true, true, true))
        precondition(!accepts("งานตอนเช้า", false, true, true))
        precondition(!accepts("งานตอนเช้า", true, false, true))
        precondition(!accepts("งานตอนเช้า", true, true, false))
        precondition(!DraftGuard.allowsSend(
            expectedDraft: "  \n",
            currentDraft: "  \n",
            sameComposer: true,
            lineIsFrontmost: true,
            originalProcessIsRunning: true
        ))
        print("DraftGuard tests passed")
    }
}

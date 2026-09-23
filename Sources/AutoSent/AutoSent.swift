import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.pwr_mgt
import SwiftUI

private let lineBundleID = "jp.naver.line.mac"

private struct DraftSnapshot {
    let processID: pid_t
    let composer: AXUIElement
    let text: String
}

@MainActor
private final class Scheduler: ObservableObject {
    enum Phase {
        case idle, capturing, armed, sending
    }

    @Published var sendDate = Calendar.current.nextDate(
        after: .now,
        matching: DateComponents(hour: 9, minute: 0, second: 0),
        matchingPolicy: .nextTime
    ) ?? Date.now.addingTimeInterval(60 * 60)
    @Published var phase: Phase = .idle
    @Published var status = "พิมพ์ข้อความร่างในห้อง LINE ที่ต้องการ แล้วตั้งเวลาส่ง"
    @Published var remaining = ""

    private var scheduledDate: Date?
    private var snapshot: DraftSnapshot?
    private var captureTimer: Timer?
    private var clockTimer: Timer?
    private var displayAssertion: IOPMAssertionID?

    func prepare() {
        guard phase == .idle else { return }

        let selectedMinute = Calendar.current.dateInterval(of: .minute, for: sendDate)?.start ?? sendDate
        guard selectedMinute > .now else {
            status = "กรุณาเลือกเวลาในอนาคต"
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            status = "เปิดสิทธิ์ Accessibility ให้ autoSent ใน System Settings แล้วกดเตรียมอีกครั้ง"
            return
        }

        var assertion = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "autoSent is waiting for a LINE draft" as CFString,
            &assertion
        )
        guard result == kIOReturnSuccess else {
            status = "กันหน้าจอดับไม่ได้ (IOKit error \(result)) จึงยังไม่เริ่มตั้งเวลา"
            return
        }

        displayAssertion = assertion
        scheduledDate = selectedMinute
        phase = .capturing
        status = "ภายใน 5 วินาที กลับไป LINE แล้วคลิกช่องพิมพ์ที่มีข้อความร่าง"

        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureDraft() }
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        guard phase != .idle else { return }
        finish("ยกเลิกแล้ว • ไม่ได้กด Enter")
    }

    private func captureDraft() {
        guard phase == .capturing else { return }
        guard let scheduledDate, scheduledDate > .now else {
            finish("ตั้งเวลาไม่สำเร็จ: เวลาที่เลือกผ่านไปแล้วระหว่างเตรียมส่ง")
            return
        }
        guard let line = NSWorkspace.shared.frontmostApplication,
              line.bundleIdentifier == lineBundleID else {
            finish("ตั้งเวลาไม่สำเร็จ: ตอนจับร่าง LINE ต้องเป็นแอปที่อยู่ด้านหน้า")
            return
        }

        let lineAX = AXUIElementCreateApplication(line.processIdentifier)
        guard let composer = readElement(lineAX, kAXFocusedUIElementAttribute as String),
              readString(composer, kAXRoleAttribute as String) == (kAXTextAreaRole as String),
              let draft = readString(composer, kAXValueAttribute as String),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish("ตั้งเวลาไม่สำเร็จ: กรุณาคลิกช่องพิมพ์ LINE ที่มีข้อความร่าง แล้วลองใหม่")
            return
        }

        snapshot = DraftSnapshot(processID: line.processIdentifier, composer: composer, text: draft)
        phase = .armed
        status = "ตั้งเวลาแล้ว • จะส่งร่างเดิมจากช่องนี้เท่านั้น • หน้าจอไม่ดับจากการไม่ได้ใช้งาน"
        updateRemaining()

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        clockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard phase == .armed, let scheduledDate else { return }
        if Date.now >= scheduledDate {
            sendOnce()
        } else {
            updateRemaining()
        }
    }

    private func updateRemaining() {
        guard let scheduledDate else { return }
        let seconds = max(0, Int(ceil(scheduledDate.timeIntervalSinceNow)))
        remaining = String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }

    private func sendOnce() {
        // Stop the repeating timer before any asynchronous app activation.
        guard phase == .armed, let snapshot else { return }
        clockTimer?.invalidate()
        clockTimer = nil
        phase = .sending
        status = "ถึงเวลาแล้ว • กำลังตรวจช่องข้อความ LINE"

        Task { @MainActor [weak self] in
            await self?.activateVerifyAndSend(snapshot)
        }
    }

    private func activateVerifyAndSend(_ snapshot: DraftSnapshot) async {
        guard let line = NSRunningApplication(processIdentifier: snapshot.processID),
              !line.isTerminated,
              line.bundleIdentifier == lineBundleID,
              AXIsProcessTrusted(),
              line.activate(options: []) else {
            finish("ไม่ได้ส่ง: LINE ปิดไปแล้ว เปิดหน้าต่างไม่ได้ หรือสิทธิ์ Accessibility ถูกปิด")
            return
        }

        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID
        let focused = readElement(
            AXUIElementCreateApplication(snapshot.processID),
            kAXFocusedUIElementAttribute as String
        )
        let sameComposer = focused.map { CFEqual($0, snapshot.composer) } ?? false
        let currentDraft = focused.flatMap { readString($0, kAXValueAttribute as String) }

        guard DraftGuard.allowsSend(
            expectedDraft: snapshot.text,
            currentDraft: currentDraft,
            sameComposer: sameComposer,
            lineIsFrontmost: frontmost,
            originalProcessIsRunning: !line.isTerminated
        ) else {
            finish("ไม่ได้ส่ง: ห้อง/ช่องพิมพ์เปลี่ยนไป ข้อความร่างถูกแก้ หรือ LINE ไม่อยู่ด้านหน้า")
            return
        }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false) else {
            finish("ไม่ได้ส่ง: สร้างปุ่ม Enter ไม่สำเร็จ")
            return
        }

        // A single Return press is one key-down and one key-up event.
        down.postToPid(snapshot.processID)
        up.postToPid(snapshot.processID)
        finish("ส่งปุ่ม Enter หนึ่งครั้งไปยังช่องพิมพ์ LINE แล้ว")
    }

    private func finish(_ message: String) {
        captureTimer?.invalidate()
        clockTimer?.invalidate()
        captureTimer = nil
        clockTimer = nil
        snapshot = nil
        scheduledDate = nil
        remaining = ""
        phase = .idle
        if let displayAssertion {
            IOPMAssertionRelease(displayAssertion)
            self.displayAssertion = nil
        }
        status = message
    }

    private func readElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

private struct ContentView: View {
    @ObservedObject var scheduler: Scheduler

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("autoSent for LINE")
                .font(.title.bold())
            Text("ส่งข้อความร่างที่พิมพ์ไว้แล้ว ด้วย Enter หนึ่งครั้งตามเวลา")
                .foregroundStyle(.secondary)

            DatePicker(
                "เวลาส่ง",
                selection: $scheduler.sendDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .disabled(scheduler.phase != .idle)

            if scheduler.phase == .armed {
                Text("เหลือเวลา \(scheduler.remaining)")
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
            }

            Text(scheduler.status)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if scheduler.phase == .idle {
                    Button("เตรียมส่ง") { scheduler.prepare() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("ยกเลิก") { scheduler.cancel() }
                        .disabled(scheduler.phase == .sending)
                }
                Spacer()
            }

            Text("เปิด LINE และร่างข้อความในห้องที่ถูกต้องไว้ก่อน • หลังตั้งเวลาอย่าเปลี่ยนห้องหรือแก้ร่าง • ปิดฝาเครื่องหรือสั่ง Sleep เองยังทำให้เครื่องพักได้")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 540)
    }
}

@main
private struct AutoSentApp: App {
    @StateObject private var scheduler = Scheduler()

    var body: some Scene {
        Window("autoSent", id: "main") {
            ContentView(scheduler: scheduler)
        }
        .windowResizability(.contentSize)
    }
}

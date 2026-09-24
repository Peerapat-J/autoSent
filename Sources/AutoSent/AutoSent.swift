import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.pwr_mgt
import SwiftUI
import UserNotifications

private let lineBundleID = "jp.naver.line.mac"

private enum RoomMode: String, CaseIterable, Identifiable {
    case main = "หน้าต่างหลัก"
    case separate = "หน้าต่างแชตแยก"

    var id: Self { self }
}

private struct DraftSnapshot {
    let processID: pid_t
    let roomWindow: AXUIElement
    let roomTitle: String
    let roomMode: RoomMode
    let selectedRoomRow: AXUIElement?
    let roomIdentifier: String?
    let composer: AXUIElement
    let text: String
}

@MainActor
private final class Scheduler: ObservableObject {
    private static let lastResultKey = "autoSent.lastResult"
    private static let pendingStageKey = "autoSent.pendingStage"

    enum Phase {
        case idle, capturing, armed, sending
    }

    @Published var sendDate = Calendar.current.nextDate(
        after: .now,
        matching: DateComponents(hour: 9, minute: 0, second: 0),
        matchingPolicy: .nextTime
    ) ?? Date.now.addingTimeInterval(60 * 60)
    @Published var phase: Phase = .idle
    @Published var roomMode: RoomMode = .main
    @Published var allowedLatenessMinutes = 15
    @Published var status = "พิมพ์ข้อความร่างในห้อง LINE ที่ต้องการ แล้วตั้งเวลาส่ง"
    @Published var remaining = ""
    @Published private(set) var lastResult: SendResult?

    private var scheduledDate: Date?
    private var maximumLateness: TimeInterval?
    private var snapshot: DraftSnapshot?
    private var captureTimer: Timer?
    private var clockTimer: Timer?
    private var displayAssertion: IOPMAssertionID?

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.lastResultKey) {
            lastResult = try? JSONDecoder().decode(SendResult.self, from: data)
        }
        if let pending = defaults.string(forKey: Self.pendingStageKey) {
            let outcome: SendOutcome = pending == PendingStage.waiting.rawValue ? .notPressed : .uncertain
            let reason = outcome == .notPressed
                ? "แอปหยุดทำงานหรือเครื่องเริ่มใหม่ก่อนกด Enter; งานเดิมไม่ทำงานต่อ"
                : "แอปหยุดทำงานขณะโพสต์ปุ่ม Enter; กรุณาตรวจใน LINE ก่อนส่งเอง"
            let result = SendResult(outcome: outcome, reason: reason, date: .now)
            lastResult = result
            defaults.set(try? JSONEncoder().encode(result), forKey: Self.lastResultKey)
            defaults.removeObject(forKey: Self.pendingStageKey)
        }
    }

    func prepare() {
        guard phase == .idle else { return }

        let selectedMinute = Calendar.current.dateInterval(of: .minute, for: sendDate)?.start ?? sendDate
        guard selectedMinute > .now else {
            finish("เวลาที่เลือกผ่านไปแล้ว กรุณาเลือกเวลาในอนาคต")
            return
        }
        guard (1...240).contains(allowedLatenessMinutes) else {
            finish("ช่วงส่งช้าต้องอยู่ระหว่าง 1 ถึง 240 นาที")
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            finish("ยังไม่ได้รับสิทธิ์ Accessibility; เปิดให้ autoSent ใน System Settings แล้วลองใหม่")
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
            finish("กันหน้าจอดับไม่ได้ (IOKit error \(result)) จึงไม่เริ่มตั้งเวลา")
            return
        }

        displayAssertion = assertion
        scheduledDate = selectedMinute
        maximumLateness = TimeInterval(allowedLatenessMinutes * 60)
        phase = .capturing
        markPending(.waiting)
        status = "ภายใน 5 วินาที กลับไป LINE แล้วคลิกช่องพิมพ์ที่มีข้อความร่าง"

        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureDraft() }
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        guard phase != .idle else { return }
        finish("ผู้ใช้ยกเลิกงานก่อนกด Enter", outcome: .cancelled)
    }

    private func captureDraft() {
        guard phase == .capturing else { return }
        guard let scheduledDate, scheduledDate > .now else {
            finish("เวลาที่เลือกผ่านไปแล้วระหว่างเตรียมส่ง")
            return
        }
        guard let line = NSWorkspace.shared.frontmostApplication,
              line.bundleIdentifier == lineBundleID else {
            finish("ตอนจับร่าง LINE ไม่ใช่แอปที่อยู่ด้านหน้า")
            return
        }

        let lineAX = AXUIElementCreateApplication(line.processIdentifier)
        guard let composer = readElement(lineAX, kAXFocusedUIElementAttribute as String),
              readString(composer, kAXRoleAttribute as String) == (kAXTextAreaRole as String),
              let draft = readString(composer, kAXValueAttribute as String),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish("ไม่พบช่องพิมพ์ LINE ที่มีข้อความร่าง")
            return
        }

        guard let roomWindow = readElement(composer, kAXWindowAttribute as String)
                ?? readElement(composer, kAXTopLevelUIElementAttribute as String),
              let focusedWindow = readElement(lineAX, kAXFocusedWindowAttribute as String),
              CFEqual(roomWindow, focusedWindow) else {
            finish("ระบุหน้าต่าง LINE ที่กำลังพิมพ์ไม่ได้")
            return
        }

        let roomTitle: String
        var selectedRoomRow: AXUIElement?
        var roomIdentifier: String?
        switch roomMode {
        case .separate:
            guard let title = readString(roomWindow, kAXTitleAttribute as String),
                  DraftGuard.isBindableRoomTitle(title) else {
                finish("หน้าต่างแชตแยกไม่แสดงชื่อห้องผ่าน Accessibility")
                return
            }
            roomTitle = title
        case .main:
            guard readString(roomWindow, kAXTitleAttribute as String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("LINE") == .orderedSame,
                  let selected = selectedMainRoom(in: roomWindow) else {
                finish("LINE ไม่เปิดเผยรายการห้องที่เลือกผ่าน Accessibility; ลองใช้หน้าต่างแชตแยก")
                return
            }
            roomTitle = selected.name
            selectedRoomRow = selected.row
            roomIdentifier = selected.identifier
        }

        snapshot = DraftSnapshot(
            processID: line.processIdentifier,
            roomWindow: roomWindow,
            roomTitle: roomTitle,
            roomMode: roomMode,
            selectedRoomRow: selectedRoomRow,
            roomIdentifier: roomIdentifier,
            composer: composer,
            text: draft
        )
        phase = .armed
        status = "ตั้งเวลาแล้วสำหรับห้อง \(roomTitle) • หน้าจอไม่ดับจากการไม่ได้ใช้งาน"
        updateRemaining()

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        clockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard phase == .armed else { return }
        guard let scheduledDate, let maximumLateness else {
            finish("ข้อมูลงานที่ตั้งไว้ไม่ครบ")
            return
        }
        let now = Date.now
        if DraftGuard.isDueAndFresh(
            scheduledDate: scheduledDate, now: now, maximumLateness: maximumLateness
        ) {
            sendOnce()
        } else if now > scheduledDate {
            finish("เครื่องตื่นหรือแอปทำงานช้ากว่าเวลาที่ตั้งไว้เกิน \(Int(maximumLateness / 60)) นาที")
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
        guard phase == .armed else { return }
        guard let snapshot else {
            finish("ไม่พบข้อมูลห้องและข้อความร่างที่จับไว้")
            return
        }
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
            finish("LINE ปิดไปแล้ว เปิดหน้าต่างไม่ได้ หรือสิทธิ์ Accessibility ถูกปิด")
            return
        }

        guard AXUIElementPerformAction(snapshot.roomWindow, kAXRaiseAction as CFString) == .success else {
            finish("หน้าต่างห้อง LINE ที่จับไว้ปิดไปแล้วหรือเปิดไม่ได้")
            return
        }

        let lineAX = AXUIElementCreateApplication(snapshot.processID)
        for _ in 0..<10 {
            let lineIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID
            let focusedWindow = readElement(lineAX, kAXFocusedWindowAttribute as String)
            if lineIsFrontmost && focusedWindow.map({ CFEqual($0, snapshot.roomWindow) }) == true {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID
        let currentWindow = readElement(lineAX, kAXFocusedWindowAttribute as String)
        let sameRoomWindow = currentWindow.map { CFEqual($0, snapshot.roomWindow) } ?? false
        let currentRoomTitle: String?
        let sameRoomIdentity: Bool
        switch snapshot.roomMode {
        case .separate:
            currentRoomTitle = currentWindow.flatMap { readString($0, kAXTitleAttribute as String) }
            sameRoomIdentity = sameRoomWindow
        case .main:
            let selected = currentWindow.flatMap { selectedMainRoom(in: $0) }
            currentRoomTitle = selected?.name
            sameRoomIdentity = sameRoomWindow
                && DraftGuard.mainRoomIsUnchanged(
                    expectedName: snapshot.roomTitle,
                    currentName: selected?.name,
                    sameSelectedRow: selected.flatMap { current in
                        snapshot.selectedRoomRow.map { CFEqual(current.row, $0) }
                    } == true,
                    expectedIdentifier: snapshot.roomIdentifier,
                    currentIdentifier: selected?.identifier
                )
        }
        let focused = readElement(lineAX, kAXFocusedUIElementAttribute as String)
        let sameComposer = focused.map { CFEqual($0, snapshot.composer) } ?? false
        let currentDraft = focused.flatMap { readString($0, kAXValueAttribute as String) }

        guard DraftGuard.allowsSend(
            expectedDraft: snapshot.text,
            currentDraft: currentDraft,
            sameComposer: sameComposer,
            sameRoomWindow: sameRoomIdentity,
            expectedRoomTitle: snapshot.roomTitle,
            currentRoomTitle: currentRoomTitle,
            lineIsFrontmost: frontmost,
            originalProcessIsRunning: !line.isTerminated
        ) else {
            finish("ห้อง LINE/ช่องพิมพ์เปลี่ยน ข้อความร่างถูกแก้ หรือ LINE ไม่อยู่ด้านหน้า")
            return
        }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false) else {
            finish("สร้างปุ่ม Enter ไม่สำเร็จ")
            return
        }

        guard let scheduledDate, let maximumLateness,
              DraftGuard.isDueAndFresh(
                scheduledDate: scheduledDate, now: .now, maximumLateness: maximumLateness
              ) else {
            finish("เลยเวลาที่ตั้งไว้เกินช่วงส่งช้าที่เลือกก่อนกด Enter")
            return
        }

        // A single Return press is one key-down and one key-up event.
        markPending(.postingEnter)
        down.postToPid(snapshot.processID)
        up.postToPid(snapshot.processID)
        finish("โพสต์ปุ่ม Enter หนึ่งครั้งไปยัง LINE; ยังยืนยันการส่งถึงผู้รับไม่ได้", outcome: .enterPosted)
    }

    private func markPending(_ stage: PendingStage) {
        UserDefaults.standard.set(stage.rawValue, forKey: Self.pendingStageKey)
        UserDefaults.standard.synchronize()
    }

    private func finish(_ reason: String, outcome: SendOutcome = .notPressed) {
        captureTimer?.invalidate()
        clockTimer?.invalidate()
        captureTimer = nil
        clockTimer = nil
        snapshot = nil
        scheduledDate = nil
        maximumLateness = nil
        remaining = ""
        phase = .idle
        if let displayAssertion {
            IOPMAssertionRelease(displayAssertion)
            self.displayAssertion = nil
        }
        let result = SendResult(outcome: outcome, reason: reason, date: .now)
        lastResult = result
        status = "พร้อมตั้งเวลางานใหม่"
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(result), forKey: Self.lastResultKey)
        defaults.removeObject(forKey: Self.pendingStageKey)
        let content = UNMutableNotificationContent()
        content.title = outcome.title
        content.body = reason
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
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

    private func readElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
    }

    private func readBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return false
        }
        return value as? Bool == true
    }

    private func roomName(of row: AXUIElement) -> String? {
        let ownName = readString(row, kAXTitleAttribute as String)
            ?? readString(row, kAXDescriptionAttribute as String)
        if DraftGuard.isBindableRoomTitle(ownName) { return ownName }

        // LINE may put the room name in the first accessible label within a chat row.
        for child in readElements(row, kAXChildrenAttribute as String).prefix(8) {
            let name = readString(child, kAXTitleAttribute as String)
                ?? readString(child, kAXValueAttribute as String)
            if DraftGuard.isBindableRoomTitle(name) { return name }
        }
        return nil
    }

    private func selectedMainRoom(in window: AXUIElement) -> (row: AXUIElement, name: String, identifier: String?)? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var selectedRows: [AXUIElement] = []
        var visited = 0
        while !queue.isEmpty && visited < 500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if readString(element, kAXRoleAttribute as String) == (kAXListRole as String) {
                var selected = readElements(element, kAXSelectedRowsAttribute as String)
                if selected.isEmpty {
                    selected = readElements(element, kAXSelectedChildrenAttribute as String)
                }
                if selected.isEmpty {
                    selected = readElements(element, kAXChildrenAttribute as String).filter {
                        readBool($0, kAXSelectedAttribute as String)
                    }
                }
                selectedRows.append(contentsOf: selected.filter {
                    readString($0, kAXRoleAttribute as String) == (kAXRowRole as String)
                })
            }
            if depth < 5 {
                queue.append(contentsOf: readElements(element, kAXChildrenAttribute as String).map { ($0, depth + 1) })
            }
        }
        guard selectedRows.count == 1,
              let row = selectedRows.first,
              let name = roomName(of: row) else { return nil }
        return (row, name, readString(row, kAXIdentifierAttribute as String))
    }
}

private struct ContentView: View {
    @ObservedObject var scheduler: Scheduler

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("autoSent for LINE")
                .font(.title.bold())
            Text("ส่งข้อความร่างในห้อง LINE ด้วย Enter หนึ่งครั้งตามเวลา")
                .foregroundStyle(.secondary)

            Picker("รูปแบบหน้าต่าง LINE", selection: $scheduler.roomMode) {
                ForEach(RoomMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .disabled(scheduler.phase != .idle)

            DatePicker(
                "เวลาส่ง",
                selection: $scheduler.sendDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .disabled(scheduler.phase != .idle)

            Stepper(
                "ยอมให้ส่งช้าได้สูงสุด \(scheduler.allowedLatenessMinutes) นาที",
                value: $scheduler.allowedLatenessMinutes,
                in: 1...240
            )
            .disabled(scheduler.phase != .idle)

            if scheduler.phase == .armed {
                Text("เหลือเวลา \(scheduler.remaining)")
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
            }

            Text(scheduler.status)
                .fixedSize(horizontal: false, vertical: true)

            if let result = scheduler.lastResult {
                Divider()
                Text("ผลล่าสุด • \(result.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.outcome.title)
                    .font(.headline)
                Text(result.reason)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            Text("เลือกหน้าต่างให้ตรงกับ LINE และร่างข้อความไว้ก่อน • หลังตั้งเวลาอย่าเปลี่ยนห้องหรือแก้ร่าง • หากเลยช่วงส่งช้าที่เลือกจะไม่ส่ง")
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

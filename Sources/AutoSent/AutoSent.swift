import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.pwr_mgt
import SwiftUI
import UserNotifications

private let lineBundleID = "jp.naver.line.mac"

private enum RoomMode: String, CaseIterable, Identifiable {
    case main = "Main window"
    case separate = "Separate chat window"

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
    private static let pendingAlertModeKey = "autoSent.pendingAlertMode"

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
    @Published var latenessHours = "0"
    @Published var latenessMinutes = "15"
    @Published var latenessSeconds = "0"
    @Published var failureAlertMode: FailureAlertMode = .notification
    @Published var status = "Type a draft in the LINE chat, then choose when to send it."
    @Published var remaining = ""
    @Published private(set) var lastResult: SendResult?

    private var scheduledDate: Date?
    private var maximumLateness: LatenessDuration?
    private var snapshot: DraftSnapshot?
    private var captureTimer: Timer?
    private var clockTimer: Timer?
    private var displayAssertion: IOPMAssertionID?
    private var activeAlertMode: FailureAlertMode?
    private var alarmSound: NSSound?

    var enteredLateness: LatenessDuration? {
        LatenessDuration(
            hoursText: latenessHours,
            minutesText: latenessMinutes,
            secondsText: latenessSeconds
        )
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.lastResultKey) {
            lastResult = try? JSONDecoder().decode(SendResult.self, from: data)
        }
        if let pending = defaults.string(forKey: Self.pendingStageKey) {
            let outcome: SendOutcome = pending == PendingStage.waiting.rawValue ? .notPressed : .uncertain
            let reason = outcome == .notPressed
                ? "The app stopped or the Mac restarted before Enter was pressed. The scheduled send will not resume."
                : "The app stopped while pressing Enter. Check LINE before sending manually to avoid a duplicate."
            let result = SendResult(outcome: outcome, reason: reason, date: .now)
            lastResult = result
            defaults.set(try? JSONEncoder().encode(result), forKey: Self.lastResultKey)
            defaults.removeObject(forKey: Self.pendingStageKey)
            let previousAlertMode = defaults.string(forKey: Self.pendingAlertModeKey)
                .flatMap(FailureAlertMode.init(rawValue:)) ?? .notification
            defaults.removeObject(forKey: Self.pendingAlertModeKey)
            if previousAlertMode.requiresAlarm(for: outcome) {
                DispatchQueue.main.async { [weak self] in self?.presentAlarm(for: result) }
            }
        }
    }

    func prepare() {
        guard phase == .idle else { return }

        let selectedMinute = Calendar.current.dateInterval(of: .minute, for: sendDate)?.start ?? sendDate
        guard selectedMinute > .now else {
            finish("The selected time has passed. Choose a future time.")
            return
        }
        guard let selectedLateness = enteredLateness else {
            finish("Enter a valid lateness limit: 0–4 hours, 0–59 minutes, and 0–59 seconds; total 1 second to 4 hours.")
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            finish("Accessibility permission is missing. Allow autoSent in System Settings and try again.")
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
            finish("Could not keep the display awake (IOKit error \(result)). Scheduling did not start.")
            return
        }

        displayAssertion = assertion
        scheduledDate = selectedMinute
        maximumLateness = selectedLateness
        activeAlertMode = failureAlertMode
        UserDefaults.standard.set(failureAlertMode.rawValue, forKey: Self.pendingAlertModeKey)
        phase = .capturing
        markPending(.waiting)
        status = "Within 5 seconds, return to LINE and click the draft message field."

        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureDraft() }
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        guard phase != .idle else { return }
        finish("You cancelled the scheduled send before Enter was pressed.", outcome: .cancelled)
    }

    private func captureDraft() {
        guard phase == .capturing else { return }
        guard let scheduledDate, scheduledDate > .now else {
            finish("The selected time passed while preparing the send.")
            return
        }
        guard let line = NSWorkspace.shared.frontmostApplication,
              line.bundleIdentifier == lineBundleID else {
            finish("LINE was not the frontmost app when capturing the draft.")
            return
        }

        let lineAX = AXUIElementCreateApplication(line.processIdentifier)
        guard let composer = readElement(lineAX, kAXFocusedUIElementAttribute as String),
              readString(composer, kAXRoleAttribute as String) == (kAXTextAreaRole as String),
              let draft = readString(composer, kAXValueAttribute as String),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish("Could not find a LINE message field containing a draft.")
            return
        }

        guard let roomWindow = readElement(composer, kAXWindowAttribute as String)
                ?? readElement(composer, kAXTopLevelUIElementAttribute as String),
              let focusedWindow = readElement(lineAX, kAXFocusedWindowAttribute as String),
              CFEqual(roomWindow, focusedWindow) else {
            finish("Could not identify the LINE window containing the draft.")
            return
        }

        let roomTitle: String
        var selectedRoomRow: AXUIElement?
        var roomIdentifier: String?
        switch roomMode {
        case .separate:
            guard let title = readString(roomWindow, kAXTitleAttribute as String),
                  DraftGuard.isBindableRoomTitle(title) else {
                finish("The separate LINE chat window does not expose its room name through Accessibility.")
                return
            }
            roomTitle = title
        case .main:
            guard readString(roomWindow, kAXTitleAttribute as String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("LINE") == .orderedSame,
                  let selected = selectedMainRoom(in: roomWindow) else {
                finish("LINE does not expose the selected room through Accessibility. Try a separate chat window.")
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
        status = "Scheduled for \(roomTitle) • The display will stay awake while waiting."
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
            finish("The scheduled send is missing required information.")
            return
        }
        let now = Date.now
        if DraftGuard.isDueAndFresh(
            scheduledDate: scheduledDate, now: now, maximumLateness: maximumLateness.totalSeconds
        ) {
            sendOnce()
        } else if now > scheduledDate {
            finish("The Mac woke or the app resumed more than \(maximumLateness.displayText) after the scheduled time.")
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
            finish("The captured room or draft is no longer available.")
            return
        }
        clockTimer?.invalidate()
        clockTimer = nil
        phase = .sending
        status = "Scheduled time reached • Checking the LINE message field."

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
            finish("LINE is closed, its window could not be opened, or Accessibility permission was revoked.")
            return
        }

        guard AXUIElementPerformAction(snapshot.roomWindow, kAXRaiseAction as CFString) == .success else {
            finish("The captured LINE chat window was closed or could not be opened.")
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
            finish("The LINE room or message field changed, the draft was edited, or LINE is not frontmost.")
            return
        }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false) else {
            finish("Could not create the Enter key event.")
            return
        }

        guard let scheduledDate, let maximumLateness,
              DraftGuard.isDueAndFresh(
                scheduledDate: scheduledDate, now: .now, maximumLateness: maximumLateness.totalSeconds
              ) else {
            finish("The selected lateness limit was exceeded before Enter could be pressed.")
            return
        }

        // A single Return press is one key-down and one key-up event.
        markPending(.postingEnter)
        down.postToPid(snapshot.processID)
        up.postToPid(snapshot.processID)
        finish("Pressed Enter once in LINE. Delivery to the recipient cannot be confirmed.", outcome: .enterPosted)
    }

    private func markPending(_ stage: PendingStage) {
        UserDefaults.standard.set(stage.rawValue, forKey: Self.pendingStageKey)
        UserDefaults.standard.synchronize()
    }

    private func finish(_ reason: String, outcome: SendOutcome = .notPressed) {
        let shouldAlarm = activeAlertMode?.requiresAlarm(for: outcome) == true
        captureTimer?.invalidate()
        clockTimer?.invalidate()
        captureTimer = nil
        clockTimer = nil
        snapshot = nil
        scheduledDate = nil
        maximumLateness = nil
        activeAlertMode = nil
        remaining = ""
        phase = .idle
        if !shouldAlarm { releaseDisplayAssertion() }
        let result = SendResult(outcome: outcome, reason: reason, date: .now)
        lastResult = result
        status = "Ready to schedule another send."
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(result), forKey: Self.lastResultKey)
        defaults.removeObject(forKey: Self.pendingStageKey)
        defaults.removeObject(forKey: Self.pendingAlertModeKey)
        let content = UNMutableNotificationContent()
        content.title = outcome.title
        content.body = reason
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
        if shouldAlarm { presentAlarm(for: result) }
    }

    private func releaseDisplayAssertion() {
        if let displayAssertion {
            IOPMAssertionRelease(displayAssertion)
            self.displayAssertion = nil
        }
    }

    private func presentAlarm(for result: SendResult) {
        if displayAssertion == nil {
            var assertion = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "autoSent is waiting for alarm acknowledgment" as CFString,
                &assertion
            ) == kIOReturnSuccess {
                displayAssertion = assertion
            }
        }
        let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Sosumi.aiff", byReference: false)
            ?? NSSound(named: NSSound.Name("Sosumi"))
        sound?.loops = true
        alarmSound = sound
        var fallbackBeepTimer: Timer?
        if sound?.play() != true {
            NSSound.beep()
            let timer = Timer(timeInterval: 1.5, repeats: true) { _ in NSSound.beep() }
            fallbackBeepTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = result.outcome == .uncertain
            ? "Check LINE now: Enter status is uncertain"
            : "Check LINE now: Enter was not pressed"
        alert.informativeText = "\(result.displayReason)\n\nCheck the room and draft in LINE before sending manually to avoid a duplicate."
        alert.addButton(withTitle: "Acknowledge and stop alarm")
        alert.runModal()

        fallbackBeepTimer?.invalidate()
        sound?.stop()
        alarmSound = nil
        releaseDisplayAssertion()
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

    private var sendDay: Binding<Date> {
        Binding(
            get: { scheduler.sendDate },
            set: { selected in
                scheduler.sendDate = ScheduleDate.replacingDay(in: scheduler.sendDate, with: selected)
                    ?? scheduler.sendDate
            }
        )
    }

    private var sendTime: Binding<Date> {
        Binding(
            get: { scheduler.sendDate },
            set: { selected in
                scheduler.sendDate = ScheduleDate.replacingTime(in: scheduler.sendDate, with: selected)
                    ?? scheduler.sendDate
            }
        )
    }

    private func durationField(_ unit: String, accessibilityLabel: String, text: Binding<String>) -> some View {
        HStack(spacing: 5) {
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 54)
                .accessibilityLabel(accessibilityLabel)
            Text(unit)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("autoSent for LINE")
                .font(.title.bold())
            Text("Send a LINE draft with one Enter key press at the scheduled time.")
                .foregroundStyle(.secondary)

            Picker("LINE window type", selection: $scheduler.roomMode) {
                ForEach(RoomMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .disabled(scheduler.phase != .idle)

            HStack(spacing: 10) {
                Text("Send date")
                DatePicker("Send date", selection: sendDay, displayedComponents: .date)
                    .labelsHidden()
                Text("Time")
                DatePicker("Send time", selection: sendTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            .disabled(scheduler.phase != .idle)

            VStack(alignment: .leading, spacing: 7) {
                Text("Maximum lateness")
                HStack(spacing: 14) {
                    durationField("hr", accessibilityLabel: "Hours", text: $scheduler.latenessHours)
                    durationField("min", accessibilityLabel: "Minutes", text: $scheduler.latenessMinutes)
                    durationField("sec", accessibilityLabel: "Seconds", text: $scheduler.latenessSeconds)
                }
                if scheduler.enteredLateness == nil {
                    Text("Enter 0–4 hr, 0–59 min, and 0–59 sec; total 1 second to 4 hours.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .disabled(scheduler.phase != .idle)

            Picker("If Enter cannot be pressed", selection: $scheduler.failureAlertMode) {
                ForEach(FailureAlertMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(scheduler.phase != .idle)

            if scheduler.phase == .armed {
                Text("Time remaining: \(scheduler.remaining)")
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
            }

            Text(scheduler.status)
                .fixedSize(horizontal: false, vertical: true)

            if let result = scheduler.lastResult {
                Divider()
                Text("Last result • \(result.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US"))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.outcome.title)
                    .font(.headline)
                Text(result.displayReason)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if scheduler.phase == .idle {
                    Button("Schedule send") { scheduler.prepare() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { scheduler.cancel() }
                        .disabled(scheduler.phase == .sending)
                }
                Spacer()
            }

            Text("Match the LINE window and prepare the draft first • Do not change rooms or edit the draft after scheduling • Sends beyond the lateness limit are cancelled")
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
                .environment(\.locale, Locale(identifier: "en_US"))
        }
        .windowResizability(.contentSize)
    }
}

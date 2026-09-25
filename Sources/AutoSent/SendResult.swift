import Foundation

enum SendOutcome: String, Codable {
    case notPressed
    case enterPosted
    case cancelled
    case uncertain

    var title: String {
        switch self {
        case .notPressed: return "Enter was not pressed"
        case .enterPosted: return "Enter was pressed"
        case .cancelled: return "Cancelled before pressing Enter"
        case .uncertain: return "Enter status is uncertain"
        }
    }
}

struct SendResult: Codable, Equatable {
    let outcome: SendOutcome
    let reason: String
    let date: Date

    var summary: String { "\(outcome.title): \(displayReason)" }

    var displayReason: String {
        let olderReasons: [String: String] = [
            "แอปหยุดทำงานหรือเครื่องเริ่มใหม่ก่อนกด Enter; งานเดิมไม่ทำงานต่อ": "The app stopped or the Mac restarted before Enter was pressed. The scheduled send will not resume.",
            "แอปหยุดทำงานขณะโพสต์ปุ่ม Enter; กรุณาตรวจใน LINE ก่อนส่งเอง": "The app stopped while pressing Enter. Check LINE before sending manually to avoid a duplicate.",
            "เวลาที่เลือกผ่านไปแล้ว กรุณาเลือกเวลาในอนาคต": "The selected time has passed. Choose a future time.",
            "ช่วงส่งช้าต้องอยู่ระหว่าง 1 ถึง 240 นาที": "The lateness limit must be between 1 and 240 minutes.",
            "ช่วงส่งช้าต้องเป็นตัวเลข: ชั่วโมง 0–4 นาทีและวินาที 0–59 รวมอย่างน้อย 1 วินาทีและไม่เกิน 4 ชั่วโมง": "Enter a valid lateness limit: 0–4 hours, 0–59 minutes, and 0–59 seconds; total 1 second to 4 hours.",
            "ยังไม่ได้รับสิทธิ์ Accessibility; เปิดให้ autoSent ใน System Settings แล้วลองใหม่": "Accessibility permission is missing. Allow autoSent in System Settings and try again.",
            "ผู้ใช้ยกเลิกงานก่อนกด Enter": "You cancelled the scheduled send before Enter was pressed.",
            "เวลาที่เลือกผ่านไปแล้วระหว่างเตรียมส่ง": "The selected time passed while preparing the send.",
            "ตอนจับร่าง LINE ไม่ใช่แอปที่อยู่ด้านหน้า": "LINE was not the frontmost app when capturing the draft.",
            "ไม่พบช่องพิมพ์ LINE ที่มีข้อความร่าง": "Could not find a LINE message field containing a draft.",
            "ระบุหน้าต่าง LINE ที่กำลังพิมพ์ไม่ได้": "Could not identify the LINE window containing the draft.",
            "หน้าต่างแชตแยกไม่แสดงชื่อห้องผ่าน Accessibility": "The separate LINE chat window does not expose its room name through Accessibility.",
            "LINE ไม่เปิดเผยรายการห้องที่เลือกผ่าน Accessibility; ลองใช้หน้าต่างแชตแยก": "LINE does not expose the selected room through Accessibility. Try a separate chat window.",
            "ข้อมูลงานที่ตั้งไว้ไม่ครบ": "The scheduled send is missing required information.",
            "ไม่พบข้อมูลห้องและข้อความร่างที่จับไว้": "The captured room or draft is no longer available.",
            "LINE ปิดไปแล้ว เปิดหน้าต่างไม่ได้ หรือสิทธิ์ Accessibility ถูกปิด": "LINE is closed, its window could not be opened, or Accessibility permission was revoked.",
            "หน้าต่างห้อง LINE ที่จับไว้ปิดไปแล้วหรือเปิดไม่ได้": "The captured LINE chat window was closed or could not be opened.",
            "ห้อง LINE/ช่องพิมพ์เปลี่ยน ข้อความร่างถูกแก้ หรือ LINE ไม่อยู่ด้านหน้า": "The LINE room or message field changed, the draft was edited, or LINE is not frontmost.",
            "สร้างปุ่ม Enter ไม่สำเร็จ": "Could not create the Enter key event.",
            "เลยเวลาที่ตั้งไว้เกินช่วงส่งช้าที่เลือกก่อนกด Enter": "The selected lateness limit was exceeded before Enter could be pressed.",
            "โพสต์ปุ่ม Enter หนึ่งครั้งไปยัง LINE; ยังยืนยันการส่งถึงผู้รับไม่ได้": "Pressed Enter once in LINE. Delivery to the recipient cannot be confirmed."
        ]
        if let translated = olderReasons[reason] { return translated }
        if reason.hasPrefix("กันหน้าจอดับไม่ได้ (IOKit error "), reason.hasSuffix(") จึงไม่เริ่มตั้งเวลา") {
            let code = reason.dropFirst("กันหน้าจอดับไม่ได้ (IOKit error ".count)
                .dropLast(") จึงไม่เริ่มตั้งเวลา".count)
            return "Could not keep the display awake (IOKit error \(code)). Scheduling did not start."
        }
        if reason.hasPrefix("เครื่องตื่นหรือแอปทำงานช้ากว่าเวลาที่ตั้งไว้เกิน ") {
            let interval = String(reason.dropFirst("เครื่องตื่นหรือแอปทำงานช้ากว่าเวลาที่ตั้งไว้เกิน ".count))
                .replacingOccurrences(of: " ชม.", with: " hr")
                .replacingOccurrences(of: " นาที", with: " min")
                .replacingOccurrences(of: " วิ", with: " sec")
            return "The Mac woke or the app resumed more than \(interval) after the scheduled time."
        }
        return reason
    }
}

enum PendingStage: String {
    case waiting
    case postingEnter
}

enum AlarmJournal {
    static let lastResultKey = "autoSent.lastResult"
    static let pendingStageKey = "autoSent.pendingStage"
    static let pendingAlertModeKey = "autoSent.pendingAlertMode"
    private static let unacknowledgedAlarmKey = "autoSent.unacknowledgedAlarm"

    static func lastResult(in defaults: UserDefaults) -> SendResult? {
        decodeResult(forKey: lastResultKey, in: defaults)
    }

    static func unacknowledgedResult(in defaults: UserDefaults) -> SendResult? {
        decodeResult(forKey: unacknowledgedAlarmKey, in: defaults)
    }

    static func record(_ result: SendResult, needsAlarm: Bool, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        defaults.set(data, forKey: lastResultKey)
        if needsAlarm {
            defaults.set(data, forKey: unacknowledgedAlarmKey)
        }
        // Persist the alarm before removing the crash-recovery keys.
        guard defaults.synchronize() else { return }
        clearPending(in: defaults)
    }

    static func clearPending(in defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingStageKey)
        defaults.removeObject(forKey: pendingAlertModeKey)
        defaults.synchronize()
    }

    static func acknowledge(in defaults: UserDefaults) {
        defaults.removeObject(forKey: unacknowledgedAlarmKey)
        defaults.synchronize()
    }

    private static func decodeResult(forKey key: String, in defaults: UserDefaults) -> SendResult? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SendResult.self, from: data)
    }
}

enum FailureAlertMode: String, CaseIterable, Identifiable {
    case notification
    case alarm

    var id: Self { self }

    var title: String {
        switch self {
        case .notification: return "Standard notification"
        case .alarm: return "Alarm until acknowledged"
        }
    }

    func requiresAlarm(for outcome: SendOutcome) -> Bool {
        self == .alarm && (outcome == .notPressed || outcome == .uncertain)
    }
}

import Foundation

enum SendOutcome: String, Codable {
    case notPressed
    case enterPosted
    case cancelled
    case uncertain

    var title: String {
        switch self {
        case .notPressed: return "ยังไม่ได้กด Enter"
        case .enterPosted: return "โพสต์ปุ่ม Enter แล้ว"
        case .cancelled: return "ยกเลิกก่อนกด Enter"
        case .uncertain: return "สถานะการกด Enter ไม่แน่ชัด"
        }
    }
}

struct SendResult: Codable, Equatable {
    let outcome: SendOutcome
    let reason: String
    let date: Date

    var summary: String { "\(outcome.title): \(reason)" }
}

enum PendingStage: String {
    case waiting
    case postingEnter
}

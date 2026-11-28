import Foundation

struct CareLine: Decodable {
    let id: String
    let text: String
}

struct GreetingSchedule {
    var calendar = Calendar.autoupdatingCurrent
    private var waitingForReturn = true

    func day(_ date: Date) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year!, values.month!, values.day!)
    }

    mutating func awaitReturn() {
        waitingForReturn = true
    }

    // Midnight alone does not start a new computer session.
    mutating func shouldGreet(at date: Date, greetedDays: [String], available: Bool) -> Bool {
        guard available else {
            waitingForReturn = true
            return false
        }
        guard waitingForReturn else { return false }
        waitingForReturn = false
        return !greetedDays.contains(day(date))
    }
}

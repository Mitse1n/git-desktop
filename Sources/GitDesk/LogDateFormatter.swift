import Foundation

/// Swift equivalent of IDEA DateFormatUtil.formatPrettyDateTime's defaults.
/// Kept on the controller's main thread; reuse the native date formatters.
final class LogDateFormatter {
  private let time = DateFormatter()
  private let dateTime = DateFormatter()
  init() {
    for formatter in [time, dateTime] { formatter.locale = Locale(identifier: "en_US_POSIX") }
    time.dateFormat = "HH:mm"
    dateTime.dateFormat = "yyyy/M/d HH:mm"
  }
  func absolute(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
    dateTime.timeZone = calendar.timeZone
    return dateTime.string(from: date)
  }
  func string(_ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
    guard date.timeIntervalSince1970 >= 0 else { return "" }
    let elapsed = now.timeIntervalSince(date)
    if elapsed >= 0 && elapsed <= 61 * 60 {
      // Java Math.rint uses ties-to-even, including the 30-second boundary.
      let minutes = Int((elapsed / 60).rounded(.toNearestOrEven))
      if minutes == 0 { return "Moments ago" }
      if minutes == 1 { return "A minute ago" }
      if minutes >= 60 { return "1 hour ago" }
      return "\(minutes) minutes ago"
    }
    time.timeZone = calendar.timeZone
    if calendar.isDate(date, inSameDayAs: now) { return "Today " + time.string(from: date) }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday " + time.string(from: date) }
    return absolute(date, calendar: calendar)
  }
}

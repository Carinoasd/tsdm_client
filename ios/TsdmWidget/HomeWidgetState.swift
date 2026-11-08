import Foundation

/// What the home screen widget shows: the account in use and its unread counts, and the day it checked in.
///
/// Compiled into both the app (`HomeWidgetBridge` writes it) and the widget extension (`TsdmWidget` reads it); the
/// two share it through the App Group's user defaults. The same state as Android's `HomeWidgetState`:
///
/// * a count is [unknownCount] while nothing counted for this account yet (right after a switch to it): the widget
///   shows a dash rather than a zero that is not true;
/// * [checkedInDay] is the device-local day (`yyyy-MM-dd`) of the check-in Dart last told, nil when it told "not
///   checked in": the widget compares it with the day it draws on, so yesterday's check-in is over at midnight without
///   the app saying anything.
struct HomeWidgetState: Equatable {
  /// The App Group both the app and the extension are entitled to.
  static let appGroup = "group.com.tsdm.tsdmClient"

  /// The kind of the widget, to reload its timelines.
  static let widgetKind = "TsdmHomeWidget"

  static let unknownCount = -1

  static let empty = HomeWidgetState(uid: nil, notice: 0, personalMessage: 0, checkedInDay: nil)

  var uid: Int?
  var notice: Int
  var personalMessage: Int
  var checkedInDay: String?

  var loggedIn: Bool { uid != nil }

  /// Whether the check-in is of the day of [date].
  func checkedIn(on date: Date) -> Bool {
    guard let day = checkedInDay else { return false }
    return day == HomeWidgetState.isoDay(date)
  }

  /// The device-local day of [date] as Dart writes it (`HomeWidgetSyncCubit.isoDay`), always in the Gregorian
  /// calendar whatever calendar the device uses.
  static func isoDay(_ date: Date) -> String {
    let parts = gregorian.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// The local midnight that starts the day after [date].
  static func nextMidnight(after date: Date) -> Date {
    let start = gregorian.startOfDay(for: date)
    return gregorian.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(24 * 60 * 60)
  }

  private static var gregorian: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar
  }

  private enum Key {
    static let uid = "uid"
    static let notice = "notice"
    static let personalMessage = "personalMessage"
    static let checkedInDay = "checkedInDay"
  }

  private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

  static func read() -> HomeWidgetState {
    guard let defaults = defaults else { return .empty }
    let uid = defaults.integer(forKey: Key.uid)
    return HomeWidgetState(
      uid: uid > 0 ? uid : nil,
      notice: defaults.object(forKey: Key.notice) as? Int ?? 0,
      personalMessage: defaults.object(forKey: Key.personalMessage) as? Int ?? 0,
      checkedInDay: defaults.string(forKey: Key.checkedInDay)
    )
  }

  func write() {
    guard let defaults = HomeWidgetState.defaults else { return }
    defaults.set(uid ?? 0, forKey: Key.uid)
    defaults.set(notice, forKey: Key.notice)
    defaults.set(personalMessage, forKey: Key.personalMessage)
    if let day = checkedInDay {
      defaults.set(day, forKey: Key.checkedInDay)
    } else {
      defaults.removeObject(forKey: Key.checkedInDay)
    }
  }
}

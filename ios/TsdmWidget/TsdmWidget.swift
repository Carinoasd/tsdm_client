import SwiftUI
import UIKit
import WidgetKit

/// The home screen widget: the unread notice and personal message counts of the account in use and whether it
/// checked in today, the iOS counterpart of Android's `HomeWidgetProvider`.
///
/// It draws what the app stored in the App Group ([HomeWidgetState], written by `HomeWidgetBridge`), which reloads
/// the timeline after every change. Taps open the `tsdm://shortcut/<id>` links the app takes like the Android
/// shortcuts: the check-in while not checked in yet, the notices otherwise. A small widget is one tap target, so it
/// checks in until checked in; a medium one has the check-in cell as its own link.
///
/// "Checked in" is a day compared with the entry's date, and every timeline has one more entry just after the next
/// local midnight: yesterday's check-in is then over on the widget without the app saying anything.
@main
struct TsdmWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: HomeWidgetState.widgetKind, provider: HomeWidgetProvider()) { entry in
      HomeWidgetView(entry: entry)
    }
    .configurationDisplayName(HomeWidgetText.title)
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct HomeWidgetEntry: TimelineEntry {
  let date: Date
  let state: HomeWidgetState
}

struct HomeWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> HomeWidgetEntry {
    HomeWidgetEntry(date: Date(), state: HomeWidgetState(uid: 1, notice: 0, personalMessage: 0, checkedInDay: nil))
  }

  func getSnapshot(in context: Context, completion: @escaping (HomeWidgetEntry) -> Void) {
    completion(HomeWidgetEntry(date: Date(), state: HomeWidgetState.read()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<HomeWidgetEntry>) -> Void) {
    let now = Date()
    let state = HomeWidgetState.read()
    let afterMidnight = HomeWidgetState.nextMidnight(after: now).addingTimeInterval(5)
    let entries = [
      HomeWidgetEntry(date: now, state: state),
      HomeWidgetEntry(date: afterMidnight, state: state),
    ]
    completion(Timeline(entries: entries, policy: .after(afterMidnight)))
  }
}

/// The links the app takes, same as `AppShortcut.link` in Dart.
enum HomeWidgetLink {
  static let checkin = URL(string: "tsdm://shortcut/checkin")!
  static let notice = URL(string: "tsdm://shortcut/notice")!
}

/// The widget's words, in the language of the device: simplified Chinese unless English or traditional Chinese, like
/// the Android strings.
enum HomeWidgetText {
  private enum Language {
    case simplified
    case traditional
    case english
  }

  private static var language: Language {
    let preferred = (Locale.preferredLanguages.first ?? "").lowercased()
    if preferred.hasPrefix("en") {
      return .english
    }
    if preferred.hasPrefix("zh")
      && (preferred.contains("hant") || preferred.contains("-tw") || preferred.contains("-hk")
        || preferred.contains("-mo"))
    {
      return .traditional
    }
    return .simplified
  }

  private static func pick(_ simplified: String, _ traditional: String, _ english: String) -> String {
    switch language {
    case .simplified: return simplified
    case .traditional: return traditional
    case .english: return english
    }
  }

  static var title: String { pick("签到与消息", "簽到與訊息", "Check-in and messages") }
  static var notice: String { pick("通知", "通知", "Notices") }
  static var personalMessage: String { pick("私信", "私訊", "Messages") }
  static var checkedIn: String { pick("已签到", "已簽到", "Checked in") }
  static var notCheckedIn: String { pick("未签到", "未簽到", "Not checked in") }
}

struct HomeWidgetView: View {
  @Environment(\.widgetFamily) private var family

  let entry: HomeWidgetEntry

  /// The most a count shows; the exact number is in the app.
  private static let countCap = 99

  private var checked: Bool { entry.state.loggedIn && entry.state.checkedIn(on: entry.date) }

  var body: some View {
    content
      .widgetURL(family == .systemSmall && !checked ? HomeWidgetLink.checkin : HomeWidgetLink.notice)
      .homeWidgetBackground()
  }

  @ViewBuilder
  private var content: some View {
    if family == .systemSmall {
      small
    } else {
      medium
    }
  }

  private var small: some View {
    VStack(alignment: .leading, spacing: 8) {
      smallRow(HomeWidgetText.notice, count(entry.state.notice))
      smallRow(HomeWidgetText.personalMessage, count(entry.state.personalMessage))
      Spacer(minLength: 0)
      checkin
        .frame(maxWidth: .infinity)
    }
    .padding(4)
  }

  private func smallRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(value)
        .font(.title2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
  }

  private var medium: some View {
    HStack(spacing: 8) {
      countCell(HomeWidgetText.notice, count(entry.state.notice))
      countCell(HomeWidgetText.personalMessage, count(entry.state.personalMessage))
      if checked {
        checkin
          .frame(maxWidth: .infinity)
      } else {
        Link(destination: HomeWidgetLink.checkin) {
          checkin
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private func countCell(_ label: String, _ value: String) -> some View {
    VStack(spacing: 2) {
      Text(value)
        .font(.title.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text(label)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }

  /// The check-in: a pill while it is a button, flat once checked in.
  private var checkin: some View {
    VStack(spacing: 2) {
      Image(systemName: checked ? "checkmark.circle.fill" : "calendar.badge.plus")
        .font(.title3)
        .foregroundColor(checked ? Color.green : Color.accentColor)
      Text(checked ? HomeWidgetText.checkedIn : HomeWidgetText.notCheckedIn)
        .font(.caption)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(checked ? Color.clear : Color.accentColor.opacity(0.15))
    )
  }

  /// A count; a dash without an account and while the count is not known ([HomeWidgetState.unknownCount]).
  private func count(_ value: Int) -> String {
    if !entry.state.loggedIn || value < 0 {
      return "–"
    }
    if value > HomeWidgetView.countCap {
      return "\(HomeWidgetView.countCap)+"
    }
    return String(value)
  }
}

extension View {
  /// The widget's background: the container background from iOS 17 on, a plain one before.
  @ViewBuilder
  func homeWidgetBackground() -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(for: .widget) {
        Color(UIColor.systemBackground)
      }
    } else {
      padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }
  }
}

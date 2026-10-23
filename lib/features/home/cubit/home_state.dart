part of 'home_cubit.dart';

/// All tabs in homepage of the app.
///
/// Not the homepage of website nor the [home] tab.
enum HomeTab {
  /// Homepage of the forum website except forum list/groups part.
  ///
  /// Provides data fetched from baseUrl.
  home,

  /// All top-level forums showed in homepage with forum group.
  topic,

  /// Notifications of the account in use: notices, private messages and broadcast messages.
  notice,

  /// The account in use and its pages (threads, favorites, history, messages...), the settings and about the app.
  me,
}

/// State of the homepage of the app.
@MappableClass()
final class HomeState with HomeStateMappable {
  /// Constructor.
  const HomeState({this.tab = HomeTab.home, this.inHome});

  /// Current tab.
  final HomeTab tab;

  /// Flag indicating whether current in home tab.
  ///
  /// Some behavior changes due to this flag, for example whether scroll the
  /// welcome swiper in home tab.
  final bool? inHome;
}

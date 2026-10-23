part of 'homepage_bloc.dart';

/// All events happen in HomepagePage.
@MappableClass()
sealed class HomepageEvent with HomepageEventMappable {
  const HomepageEvent();
}

/// User request to load the homepage.
///
/// This will load from cache if available.
@MappableClass()
final class HomepageLoadRequested extends HomepageEvent with HomepageLoadRequestedMappable {}

/// User requests to refresh homepage.
///
/// Directly load homepage from server.
@MappableClass()
final class HomepageRefreshRequested extends HomepageEvent with HomepageRefreshRequestedMappable {
  /// Constructor.
  HomepageRefreshRequested({this.userLoginInfo});

  /// Optional user login info to specify who's homepage to refresh.
  UserLoginInfo? userLoginInfo;
}

/// User asks whether today's daily red packet is offered now, from its entry on the loaded homepage.
///
/// Only the packet and the form hash are updated; the loaded page stays on screen, no loading state, and a refresh or
/// an account change meanwhile wins over the answer.
@MappableClass()
final class HomepageDailyRedPacketCheckRequested extends HomepageEvent
    with HomepageDailyRedPacketCheckRequestedMappable {
  /// Constructor.
  const HomepageDailyRedPacketCheckRequested();
}

/// User requests to login.
@MappableClass()
final class HomepageLoginRequested extends HomepageEvent with HomepageLoginRequestedMappable {}

/// Current logged user changed.
///
/// This is a passive event.
@MappableClass()
final class HomepageAuthChanged extends HomepageEvent with HomepageAuthChangedMappable {
  /// Constructor.
  const HomepageAuthChanged({required this.prev, required this.curr}) : super();

  /// Previous status.
  final AuthStatus? prev;

  /// Current status.
  final AuthStatus curr;
}

/// The page shown was replaced in the background by the page asked once more after the daily rewards (a new balance,
/// the claimed packet gone, `ForumHomeRepository.pageReplacements`).
@MappableClass()
final class HomepagePageReplaced extends HomepageEvent with HomepagePageReplacedMappable {
  /// Constructor.
  const HomepagePageReplaced({required this.previous, required this.page});

  /// The page replaced.
  final ForumHomePage previous;

  /// The page replacing it.
  final ForumHomePage page;
}

/// Pause the swiper scrolling.
@MappableClass()
final class HomepagePauseSwiper extends HomepageEvent with HomepagePauseSwiperMappable {
  /// Constructor.
  const HomepagePauseSwiper();
}

/// Resume the swiper scrolling.
@MappableClass()
final class HomepageResumeSwiper extends HomepageEvent with HomepageResumeSwiperMappable {
  /// Constructor.
  const HomepageResumeSwiper();
}

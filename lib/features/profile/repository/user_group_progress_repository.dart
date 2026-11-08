import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/user_group_progress.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Reads how far the current account is from the next credit-based user group.
///
/// The forum has no app API for it (the plugin answers the web page as it is), so the group comparison page
/// `home.php?mod=spacecp&ac=usergroup` is parsed ([UserGroupPage]): without `gid` it is about the next group of the
/// account (and says how many credits are missing), with `gid` about that group (and says where it starts). Every
/// page names the account it was served to, which must be the one asked for ([IdentityChangedException] otherwise).
final class UserGroupProgressRepository {
  /// Constructor; [currentUid] tells the account the progress is asked for (the logged in account by default).
  UserGroupProgressRepository({int Function()? currentUid}) : _currentUid = currentUid ?? currentLoginUid;

  final int Function() _currentUid;

  static const _pageUrl = '$baseUrl/home.php?mod=spacecp&ac=usergroup';

  AsyncEither<UserGroupPage> _fetch({int? gid}) => AsyncEither(() async {
    final uid = _currentUid();
    final response = await getIt.get<NetClientProvider>().get(gid == null ? _pageUrl : '$_pageUrl&gid=$gid').run();
    return response.flatMap((resp) {
      if (resp.statusCode != 200) {
        return left<AppException, UserGroupPage>(HttpRequestFailedException(resp.statusCode));
      }
      final page = UserGroupPage.parse('${resp.data}');
      if (page == null) {
        return left<AppException, UserGroupPage>(ServerRespondedErrorException('user group page not recognized'));
      }
      if (uid <= 0 || page.uid != uid || _currentUid() != uid) {
        return left<AppException, UserGroupPage>(IdentityChangedException());
      }
      return right<AppException, UserGroupPage>(page);
    });
  });

  /// The credits [page] says its viewed group starts at.
  static int? _from(UserGroupPage? page) => page?.viewedThreshold;

  /// The progress of the account towards its next group, null when it has none (a special group, or the highest one).
  ///
  /// Two pages: the account's own, and the one of its current group for the credits that group starts at.
  AsyncEither<UserGroupProgress?> fetchProgress() => AsyncEither(() async {
    final own = await _fetch().run();
    switch (own) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        final next = _nextOf(value);
        if (next == null) {
          return right(null);
        }
        final currentGid = _currentGid(value);
        int? currentFrom;
        if (currentGid != null) {
          // A failure of this page only costs the start of the bar; the account changing is still an error.
          switch (await _fetch(gid: currentGid).run()) {
            case Left(:final value) when value is IdentityChangedException:
              return left(value);
            case Left():
              break;
            case Right(:final value):
              currentFrom = _from(value);
          }
        }
        return right(
          UserGroupProgress(
            mainGroupName: value.mainGroupName,
            credits: value.credits,
            currentFrom: currentFrom,
            nextName: next.name,
            nextFrom: next.from,
          ),
        );
    }
  });

  /// The progress with every credit-based group and the member's other groups: a page per group.
  AsyncEither<UserGroupProgress?> fetchDetail() => AsyncEither(() async {
    switch (await _fetch().run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        final next = _nextOf(value);
        if (next == null) {
          return right(null);
        }
        final pages = await Future.wait(value.memberGroups.map((g) => _fetch(gid: g.gid).run()));
        final tiers = <UserGroupTier>[];
        for (final (i, result) in pages.indexed) {
          switch (result) {
            case Left(:final value) when value is IdentityChangedException:
              return left(value);
            case Left():
              // A group whose page failed is left out of the table.
              break;
            case Right(value: final page):
              if (_from(page) case final from?) {
                tiers.add(
                  UserGroupTier(gid: value.memberGroups[i].gid, name: value.memberGroups[i].name, creditsFrom: from),
                );
              }
          }
        }
        tiers.sort((a, b) => a.creditsFrom.compareTo(b.creditsFrom));
        final currentGid = _currentGid(value);
        final currentFrom = tiers.where((t) => t.gid == currentGid).firstOrNull?.creditsFrom;
        return right(
          UserGroupProgress(
            mainGroupName: value.mainGroupName,
            credits: value.credits,
            currentFrom: currentFrom,
            currentGid: currentGid,
            nextName: next.name,
            nextFrom: next.from,
            tiers: tiers,
            extraGroups: [for (final g in value.extraGroups) g.name],
          ),
        );
    }
  });

  /// The next group and where it starts, null when [page] has no group below its comparison (see [fetchProgress]).
  static ({String name, int from})? _nextOf(UserGroupPage page) {
    final name = page.viewedGroupName;
    final from = page.viewedThreshold;
    if (name == null || from == null) {
      return null;
    }
    return (name: name, from: from);
  }

  /// The group id of the account's main group: the menu entry of its name, else the one before the next group.
  static int? _currentGid(UserGroupPage page) {
    final groups = page.memberGroups;
    final byName = groups.where((g) => g.name == page.mainGroupName).firstOrNull;
    if (byName != null) {
      return byName.gid;
    }
    final nextIndex = groups.indexWhere((g) => g.gid == page.viewedGid);
    return nextIndex > 0 ? groups[nextIndex - 1].gid : null;
  }
}

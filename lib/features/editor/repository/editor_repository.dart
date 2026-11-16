import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The forum's emoji list (`data/cache/common_smilies_var.js`) asked in the background: one request at a time for
/// the emoji panel and the editor together, saved when it changed.
///
/// * The emoji panel shows the list on this device at once and asks the forum for its list once a run ([refresh]):
///   a group the forum added shows, an emoji it removed goes. A failure says nothing; the next run asks again.
/// * The editor shows the forum's emoji of an old draft or a quote before the emoji panel ever loaded the list
///   ([ensure]): fetched once a run (the emoji stay their code when it fails; the emoji panel tries again on its own
///   when opened). An emoji the list on this device has not (a group added later) waits for [refresh].
abstract final class EmojiListInBackground {
  /// The request running now.
  static Future<List<EmojiGroup>?>? _request;

  /// The forum's list was asked in this run (and arrived), or a refresh was tried: not asked again in the background.
  static var _asked = false;

  /// [ensure] failed in this run.
  static var _failed = false;

  static NetClientProvider? _clientOr(NetClientProvider? client) =>
      client ??
      (getIt.isRegistered<NetClientProvider>(instanceName: ServiceKeys.noCookie)
          ? getIt.get<NetClientProvider>(instanceName: ServiceKeys.noCookie)
          : null);

  /// The forum's list, asked now unless a request is running already (its answer then); saved in [cache] when it has
  /// emoji and is not the list there ([sameEmojiList]). Null when it could not be had.
  static Future<List<EmojiGroup>?> fetch(ImageCacheProvider cache, {NetClientProvider? client}) {
    final running = _request;
    if (running != null) {
      return running;
    }
    final netClient = _clientOr(client);
    if (!cache.emojiCacheReady || netClient == null) {
      return Future.value();
    }
    return _request = () async {
      // Not the repository of a panel: closing the panel must not stop the request others wait for.
      final repository = EditorRepository(netClientProvider: netClient, imageCacheProvider: cache);
      try {
        final groups = await repository._fetchEmojiList();
        if (groups == null) {
          return null;
        }
        _asked = true;
        final saved = await cache.loadEmojiInfo();
        if (saved == null || !sameEmojiList(saved, groups)) {
          await cache.saveEmojiInfo(groups);
        }
        return groups;
      } on Exception catch (e) {
        talker.handle(e);
        return null;
      } finally {
        repository.dispose();
        _request = null;
      }
    }();
  }

  /// The forum's list for a device that has one already: asked once a run (the request running now, if any, is
  /// shared). Null when it was asked before in this run or could not be had.
  static Future<List<EmojiGroup>?> refresh(ImageCacheProvider cache, {NetClientProvider? client}) {
    final running = _request;
    if (running != null) {
      return running;
    }
    if (_asked) {
      return Future.value();
    }
    _asked = true;
    return fetch(cache, client: client);
  }

  /// Whether the emoji list is in [cache] ([ImageCacheProvider.hasEmojiList]), fetched now when it is not and no
  /// fetch failed in this run; callers at the same time share one fetch.
  static Future<bool> ensure(ImageCacheProvider cache) async {
    if (!cache.emojiCacheReady || _clientOr(null) == null) {
      return false;
    }
    if (await cache.hasEmojiList()) {
      return true;
    }
    if (_failed) {
      return false;
    }
    final groups = await fetch(cache);
    _failed = groups == null;
    return groups != null;
  }

  /// Forget the fetches of this run.
  @visibleForTesting
  static void reset() {
    _request = null;
    _asked = false;
    _failed = false;
  }
}

/// Whether [a] and [b] are the same group: name, place and its emoji in the same order. The url of an image is not
/// compared, only where it is ([ImageCacheProvider.emojiImageKeyOf]): an older version saved them on the image host.
bool sameEmojiGroup(EmojiGroup a, EmojiGroup b) {
  if (a.id != b.id || a.name != b.name || a.routeName != b.routeName || a.emojiList.length != b.emojiList.length) {
    return false;
  }
  for (var i = 0; i < a.emojiList.length; i++) {
    final x = a.emojiList[i];
    final y = b.emojiList[i];
    if (x.id != y.id ||
        x.code != y.code ||
        (ImageCacheProvider.emojiImageKeyOf(x.url) ?? x.url) != (ImageCacheProvider.emojiImageKeyOf(y.url) ?? y.url)) {
      return false;
    }
  }
  return true;
}

/// Whether the lists [a] and [b] are the same groups in the same order ([sameEmojiGroup]).
bool sameEmojiList(List<EmojiGroup> a, List<EmojiGroup> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (!sameEmojiGroup(a[i], b[i])) {
      return false;
    }
  }
  return true;
}

/// The repository of bbcode editor features injected into bbcode editor.
///
/// Provide materials including:
/// * Emoji
///
final class EditorRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [netClientProvider] fetches the emoji list (a client without cookies by default), [imageCacheProvider] keeps the
  /// emoji (the app's by default).
  EditorRepository({NetClientProvider? netClientProvider, ImageCacheProvider? imageCacheProvider})
    : _netClientProvider = netClientProvider,
      _imageCacheProvider = imageCacheProvider;

  final NetClientProvider? _netClientProvider;

  final ImageCacheProvider? _imageCacheProvider;

  /// Url to fetch all available emoji info.
  ///
  /// It's a one-line javascript file expected in the following format:
  ///
  /// ``` javascript
  /// ...
  /// var smilies_type = new Array()
  /// smilies_type = new Array()
  /// smilies_type['_${GROUP_ID}'] = ['${GROUP_NAME}', '${GROUP_ROUTE_NAME}']
  /// (repeat above line ...)
  /// var smilies_array = new Array()
  /// var smilies_fast = new Array()
  /// smilies_array[${GROUP_ID}] = new Array()
  /// smilies_array[${GROUP_ID}][${PAGE_NUMBER}] =
  ///   [['${EMOJI_ID}','${BBCODE}','${FILE_NAME}','20','${WIDTH}','${HEIGHT}']]
  /// ...
  /// ```
  ///
  /// All data we need to save:
  ///
  /// * GROUP_ID: Emoji group id. Also the first part of emoji bbcode like
  ///   "10" in "{:10_200:}".
  /// * GROUP_NAME: Human readable emoji group name.
  /// * GROUP_ROUTE_NAME: A part of the route we fetch the emoji image. For
  ///   example: In https://www.tsdm39.com/static/image/smiley/TSDM/9.jpg the
  ///   "TSDM" is the group route name.
  /// * PAGE_NUMBER: Page number of the emoji in group when display in browser.
  ///   Optional because we provides a different layout and this parameter is
  ///   not required.
  /// * EMOJI_ID: The emoji id in group. Like the "200" in BBCode "{:10_200:}".
  /// * BBCODE: Used in editor and represent the emoji when send data to server.
  ///   Also formatted like "{:${GROUP_ID}_${EMOJI_ID}:}".
  /// * FILE_NAME: the final file name in url when we fetch the emoji image. We
  ///   don't name cache with this value.
  static const _emojiInfoUrl = '$baseUrl/data/cache/common_smilies_var.js';

  /// Expected to match data:
  ///
  /// smilies_type['_12'] = ['梦予馨', 'TSDM']
  ///
  /// Matches:
  /// * groupId: 12
  /// * groupName: 梦予馨
  /// * routeName: TSDM
  static final _emojiGroupInfoRe = RegExp(
    r"smilies_type\['_(?<groupId>\d+)'\] = \['(?<groupName>[^']+)', '(?<routeName>[^']+)'\]",
  );

  /// Expected to match data:
  ///
  /// smilies_array[1][1] = [['1', '{:1_1:}','smile.gif','20','20','20'],['2', ':(','sad.gif','20','20','20']];
  ///
  /// Note that bbcode of emoji in the default group may contain ";" (e.g. ";P") so the whole file can NOT be split
  /// into statements by ";". Match till the end of the array "];" instead.
  ///
  /// Groups may be empty: `smilies_array[12][1] = [];`
  static final _emojiGroupDataRe = RegExp(r'smilies_array\[(?<groupId>\d+)\]\[\d+\] = \[(?<data>.*?)\];');

  /// Placeholder of escaped single quote in bbcode (e.g. `':\'('`) when splitting emoji data.
  static const _escapedQuotePlaceholder = '\u0001';

  /// Url of the official `@` user list: the usernames the current user may mention, comma separated in CDATA.
  static const _atUserListUrl = '$baseUrl/misc.php?mod=getatuser&inajax=1';

  /// `@` user list cached for this repository instance.
  List<String>? _atUsers;

  /// Flag used to indicate whether repository should be closed or not.
  /// If so, stop all actions still runings.
  var _disposed = false;

  /// Call this function to notify the repository instance to stop all actions
  /// still running.
  ///
  /// This can prevent further unstopped background jobs.
  void dispose() {
    _disposed = true;
  }

  /// All groups of emoji.
  ///
  /// TODO: Do not use the type in code editor.
  /// Here we should use our own emoji group type.
  List<EmojiGroup>? emojiGroupList;

  /// Parse emoji info fetched from [_emojiInfoUrl] into a list of [EmojiGroup].
  ///
  /// The input [info] is expected in format described above [_emojiInfoUrl]
  /// document.
  List<EmojiGroup> _parseEmojiInfo(String info) {
    // Key: group id.
    // Value: group.
    final emojiGroupMap = <String, EmojiGroup>{};

    // Parse group info: smilies_type['_12'] = ['梦予馨', 'TSDM']
    for (final m in _emojiGroupInfoRe.allMatches(info)) {
      if (_disposed) {
        // Closed, it's ok to return nothing.
        return [];
      }
      emojiGroupMap[m.namedGroup('groupId')!] = EmojiGroup(
        name: m.namedGroup('groupName')!,
        id: m.namedGroup('groupId')!,
        routeName: m.namedGroup('routeName')!,
        emojiList: [],
      );
    }

    // Parse emoji in each group.
    for (final m in _emojiGroupDataRe.allMatches(info)) {
      if (_disposed) {
        return [];
      }
      final groupId = m.namedGroup('groupId')!;
      final group = emojiGroupMap[groupId];
      if (group == null) {
        warning('emoji group $groupId not found in group info, skip');
        continue;
      }
      final data = m.namedGroup('data')!.replaceAll(r"\'", _escapedQuotePlaceholder);
      if (data.isEmpty) {
        continue;
      }
      final emojiList = <Emoji>[];
      for (final d in data.split('],[')) {
        //  ['694', '{:10_694:}','14.jpg','20','20','50'
        final dd = d.split("'");
        if (dd.length != 13) {
          continue;
        }
        final id = dd[1];
        final code = dd[3].replaceAll(_escapedQuotePlaceholder, "'");
        final fileName = dd[5];
        // Where the forum's pages show it from ([ImageCacheProvider.emojiImageUrlsOf] adds the image host). Some files
        // have spaces in their names (`1 (15).gif`, `d (1).gif`).
        final url =
            '${ImageCacheProvider.emojiForumImageHead}'
            '${Uri.encodeComponent(group.routeName)}/${Uri.encodeComponent(fileName)}';
        emojiList.add(Emoji(id: id, code: code, url: url));
      }
      emojiGroupMap[groupId] = group.copyWith(emojiList: [...group.emojiList, ...emojiList]);
    }
    // Groups without emoji are useless in editor (all custom groups are empty on server since Discuz X5 upgrade).
    final emptyGroups = emojiGroupMap.values.where((e) => e.emojiList.isEmpty).map((e) => '${e.id}:${e.name}');
    if (emptyGroups.isNotEmpty) {
      warning('empty emoji groups skipped: ${emptyGroups.join(', ')}');
    }
    return emojiGroupMap.values.where((e) => e.emojiList.isNotEmpty).toList();
  }

  /// Parse [info], the content of the forum's emoji list ([_emojiInfoUrl]).
  @visibleForTesting
  List<EmojiGroup> parseEmojiInfo(String info) => _parseEmojiInfo(info);

  ImageCacheProvider get _imageCache => _imageCacheProvider ?? getIt.get<ImageCacheProvider>();

  /// Load the emoji groups into [emojiGroupList]: the list saved on this device, else the forum's list (saved for the
  /// next time). Only the list: the images of a group are downloaded when it is shown ([downloadEmojiGroup]); the
  /// list on this device is asked again of the forum in the background ([refreshEmojiList]).
  AsyncVoidEither loadEmojiFromCacheOrServer() => AsyncVoidEither(() async {
    final saved = await _imageCache.loadEmojiInfo();
    if (saved != null && saved.isNotEmpty) {
      emojiGroupList = saved;
      return rightVoid();
    }
    info('load emoji list from server');
    final groups = await EmojiListInBackground.fetch(_imageCache, client: _netClientProvider);
    if (groups == null || _disposed) {
      return left(EmojiLoadFailedException());
    }
    emojiGroupList = groups;
    return rightVoid();
  });

  /// The forum's list when it is not [emojiGroupList] ([sameEmojiList]), saved; asked once a run
  /// ([EmojiListInBackground.refresh]). Null when nothing changed, it was asked before in this run, or it could not be
  /// had (nothing said: the list on this device stays).
  Future<List<EmojiGroup>?> refreshEmojiList() async {
    final shown = emojiGroupList;
    final groups = await EmojiListInBackground.refresh(_imageCache, client: _netClientProvider);
    if (groups == null || _disposed || (shown != null && sameEmojiList(shown, groups))) {
      return null;
    }
    emojiGroupList = groups;
    return groups;
  }

  /// The forum's list ([_emojiInfoUrl]), null when it could not be had or has no emoji.
  Future<List<EmojiGroup>?> _fetchEmojiList() async {
    final netClient = _netClientProvider ?? getIt.get<NetClientProvider>(instanceName: ServiceKeys.noCookie);
    final respEither = await netClient.get(_emojiInfoUrl).run();
    if (respEither.isLeft()) {
      handle(respEither.unwrapErr());
      return null;
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok || resp.data is! String) {
      error('failed to load emoji info: StatusCode=${resp.statusCode}');
      return null;
    }
    final groups = _parseEmojiInfo(resp.data as String);
    return groups.isEmpty ? null : groups;
  }

  /// Download the images of [group] not in the emoji cache yet, a few at once ([ImageCacheProvider.getOrMakeEmojiCache]
  /// limits all emoji downloads together); [onProgress] is
  /// told how many of all the group has are there.
  ///
  /// [onFailed] is told how many failed so far.
  ///
  /// Returns how many are still missing: failed to download, or left when the repository was disposed.
  Future<int> downloadEmojiGroup(
    EmojiGroup group, {
    void Function(int done, int total)? onProgress,
    void Function(int failed)? onFailed,
  }) async {
    final cache = _imageCache;
    final total = group.emojiList.length;
    final missing = group.emojiList.where((e) => !cache.hasEmojiCacheFile(group.id, e.id)).toList();
    var done = total - missing.length;
    var failed = 0;
    onProgress?.call(done, total);
    await Future.wait(
      missing.map(
        (emoji) async {
          final data = await cache.getOrMakeEmojiCache(group.id, emoji.id, url: emoji.url, wanted: () => !_disposed);
          if (data == null) {
            failed++;
            if (!_disposed) {
              onFailed?.call(failed);
            }
            return;
          }
          done++;
          if (!_disposed) {
            onProgress?.call(done, total);
          }
        },
      ),
    );
    if (failed > 0) {
      warning('emoji group ${group.id}: $failed of $total not downloaded');
    }
    return failed;
  }

  /// Load the official `@` user list, cached after the first success unless [force].
  AsyncEither<List<String>> _loadAtUsers({bool force = false}) {
    final cached = _atUsers;
    if (cached != null && !force) {
      return TaskEither.right(cached);
    }
    return getIt.get<NetClientProvider>().get(_atUserListUrl).mapHttp((e) => parseAtUserList(e.data as String)).map((
      users,
    ) {
      _atUsers = users;
      return users;
    });
  }

  /// Search the `@` user list by part of username [keyword], case insensitive.
  ///
  /// Discuz! X5 has no server side search for mentions: the official `at.js` fetches the whole list once and filters
  /// it locally, so does this.
  AsyncEither<List<String>> searchUserByName({required String keyword}) => _loadAtUsers().map((users) {
    final k = keyword.trim().toLowerCase();
    return users.where((e) => k.isEmpty || e.toLowerCase().contains(k)).toList();
  });

  /// Reload the users the current user may mention.
  AsyncEither<List<String>> loadAtUsers() => _loadAtUsers(force: true);
}

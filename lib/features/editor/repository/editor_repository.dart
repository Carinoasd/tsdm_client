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
  ///   example: In https://img.mikudm.net/img02/smilies/TSDM/9.jpg the "TSDM"
  ///   is the group route name.
  /// * PAGE_NUMBER: Page number of the emoji in group when display in browser.
  ///   Optional because we provides a different layout and this parameter is
  ///   not required.
  /// * EMOJI_ID: The emoji id in group. Like the "200" in BBCode "{:10_200:}".
  /// * BBCODE: Used in editor and represent the emoji when send data to server.
  ///   Also formatted like "{:${GROUP_ID}_${EMOJI_ID}:}".
  /// * FILE_NAME: the final file name in url when we fetch the emoji image. We
  ///   don't name cache with this value.
  static const _emojiInfoUrl = '$baseUrl/data/cache/common_smilies_var.js';

  /// Head of the image url.
  ///
  /// Full url: [_emojiFileUrlHead]/${ROUTE_NAME}/${FILE_NAME}
  static const _emojiFileUrlHead = 'https://img.tsdm39.com/img02/smilies/';

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
        // Some files have spaces in their names (`1 (15).gif`).
        final url = '$_emojiFileUrlHead${Uri.encodeComponent(group.routeName)}/${Uri.encodeComponent(fileName)}';
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
  /// next time). Only the list: the images of a group are downloaded when it is shown ([downloadEmojiGroup]).
  AsyncVoidEither loadEmojiFromCacheOrServer() => AsyncVoidEither(() async {
    final saved = await _imageCache.loadEmojiInfo();
    if (saved != null && saved.isNotEmpty) {
      emojiGroupList = saved;
      return rightVoid();
    }
    info('load emoji list from server');
    final netClient = _netClientProvider ?? getIt.get<NetClientProvider>(instanceName: ServiceKeys.noCookie);
    final respEither = await netClient.get(_emojiInfoUrl).run();
    if (respEither.isLeft()) {
      handle(respEither.unwrapErr());
      return left(EmojiLoadFailedException());
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok || resp.data is! String) {
      error('failed to load emoji info: StatusCode=${resp.statusCode}');
      return left(EmojiLoadFailedException());
    }
    final groups = _parseEmojiInfo(resp.data as String);
    if (groups.isEmpty) {
      return left(EmojiLoadFailedException());
    }
    emojiGroupList = groups;
    await _imageCache.saveEmojiInfo(groups);
    return rightVoid();
  });

  /// Download the images of [group] not in the emoji cache yet, a few at once ([ImageCacheProvider.getOrMakeEmojiCache]
  /// limits all emoji downloads together); [onProgress] is
  /// told how many of all the group has are there.
  ///
  /// Returns how many are still missing: failed to download, or left when the repository was disposed.
  Future<int> downloadEmojiGroup(EmojiGroup group, {void Function(int done, int total)? onProgress}) async {
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

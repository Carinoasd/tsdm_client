import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

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
        emojiList.add(Emoji(id: id, code: code, url: '$_emojiFileUrlHead${group.routeName}/$fileName'));
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

  Future<bool> _generateDownloadEmojiTask(
    NetClientProvider netClient,
    ImageCacheProvider cacheProvider,
    EmojiGroup emojiGroup,
    Emoji emoji, {
    bool force = false,
  }) async {
    if (_disposed) {
      // Terminate task generation if disposed.
      return false;
    }
    // Skip if have cache.
    if (!force && cacheProvider.hasEmojiCacheFile(emojiGroup.id, emoji.id)) {
      return true;
    }
    var retryTimes = 2;
    while (retryTimes >= 0) {
      retryTimes -= 1;
      // No more retry here.
      final respEither = await netClient.getImage(emoji.url).run();
      if (_disposed) {
        return false;
      }
      if (respEither.isLeft()) {
        if (retryTimes < 0) {
          handle(respEither.unwrapErr());
          error(
            'failed to download emoji ${emojiGroup.id}_${emoji.id}: '
            'exceed max retry times',
          );
          return false;
        }
        continue;
      }
      final resp = respEither.unwrap();
      if (resp.statusCode != HttpStatus.ok) {
        return false;
      }
      await cacheProvider.updateEmojiCache(emojiGroup.id, emoji.id, resp.data as List<int>);
    }
    return true;
  }

  /// Force load all emoji from server through [_emojiInfoUrl].
  ///
  /// No cookie needed in this process.
  ///
  /// Return false when single emoji file exceed max retry times.
  Future<bool> loadEmojiFromServer() async {
    info('load emoji from server');
    // TODO: Use injected net client.
    final netClient = getIt.get<NetClientProvider>(instanceName: ServiceKeys.noCookie);
    final respEither = await netClient.get(_emojiInfoUrl).run();
    if (respEither.isLeft()) {
      handle(respEither.unwrapErr());
      return false;
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      error('failed to load emoji info: StatusCode=${resp.statusCode}');
      return false;
    }
    emojiGroupList = _parseEmojiInfo(resp.data as String);
    final cacheProvider = getIt.get<ImageCacheProvider>();
    // Save emoji info.
    await cacheProvider.saveEmojiInfo(emojiGroupList!);
    // TODO: Download emoji in parallel.
    // Download emoji data.
    for (final emojiGroup in emojiGroupList!) {
      if (_disposed) {
        // Terminate job if disposed.
        return false;
      }
      final downloadList = emojiGroup.emojiList.map(
        (e) => _generateDownloadEmojiTask(netClient, cacheProvider, emojiGroup, e),
      );
      debug('download for emoji group: ${emojiGroup.id}');
      debug('emoji group ${emojiGroup.id} ${emojiGroup.emojiList.first.url}');
      await Future.wait(downloadList);
    }
    info('load emoji from server finished');
    return true;
  }

  /// Load single emoji data from server.
  ///
  /// Only use this when single emoji cache is missing.
  ///
  /// For large mount of emojis, use [loadEmojiFromServer] instead.
  Future<void> loadSingleEmoji(String groupId, String id) async {
    // TODO:
  }

  /// Load all emoji data from
  /// * cache: if have.
  /// * server: when cache is invalid.
  ///
  /// Only load the emoji info, do not load the emoji image data.
  ///
  /// Currently there there is no validation on emoji and emoji groups.
  AsyncVoidEither loadEmojiFromCacheOrServer() => AsyncVoidEither(() async {
    final cacheProvider = getIt.get<ImageCacheProvider>();
    if (await cacheProvider.validateEmojiCache()) {
      // Have valid emoji cache.
      emojiGroupList = await cacheProvider.loadEmojiInfo();
    } else {
      // Do not have valid emoji cache, reload from server.
      final ret = await loadEmojiFromServer();
      if (!ret) {
        return left(EmojiLoadFailedException());
      }
    }
    return rightVoid();
  });

  /// Some should be because still developing.
  AsyncVoidEither loadEmojiFromAsset() => AsyncVoidEither(() async {
    final cacheProvider = getIt.get<ImageCacheProvider>();
    if (await cacheProvider.validateEmojiCache()) {
      emojiGroupList = await cacheProvider.loadEmojiInfo();
    } else {
      emojiGroupList = await cacheProvider.loadEmojiFromAsset();
    }
    return rightVoid();
  });

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

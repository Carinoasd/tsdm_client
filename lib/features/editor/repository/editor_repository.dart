import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

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

  /// Url to get random recommend friends.
  ///
  /// Originally there is a query parameter called "tp" which contains thread id
  /// and page number, but seems work well without that so removed it.
  /// Add it back if any unexpected error occurred.
  static const _userRecommendUrl =
      '$baseUrl/plugin.php?id=amucallme_dzx:callme&adds=fastpostmessage&'
      'infloat=yes&handlekey=amucallme_dzx_add&'
      'inajax=1&ajaxtarget=fwin_content_amucallme_dzx_add';

  /// User to search user by name.
  ///
  /// Post to this url with form hash, handle key and keyword.
  static const _searchUserByName =
      '$baseUrl/plugin.php?id=amucallme_dzx:js&'
      'sreach=1&callmesubmit=true&ajax=1&adds=fastpostmessage&inajax=1';

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

  /// Parse username from document.
  ///
  /// For user search or friend recommendation.
  ///
  /// Returns the parsed list of username, and optional form hash.
  /// Currently two api use this function to parse username wrapped in server
  /// response:
  ///
  /// 1. Get random recommend friend for current logged user.
  /// 2. Search user by username keyword.
  ///
  /// The first api is a get result which only requires cookie (authenticated),
  /// while the second api is a POST to server that requires form hash. Form
  /// hash would be provided from repository caller but it's hard to
  /// consistently inject form hash because there are many places using editor.
  /// So alternatively, we use the form hash came from the first api then the
  /// form hash is provided internally inside this repository.
  /// But this solution add implicit requirements for the caller:
  /// MUST call random friend api before search user, otherwise search will
  /// fail due to lack of form hash.
  ///
  /// ## CAUTION
  ///
  /// The plugin `amucallme_dzx` is GONE since the server upgraded to Discuz X5, the server responds an error
  /// `插件不存在或已关闭` in `div.alert_error`, [_checkPluginError] detects it.
  (List<String>, String?) _parseUserFromXmlDocument(String xml, {bool parseFormHash = false}) {
    //<?xml version="1.0" encoding="utf-8"?>
    // <root><![CDATA[
    //
    // <form id="sform" ... >
    // <input ... />
    // <div class="c" style="width: 340px">
    // 要@好友，直接在贴子内打上<span><font color="#F00">[@]好友名称[/@]</font></span>就可以了。
    //
    // <div class="p_opt mpx pns cl">
    //
    // <span ... ><A ... >user1</A></span>
    // <span ... ><A ... >user2</A></span>
    // ...
    // </form>
    //
    // ]]></root>
    final xmlDoc = parseXmlDocument(xml);
    final htmlDoc = parseHtmlDocument(xmlDoc.documentElement?.innerText ?? '');
    final nameList = htmlDoc.querySelectorAll('a[onclick*="seditor_insertunit"]').map((e) => e.innerText);
    final formHash = htmlDoc.querySelector('input[name="formhash"]')?.attributes['value'];
    if (parseFormHash) {
      if (formHash == null) {
        error('form hash not found in user mention response');
      } else {
        debug('user mention, search form hash set to $formHash');
      }
    }
    return (nameList.toList(), formHash);
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

  /// Check the server error in response [xml] of user mention plugin, if any.
  ///
  /// ```xml
  /// <root><![CDATA[
  /// <div class="c altw"><div class="alert_error">插件不存在或已关闭<script>...</script></div></div>
  /// ]]></root>
  /// ```
  AppException? _checkPluginError(String xml) {
    if (!xml.contains('alert_error')) {
      return null;
    }
    final xmlDoc = parseXmlDocument(xml);
    final htmlDoc = parseHtmlDocument(xmlDoc.documentElement?.innerText ?? '');
    final errNode = htmlDoc.querySelector('div.alert_error');
    if (errNode == null) {
      return null;
    }
    errNode.querySelectorAll('script').forEach((e) => e.remove());
    final message = errNode.innerText.trim();
    error('user mention plugin error: $message');
    return ServerRespondedErrorException(message);
  }

  /// Search user by name.
  ///
  /// Fails with [ServerRespondedErrorException] if the plugin is not available on server.
  AsyncEither<List<String>> searchUserByName({required String keyword, required String formHash}) => getIt
      .get<NetClientProvider>()
      .postForm(_searchUserByName, data: {'handlekey': 'amucallme_dzx_add', 'formhash': formHash, 'keywords': keyword})
      .mapHttp((e) => e.data as String)
      .flatMap(
        (data) => switch (_checkPluginError(data)) {
          final AppException e => TaskEither.left(e),
          null => TaskEither.right(_parseUserFromXmlDocument(data).$1),
        },
      );

  /// Get random recommended user from server.
  ///
  /// Fails with [ServerRespondedErrorException] if the plugin is not available on server.
  AsyncEither<(List<String>, String?)> recommendUser() => getIt
      .get<NetClientProvider>()
      .get(_userRecommendUrl)
      .mapHttp((e) => e.data as String)
      .flatMap(
        (data) => switch (_checkPluginError(data)) {
          final AppException e => TaskEither.left(e),
          null => TaskEither.right(_parseUserFromXmlDocument(data, parseFormHash: true)),
        },
      );
}

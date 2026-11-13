import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The request of a page: the shared client's, or one a test injects.
typedef SpaceGet = Future<SyncEither<Response<dynamic>>> Function(String url);

/// Ask the page [url] of the space as the page [type] of `schema` [schema] of the forum's app API (plugin 4.0.0), when
/// the last `status` lists [name] in `space_pages` (the names of `status` are not the `type` of the answers: `doing`
/// is answered as `space_doing`).
///
/// With the shared client ([get] null) a `status` is asked first when this run has none yet
/// ([TsdmAppApi.ensureStatus]); an injected [get] relies on what is known. The answer is checked to be served to the
/// account in use ([currentUid], 0 for a guest): another account's is [IdentityChangedException], but for the forum's
/// login prompt served to a guest (the session ended). `Right(null)` is "read the web page": the flag off, an older
/// plugin, an answer that is not the page.
AsyncEither<TsdmAppV4Answer?> fetchSpaceV4Page(
  String url, {
  required String name,
  required String type,
  required int schema,
  SpaceGet? get,
  int Function() currentUid = currentLoginUid,
}) => AsyncEither(() async {
  if (get == null && getIt.isRegistered<NetClientProvider>()) {
    await TsdmAppApi.ensureStatus(getIt.get<NetClientProvider>());
  }
  if (!TsdmAppV4.has(TsdmAppV4Group.spacePages, name)) {
    return right(null);
  }
  final request = withTsdmAppV4Page(url);
  final result = get == null ? await getIt.get<NetClientProvider>().get(request).run() : await get(request);
  switch (result) {
    case Left(:final value):
      return left(value);
    case Right(:final value) when value.statusCode != HttpStatus.ok:
      return left(HttpRequestFailedException(value.statusCode));
    case Right(:final value):
      final answer = tsdmAppV4AnswerOf(value.data, type: type, schema: schema);
      final uid = currentUid();
      return switch (answer) {
        null => right(null),
        _ when answer.uid == uid => right(answer),
        TsdmAppV4Message(login: true) when answer.uid == 0 => right(answer),
        _ => left(IdentityChangedException()),
      };
  }
});

/// The list page of the answer [answer] of [fetchSpaceV4Page], read by [fromApi]; null for the web page:
///
/// * the page: [fromApi];
/// * the forum's message (a module switched off, the login prompt, a member that does not exist): its words, as the
///   web parsers give the forum's 提示信息;
/// * the owner's privacy (`error: privacy`, a page the forum prints without words of its own in the answer): the
///   forum's sentence with the owner's name ([spaceV4PrivacyMessage]);
/// * anything else (a message without words, another refusal of the plugin): null, the web page says what it says.
SpaceListPage<T>? spaceV4ListPageOf<T>(
  TsdmAppV4Answer? answer,
  SpaceListPage<T> Function(Map<String, dynamic> json) fromApi,
) => switch (answer) {
  TsdmAppV4Page(:final json) => fromApi(json),
  TsdmAppV4Message(:final message, :final login) when login || message.trim().isNotEmpty => SpaceListPage(
    items: const [],
    message: message.trim().isEmpty ? null : message.trim(),
    needLogin: login,
  ),
  TsdmAppV4Refused(error: 'privacy', :final json) => SpaceListPage(
    items: const [],
    message: spaceV4PrivacyMessage(json),
  ),
  _ => null,
};

/// The forum's words of its privacy page ("抱歉！由于 NAME 的隐私设置，您不能访问当前内容", `set_privacy`) for the answer
/// `error: privacy` [json], which carries the owner and no words.
String spaceV4PrivacyMessage(Map<String, dynamic> json) {
  final owner = tsdmAppText(tsdmAppMap(json['owner'])['username']);
  return t.spacePage.forumWords.privacy(
    name: owner.isEmpty ? '${tsdmAppInt(tsdmAppMap(json['owner'])['uid'])}' : owner,
  );
}

/// The account a page of 4.0.0 [json] was served to and its form hash, what the forms of the page are posted with;
/// null for a guest.
SpaceSession? spaceV4Session(Map<String, dynamic> json) {
  final uid = tsdmAppInt(json['uid']);
  final formHash = tsdmAppText(json['formhash']);
  return uid <= 0 || formHash.isEmpty ? null : SpaceSession(uid: uid, formHash: formHash);
}

/// The next page of [url] for a page of 4.0.0 [json] (`page` of `pages`), the parameter [key] (`page`, `page_c` for
/// the replies of a record) set; null on the last page.
String? spaceV4NextPageUrl(String url, Map<String, dynamic> json, {String key = 'page'}) {
  final page = tsdmAppInt(json['page']);
  final pages = tsdmAppInt(json['pages']);
  return page > 0 && page < pages ? spaceUrlWithPage(url, page + 1, key: key) : null;
}

/// [url] with its parameter [key] set to [page].
String spaceUrlWithPage(String url, int page, {String key = 'page'}) {
  final re = RegExp('([?&])$key=[^&#]*');
  if (re.hasMatch(url)) {
    return url.replaceFirstMapped(re, (m) => '${m[1]}$key=$page');
  }
  return '$url${url.contains('?') ? '&' : '?'}$key=$page';
}

/// The time [value] (unix seconds) of a page [json] as the forum prints a date and time (`Y-m-d H:i`), on the
/// member's wall clock (`timeoffset`); null without one.
///
/// The web pages print some of these relative ("1 分钟前"), which `tsdmAppWallClockTime` would rather have shown as
/// the real moment; the items keep the forum's time as text (their `time` is a string), so the answer's time is that
/// text, on purpose.
String? spaceV4Time(Object? value, Map<String, dynamic> json) =>
    tsdmAppWallClockTime(value, tsdmAppTimeOffset(json))?.yyyyMMDDHHMM();

/// The url [value] of an answer of 4.0.0 (an image, absolute; a link, relative to the forum) as an absolute url;
/// null when empty.
String? spaceV4Url(Object? value) {
  final url = tsdmAppText(value).trim();
  return url.isEmpty ? null : spaceAbsoluteUrl(url);
}

/// The html [html] the forum stored (`message_html`, `card.html`…) as an element for the app's renderer, which keeps
/// what it knows of it; [into] receives it instead of a new `div` when given.
uh.Element spaceV4Html(String html, {uh.Element? into}) {
  final body = parseHtmlDocument('<html><body>$html</body></html>').body;
  final element = into ?? uh.DivElement();
  [...?body?.nodes].forEach(element.append);
  return element;
}

/// The words of the privacy of a blog `friend` [friend] as the forum labels it (`friendname_N`), null for everyone's.
String? _blogPrivacyOf(int friend) {
  final words = t.spacePage.forumWords;
  return switch (friend) {
    1 => words.blogFriends,
    2 => words.blogChosen,
    3 => words.blogSelf,
    4 => words.blogPassword,
    _ => null,
  };
}

/// A page of a blog list of the forum's app API (plugin 4.0.0: `type: space_blog`, `schema` 61), asked as [url], as
/// [parseSpaceBlogListPage] reads the web page: the privacy label of a blog not everyone's (the web page prints it to
/// whoever the blog is listed for), the forum's note of the blogs hidden on this page (`hidden`).
SpaceListPage<SpaceBlog> spaceBlogListPageFromApi(Map<String, dynamic> json, String url) {
  final items = <SpaceBlog>[];
  for (final row in tsdmAppList(json['blogs'])) {
    final blogId = tsdmAppInt(row['blogid']);
    final uid = tsdmAppInt(row['uid']);
    final title = tsdmAppText(row['subject']).trim();
    if (blogId <= 0 || uid <= 0 || title.isEmpty) {
      continue;
    }
    final author = tsdmAppText(row['username']);
    final summary = tsdmAppText(row['summary']).replaceAll(RegExp(r'\s+'), ' ').trim();
    final category = tsdmAppText(row['classname']).trim();
    items.add(
      SpaceBlog(
        blogId: blogId,
        uid: uid,
        title: title,
        author: author.isEmpty ? null : author,
        time: spaceV4Time(row['dateline'], json),
        summary: summary.isEmpty ? null : summary,
        category: category.isEmpty ? null : category,
        views: tsdmAppInt(row['viewnum']),
        replies: tsdmAppInt(row['replynum']),
        privacy: _blogPrivacyOf(tsdmAppInt(row['friend'])),
      ),
    );
  }
  final hidden = tsdmAppInt(json['hidden']);
  return SpaceListPage(
    items: items,
    nextPageUrl: spaceV4NextPageUrl(url, json),
    hiddenNote: hidden > 0 ? t.spacePage.forumWords.hiddenBlogs(n: hidden) : null,
  );
}

/// A page of an album list of the forum's app API (plugin 4.0.0: `type: space_album`, `schema` 62, `mode: albums`),
/// asked as [url], as [parseSpaceAlbumListPage] reads the web page: an album the viewer may not open is listed with
/// its name and count as the web page lists it; the member's own list ends with the default album (`id=-1`) when the
/// forum offers it (`default_album_url`).
SpaceListPage<SpaceAlbum> spaceAlbumListPageFromApi(Map<String, dynamic> json, String url) {
  final items = <SpaceAlbum>[];
  for (final row in tsdmAppList(json['albums'])) {
    final albumId = tsdmAppInt(row['albumid']);
    final uid = tsdmAppInt(row['uid']);
    final name = tsdmAppText(row['albumname']).trim();
    if (albumId <= 0 || uid <= 0 || name.isEmpty) {
      continue;
    }
    items.add(
      SpaceAlbum(
        albumId: albumId,
        uid: uid,
        name: name,
        coverUrl: spaceV4Url(row['cover']),
        count: tsdmAppInt(row['picnum']),
      ),
    );
  }
  final owner = tsdmAppInt(tsdmAppMap(json['owner'])['uid']);
  if (owner > 0 && tsdmAppText(json['default_album_url']).isNotEmpty) {
    items.add(SpaceAlbum(albumId: -1, uid: owner, name: t.spacePage.forumWords.defaultAlbum));
  }
  return SpaceListPage(items: items, nextPageUrl: spaceV4NextPageUrl(url, json));
}

/// A page of a wall of the forum's app API (plugin 4.0.0: `type: space_wall`, `schema` 63), asked as [url], as
/// [parseSpaceWallPage] reads the web page: an anonymous message has the site's anonymous name and no author, the
/// message box is the page's `post` form.
SpaceListPage<SpaceBlogComment> spaceWallPageFromApi(Map<String, dynamic> json, String url) {
  final items = <SpaceBlogComment>[];
  for (final row in tsdmAppList(json['comments'])) {
    final cid = tsdmAppInt(row['cid']);
    if (cid <= 0) {
      continue;
    }
    final authorId = tsdmAppInt(row['authorid']);
    final anonymous = row['anonymous'] == 1 || authorId <= 0;
    items.add(
      SpaceBlogComment(
        cid: cid,
        author: tsdmAppText(row['author']).trim(),
        uid: anonymous ? null : authorId,
        avatarUrl: anonymous ? null : spaceV4Url(row['avatar']),
        time: spaceV4Time(row['dateline'], json),
        message: spaceV4Html(tsdmAppText(row['message_html'])),
        canDelete: row['can_delete'] == 1,
        canReply: row['can_reply'] == 1,
      ),
    );
  }
  return SpaceListPage(
    items: items,
    nextPageUrl: spaceV4NextPageUrl(url, json),
    session: spaceV4Session(json),
    canPost: json['post'] is Map,
  );
}

/// A page of the greetings received of the forum's app API (plugin 4.0.0: `type: space_poke`, `schema` 64), asked as
/// [url], as [parseReceivedPokePage] reads the web page: each greeting is its picture and its name, and what was said
/// with it (plain text, put in as text).
SpaceListPage<ReceivedPoke> spacePokePageFromApi(Map<String, dynamic> json, String url) {
  final items = <ReceivedPoke>[];
  for (final row in tsdmAppList(json['pokes'])) {
    final uid = tsdmAppInt(row['uid']);
    final username = tsdmAppText(row['username']);
    if (uid <= 0 || username.isEmpty) {
      continue;
    }
    final content = uh.SpanElement()..classes.add('xw0');
    if (spaceV4Url(row['icon']) case final icon?) {
      content
        ..append(
          uh.ImageElement()
            ..src = icon
            ..classes.add('vm'),
        )
        ..append(uh.Text(' '));
    }
    final action = tsdmAppText(row['action']).trim();
    final note = tsdmAppText(row['note']).trim();
    content.append(
      uh.Text(switch ((action.isEmpty, note.isEmpty)) {
        (false, false) => t.spacePage.forumWords.pokeSaid(action: action, note: note),
        (false, true) => action,
        _ => note,
      }),
    );
    items.add(
      ReceivedPoke(
        uid: uid,
        username: username,
        avatarUrl: spaceV4Url(row['avatar']),
        content: content,
        time: spaceV4Time(row['dateline'], json),
      ),
    );
  }
  return SpaceListPage(items: items, nextPageUrl: spaceV4NextPageUrl(url, json), session: spaceV4Session(json));
}

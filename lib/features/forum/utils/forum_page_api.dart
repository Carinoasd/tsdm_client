import 'dart:convert';

import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

/// The names of the "everything" entries the web page lists first in its filter menus (`forum_thread_filters_x5`), kept
/// so the filter bar reads the same whichever path built the page.
const _allTypes = '全部';
const _allSpecialTypes = '全部主题';
const _defaultOrder = '默认排序';
const _allDatelines = '全部时间';

/// The structured forum page answer in [data]: a JSON answer of the forum's app API that carries every field the app
/// reads (plugin 2.0.0, `schema` 2 or later), or the forum's own message of such a plugin (no permission, please log
/// in: `ok` 0, `error: message`, with `login` telling the two apart). Null when the answer has to be read from its
/// `document` as before: a web page, an older plugin's answer (no `schema`, no `login`), a failed build.
///
/// The page is then built by [forumPageFromApi]; the `document` of the answer, when there is one, is never parsed.
Map<String, dynamic>? forumApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 2;
  if (json['ok'] == 1) {
    return structured ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// Build the page of forum [fid] from a structured answer [json] of the forum's app API ([forumApiAnswerOf]).
///
/// The same [ForumPageData] the web page gives through `parseForumPage`, from the fields instead of the html:
///
/// * `forum.name` is the title; `forum.rules` (the html the forum prints in `#forum_rules_<fid>`, empty when there is
///   none) is the rules element, rendered as from the page.
/// * `threads` are the rows in the forum's order, the sticky ones (`displayorder` > 0: global, in type, in forum) as
///   [StickThread], the rest as [NormalThread] ([NormalThread.fromApi]); `subforums` as [Forum] ([Forum.fromApi]).
/// * The forum's message (`ok` 0): `login` 1 is the login prompt of a guest (`needLogin`), 0 a member without
///   permission (`havePermission` false, the message text as the denied message, as the page's `#messagetext p`).
/// * `page` / `pages` give the pagination: since plugin 2.8.2 as the page's pagination prints it, the page the forum
///   really shows (its first page when asked past its last page or past the site's limit of pages, `threadmaxpages`)
///   and the last page one can go to (within that limit); before, the page asked and the pages of all the threads.
///   `types.items` the type filter with the page's "everything" entry first,
///   only when the forum lists its types (`types.listable` 1): the page shows no type row otherwise, nor when the
///   forum has no types, and the app no filter bar then; `filters.*` the menus of the page in its order and names,
///   each with its "everything" entry first (`specialtype` only lists the special threads the forum allows, which can
///   be none: the entry alone then).
/// * `forum.allow_poll` with the answer's `uid` is the poll offer (a guest, `uid` 0, is never offered one).
/// * `forum.allow_post` is whether the account may post a thread; unknown for a guest (`uid` 0), who needs an account
///   first, and for an answer without the field.
ForumPageData forumPageFromApi(Map<String, dynamic> json, String fid) {
  if (json['ok'] != 1) {
    final needLogin = json['login'] == 1;
    return ForumPageData(
      title: null,
      rulesElement: null,
      normalThreadList: const [],
      stickThreadList: const [],
      subredditList: const [],
      needLogin: needLogin,
      havePermission: needLogin,
      permissionDeniedMessage: needLogin
          ? null
          : parseHtmlDocument('<p>${htmlEscape.convert(_text(json['message']))}</p>').querySelector('p'),
      canLoadMore: false,
      currentPage: null,
      totalPages: null,
      filterTypeList: const [],
      filterSpecialTypeList: const [],
      filterOrderList: const [],
      filterDatelineList: const [],
    );
  }

  final forum = _map(json['forum']);
  final types = _map(json['types']);
  final filters = _map(json['filters']);
  final typePrefix = _int(types['prefix']);
  final forumId = int.tryParse(fid) ?? _int(forum['fid']);

  final rules = _text(forum['rules']);
  final rulesElement = rules.isEmpty
      ? null
      : parseHtmlDocument('<div id="forum_rules_$fid">$rules</div>').querySelector('div#forum_rules_$fid');

  final timeOffset = tsdmAppTimeOffset(json);
  final normalThreadList = <NormalThread>[];
  final stickThreadList = <StickThread>[];
  for (final row in _list(json['threads'])) {
    if (_int(row['displayorder']) > 0) {
      stickThreadList.add(StickThread.fromApi(row, fid: forumId, typePrefix: typePrefix, timeOffset: timeOffset));
    } else {
      normalThreadList.add(NormalThread.fromApi(row, fid: forumId, typePrefix: typePrefix, timeOffset: timeOffset));
    }
  }
  final subredditList = _list(json['subforums']).map(Forum.fromApi).toList();

  final currentPage = json['page'] is num ? _int(json['page']) : null;
  final totalPages = json['pages'] is num ? _int(json['pages']) : null;

  final typeItems = _int(types['listable']) == 1 ? _list(types['items']) : const <Map<String, dynamic>>[];
  final filterTypeList = typeItems.isEmpty
      ? const <FilterType>[]
      : [
          const FilterType(name: _allTypes, typeID: null),
          ...typeItems.map((e) => FilterType(name: _text(e['name']), typeID: '${_int(e['id'])}')),
        ];
  // The menus the page always has, each with its "everything" entry (alone when the forum allows no special thread).
  final filterSpecialTypeList = [
    const FilterSpecialType(name: _allSpecialTypes, specialType: null),
    ..._list(
      filters['specialtype'],
    ).map((e) => FilterSpecialType(name: _text(e['name']), specialType: _text(e['value']))),
  ];
  final filterOrderList = [
    const FilterOrder(name: _defaultOrder, orderBy: null),
    ..._list(filters['orderby']).map((e) => FilterOrder(name: _text(e['name']), orderBy: _text(e['value']))),
  ];
  final filterDatelineList = [
    const FilterDateline(name: _allDatelines, dateline: null),
    ..._list(filters['dateline']).map((e) => FilterDateline(name: _text(e['name']), dateline: '${_int(e['value'])}')),
  ];

  final uid = _int(json['uid']);

  return ForumPageData(
    title: _text(forum['name']),
    rulesElement: rulesElement,
    normalThreadList: normalThreadList,
    stickThreadList: stickThreadList,
    subredditList: subredditList,
    needLogin: false,
    havePermission: true,
    permissionDeniedMessage: null,
    canLoadMore: currentPage != null && totalPages != null && currentPage < totalPages,
    currentPage: currentPage,
    totalPages: totalPages,
    filterTypeList: filterTypeList,
    filterSpecialTypeList: filterSpecialTypeList,
    filterOrderList: filterOrderList,
    filterDatelineList: filterDatelineList,
    pollOfferUid: _int(forum['allow_poll']) == 1 && uid > 0 ? uid : null,
    postAllowed: uid > 0 && forum.containsKey('allow_post') ? _int(forum['allow_post']) == 1 : null,
  );
}

int _int(Object? value) => switch (value) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};

String _text(Object? value) => value is String ? value : '';

Map<String, dynamic> _map(Object? value) => value is Map<String, dynamic> ? value : const {};

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];

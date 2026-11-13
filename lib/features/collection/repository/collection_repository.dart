import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:tsdm_client/features/collection/utils/collection_answer.dart';
import 'package:tsdm_client/features/collection/utils/parse_collection.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// Read [url]: a page, or with [write] a GET that changes something (sent once, with [withTsdmAppJsonWrite]).
/// Returns the failure of the transport as its left, the decoded body as its right.
typedef CollectionGet = Future<Either<AppException, Object?>> Function(String url, {bool write});

/// Post the form [body] to [url] once, never retried. Returns the failure of the transport as its left.
typedef CollectionPost = Future<Either<AppException, Object?>> Function(String url, Map<String, String> body);

/// [keywords] as the forum takes them, separated by spaces: a comma or an ideographic comma between two is a space
/// too.
String collectionKeywords(String keywords) =>
    keywords.replaceAll(RegExp('[,，、;；]'), ' ').split(RegExp(r'\s+')).where((e) => e.isNotEmpty).join(' ');

/// Fields of a form the forum reads as an array (`ctid[]`, `tids[]`, `delthread[]`), as indexed keys: PHP takes
/// `ctid[0]=3&ctid[1]=4` as `ctid[]=3&ctid[]=4`, and a form body here maps each key to one value.
Map<String, String> collectionArrayFields(String name, Iterable<Object> values) => {
  for (final (i, v) in values.indexed) '$name[$i]': '$v',
};

/// The forum's collections (淘专辑): the lists, a collection's page and comments, and the changes the web pages make
/// (subscribe, create, edit, delete, put a thread in, take threads out, comment).
///
/// The forum's app API answers none of the pages (plugin 3.7.0): they are read from the web page
/// ([parseCollectionList], [parseCollectionDetail], [parseCollectionComments]). The changes carry the result parameter
/// of the app API, whose result is read first ([collectionOutcomeOf]), and are sent once.
///
/// Every change carries the form hash of the page it is made from and is sent only while the account in use is the
/// one that page was served to ([isCurrent]); the client drops the answer once another account is in use.
final class CollectionRepository {
  /// Constructor; the transports are injected so the flow is tested without the forum.
  CollectionRepository({required CollectionGet get, required CollectionPost post, int Function()? currentUid})
    : _get = get,
      _post = post,
      _currentUid = currentUid ?? currentLoginUid;

  /// Uses the app's client.
  factory CollectionRepository.network() => CollectionRepository(
    get: (url, {write = false}) async {
      final client = getIt.get<NetClientProvider>();
      final request = write ? client.get(withTsdmAppJsonWrite(url), singleAttempt: true) : client.get(url);
      return switch (await request.run()) {
        Left(:final value) => left(value),
        Right(:final value) when !write && value.statusCode != 200 => left(
          HttpRequestFailedException(value.statusCode),
        ),
        Right(:final value) => right(value.data),
      };
    },
    post: (url, body) async =>
        switch (await getIt.get<NetClientProvider>().postForm(url, data: body, singleAttempt: true).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right(value.data),
        },
  );

  final CollectionGet _get;
  final CollectionPost _post;
  final int Function() _currentUid;

  static const _base = '$baseUrl/forum.php?mod=collection';

  /// The web page of the list [tab] ([order] for [CollectionListTab.all]), page [page].
  static String listUrl(CollectionListTab tab, {CollectionOrder order = CollectionOrder.dateline, int page = 1}) {
    final pageQuery = page > 1 ? '&page=$page' : '';
    return switch (tab) {
      CollectionListTab.recommended => '$_base$pageQuery',
      CollectionListTab.all =>
        '$_base&op=all${order == CollectionOrder.dateline ? '' : '&order=${order.name}'}$pageQuery',
      CollectionListTab.mine || CollectionListTab.subscribed => '$_base&op=my',
    };
  }

  /// The web page of the collections holding thread [tid].
  static String relatedUrl(int tid) => '$_base&tid=$tid';

  /// The web page of the comments of collection [ctid].
  static String commentsUrl(int ctid, {int page = 1}) =>
      '$_base&action=view&op=comment&ctid=$ctid${page > 1 ? '&page=$page' : ''}';

  AsyncEither<T> _page<T>(String url, T Function(String html) parse) => AsyncEither(() async {
    switch (await _get(url)) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        final html = tsdmAppAnswerText(value);
        if (html.trim().isEmpty) {
          return left(HttpRequestFailedException(200));
        }
        try {
          return right(parse(html));
        } on AppException catch (e) {
          return left(e);
        }
    }
  });

  /// The list [tab], page [page]. [CollectionListTab.mine] and [CollectionListTab.subscribed] are the two parts of the
  /// forum's one page of the account's collections.
  AsyncEither<CollectionListResult> fetchList(
    CollectionListTab tab, {
    CollectionOrder order = CollectionOrder.dateline,
    int page = 1,
  }) => _page(listUrl(tab, order: order, page: page), (html) {
    final list = parseCollectionList(
      parseHtmlDocument(html),
      order: tab == CollectionListTab.all ? order : null,
    );
    if (tab != CollectionListTab.mine && tab != CollectionListTab.subscribed) {
      return list;
    }
    final subscribed = tab == CollectionListTab.subscribed;
    return CollectionListResult(
      items: list.items.where((e) => (e.relation == CollectionRelation.subscribed) == subscribed).toList(),
      currentPage: 1,
      totalPages: 1,
      canCreate: list.canCreate,
      formHash: list.formHash,
      viewerUid: list.viewerUid,
    );
  });

  /// The page of collection [ctid], page [page] of its threads.
  AsyncEither<CollectionDetail> fetchDetail(int ctid, {int page = 1}) => _page(
    '${collectionUrl(ctid)}${page > 1 ? '&page=$page' : ''}',
    (html) => parseCollectionDetail(parseHtmlDocument(html)),
  );

  /// The comments of collection [ctid], page [page].
  AsyncEither<CollectionCommentPage> fetchComments(int ctid, {int page = 1}) =>
      _page(commentsUrl(ctid, page: page), (html) => parseCollectionComments(parseHtmlDocument(html)));

  /// Whether the account in use is [viewerUid], the one a page was served to.
  bool isCurrent(int? viewerUid) => viewerUid != null && viewerUid > 0 && viewerUid == _currentUid();

  Future<CollectionOutcome> _send(
    Future<Either<AppException, Object?>> Function() request, {
    CollectionOutcome Function(Object?) result = collectionOutcomeOf,
  }) async {
    final Either<AppException, Object?> answer;
    try {
      answer = await request();
    } on IdentityChangedException {
      return const CollectionAccountChanged();
    }
    return switch (answer) {
      Left(value: IdentityChangedException()) => const CollectionAccountChanged(),
      Left(:final value) => () {
        talker.warning('collection change failed: $value');
        return const CollectionUnknown();
      }(),
      Right(:final value) => result(value),
    };
  }

  /// Subscribe to collection [detail] ([follow]) or unsubscribe from it, as its page's link does (a GET).
  Future<CollectionOutcome> setFollow(CollectionDetail detail, {required bool follow}) async {
    if (!isCurrent(detail.viewerUid)) {
      return const CollectionAccountChanged();
    }
    return _send(
      () => _get(
        '$_base&action=follow&op=${follow ? 'follow' : 'unfo'}&ctid=${detail.ctid}&formhash=${detail.formHash}'
        '&inajax=1',
        write: true,
      ),
    );
  }

  /// The forum's window to put thread [tid] in a collection: the account's collections that can take it, or the
  /// forum's refusal (none left to put it in, a forum whose threads may not be collected, log in first) as the left.
  Future<Either<CollectionOutcome, CollectThreadForm>> fetchCollectForm(int tid) async {
    final uid = _currentUid();
    if (uid <= 0) {
      return left(const CollectionNeedLogin());
    }
    if (getIt.isRegistered<NetClientProvider>()) {
      await TsdmAppApi.ensureStatus(getIt.get<NetClientProvider>());
    }
    if (TsdmAppV4.has(TsdmAppV4Group.forms, SmallFormKind.collection.name)) {
      // Plugin 4.0.0: the window as a small form; anything else of it reads the window as below.
      try {
        if (await _get(withTsdmAppV4Form('$_base&action=edit&op=addthread&tid=$tid&handlekey=k_collect&inajax=1'))
            case Right(:final value)) {
          if (collectThreadFormFromApi(value, tid: tid, viewerUid: uid) case final form?) {
            return form;
          }
        }
      } on IdentityChangedException {
        return left(const CollectionAccountChanged());
      }
    }
    final Either<AppException, Object?> answer;
    try {
      // A read, asked as the writes are (the result parameter, once): the plugin then answers the window as its result
      // (`kind: page`, or the refusal, or the login redirect `login: 1`), which tells the refusals apart.
      answer = await _get('$_base&action=edit&op=addthread&tid=$tid&inajax=1', write: true);
    } on IdentityChangedException {
      return left(const CollectionAccountChanged());
    }
    switch (answer) {
      case Left(value: IdentityChangedException()):
        return left(const CollectionAccountChanged());
      case Left(:final value):
        talker.warning('collection window failed: tid $tid: $value');
        return left(const CollectionUnknown());
      case Right(:final value):
        final form = parseCollectThreadForm(collectionDialogHtml(value), tid: tid, viewerUid: uid);
        if (form != null) {
          return right(form);
        }
        return left(switch (collectionOutcomeOf(value)) {
          // A window that is not the form tells nothing more than that.
          CollectionDone() => const CollectionUnknown(),
          final other => other,
        });
    }
  }

  /// Put the thread of [form] in the collections [ctids] with the reason [reason], as the window's form does.
  ///
  /// The forum takes the thread into each collection that does not hold it yet and answers its success even when
  /// every one held it already.
  Future<CollectionOutcome> collect(CollectThreadForm form, Iterable<int> ctids, String reason) async {
    if (!isCurrent(form.viewerUid)) {
      return const CollectionAccountChanged();
    }
    if (form case CollectThreadForm(submitUrl: final url?, submitFields: final fields?)) {
      // Plugin 4.0.0: the window's own fields back as served, once; `collection_collect_succ` is the forum's success.
      return _send(
        () => _post(withTsdmAppV4Write(url), {
          ...fields,
          'reason': reason,
          ...collectionArrayFields('ctid', ctids),
        }),
        result: collectOutcomeFromApi,
      );
    }
    return _send(
      () => _post('$_base&action=edit&op=addthread&inajax=1', {
        'formhash': form.formHash,
        'addthread': '1',
        'handlekey': 'k_collect',
        'reason': reason,
        ...collectionArrayFields('ctid', ctids),
        ...collectionArrayFields('tids', [form.tid]),
      }),
    );
  }

  /// Create a collection named [title], as the forum's window does (the cover and the icon are not sent); its id is
  /// the done outcome's `ctid` ([createdCtid]). [viewerUid] and [formHash] are of the page it is created from.
  Future<CollectionOutcome> create({
    required int viewerUid,
    required String formHash,
    required String title,
    String description = '',
    String keywords = '',
  }) async {
    if (!isCurrent(viewerUid)) {
      return const CollectionAccountChanged();
    }
    return _send(
      () => _post('$_base&action=edit&op=add&inajax=1', {
        'formhash': formHash,
        'collectionsubmit': '1',
        'submitcollection': '1',
        'title': title,
        'desc': description,
        'keyword': collectionKeywords(keywords),
      }),
    );
  }

  /// Change the name, the description and the keywords of collection [detail].
  Future<CollectionOutcome> edit(
    CollectionDetail detail, {
    required String title,
    required String description,
    required String keywords,
  }) async {
    if (!isCurrent(detail.viewerUid)) {
      return const CollectionAccountChanged();
    }
    return _send(
      () => _post('$_base&action=edit&op=edit&ctid=${detail.ctid}&inajax=1', {
        'formhash': detail.formHash,
        'collectionsubmit': '1',
        'submitcollection': '1',
        'title': title,
        'desc': description,
        'keyword': collectionKeywords(keywords),
      }),
    );
  }

  /// Delete collection [detail], as its page's link does (a GET).
  Future<CollectionOutcome> delete(CollectionDetail detail) async {
    if (!isCurrent(detail.viewerUid)) {
      return const CollectionAccountChanged();
    }
    return _send(
      () => _get(
        '$_base&action=edit&op=remove&ctid=${detail.ctid}&formhash=${detail.formHash}&inajax=1',
        write: true,
      ),
    );
  }

  /// Take the threads [tids] out of collection [detail].
  Future<CollectionOutcome> removeThreads(CollectionDetail detail, Iterable<int> tids) async {
    if (!isCurrent(detail.viewerUid)) {
      return const CollectionAccountChanged();
    }
    return _send(
      () => _post('$_base&action=edit&op=delthread&inajax=1', {
        'formhash': detail.formHash,
        'ctid': '${detail.ctid}',
        ...collectionArrayFields('delthread', tids),
      }),
    );
  }

  /// Comment on the collection of [page] with [message], and rate it [rate] (1 to 5) when the account has not yet.
  Future<CollectionOutcome> comment(CollectionCommentPage page, {required String message, int? rate}) async {
    if (!isCurrent(page.viewerUid)) {
      return const CollectionAccountChanged();
    }
    return _send(
      () => _post('$_base&action=comment&ctid=${page.ctid}&inajax=1', {
        'formhash': page.formHash,
        'handlekey': 'k_addComment',
        'message': message,
        'ratescore': page.myRate == null && rate != null ? '$rate' : '',
      }),
    );
  }
}

/// The id of the collection the done outcome [outcome] of [CollectionRepository.create] created, null without one.
int? createdCtid(CollectionOutcome outcome) => switch (outcome) {
  CollectionDone(:final values) => int.tryParse(values['ctid'] ?? ''),
  _ => null,
};

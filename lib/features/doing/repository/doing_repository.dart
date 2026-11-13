import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/doing/models/doing_models.dart';
import 'package:tsdm_client/features/doing/utils/parse_doing.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_account_repository.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_v4.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Reads the records and their replies.
///
/// The forum's app API answers them as fields since plugin 4.0.0 (`status` lists `doing` and `docomment` in
/// `space_pages`): the list is `type: space_doing` (`schema` 57), the replies of a record `space_docomment` (58). Without
/// it (an older plugin, the flag off, an answer that is not the page) the pages are the website's, which the plugin
/// leaves alone and which are parsed; the replies of a record are then the fragment the website loads under it.
final class DoingRepository {
  /// Constructor; [get] replaces the request of the shared client, [currentUid] the account in use.
  const DoingRepository({Future<SyncEither<Response<dynamic>>> Function(String url)? get, int Function()? currentUid})
    : _get = get,
      _currentUid = currentUid;

  final Future<SyncEither<Response<dynamic>>> Function(String url)? _get;

  final int Function()? _currentUid;

  AsyncEither<TsdmAppV4Answer?> _v4(String url, {required String name, required String type, required int schema}) =>
      fetchSpaceV4Page(
        url,
        name: name,
        type: type,
        schema: schema,
        get: _get,
        currentUid: _currentUid ?? currentLoginUid,
      );

  AsyncEither<Response<dynamic>> _run(String url) =>
      AsyncEither(() => _get == null ? getIt.get<NetClientProvider>().get(url).run() : _get(url));

  /// A page of records ([doingListUrl], or the next page of one).
  AsyncEither<SpaceListPage<Doing>> fetchList(String url) => AsyncEither(() async {
    switch (await _v4(url, name: 'doing', type: 'space_doing', schema: 57).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        if (spaceV4ListPageOf(value, (json) => doingListPageFromApi(json, url)) case final page?) {
          return right(page);
        }
    }
    return _run(withTsdmAppJson(url)).mapHttpPage(parseDoingListPage).run();
  });

  /// The page [page] of the replies of the record [doid]: the answer of plugin 4.0.0 ([doingCommentsFromApi]) when
  /// `status` lists `docomment`, else the fragment the website loads. The forum shows them to members only: a guest is
  /// answered the login prompt (4.0.0: the forum's message with `login`; before: the way to the login page, a
  /// `redirect` result with `login`), told as the page's message.
  AsyncEither<DoingCommentPage> fetchComments(int doid, {int page = 1}) => AsyncEither(() async {
    final v4 = await _v4(
      '$baseUrl/home.php?mod=spacecp&ac=doing&op=getcomment&doid=$doid&page_c=$page',
      name: 'docomment',
      type: 'space_docomment',
      schema: 58,
    ).run();
    switch (v4) {
      case Left(:final value):
        return left(value);
      case Right(value: TsdmAppV4Page(:final json)):
        return right(doingCommentsFromApi(json, doid: doid, page: page));
      case Right(value: TsdmAppV4Message(:final message, :final login)) when login || message.trim().isNotEmpty:
        // The forum's words instead (the module switched off, the login asked for), as the fragment's message.
        return right(
          DoingCommentPage(
            comments: const [],
            page: page,
            hasMore: false,
            message: message.trim().isEmpty ? t.general.needLogin : message.trim(),
          ),
        );
      case Right(value: TsdmAppV4Refused(error: 'privacy', :final json)):
        // Not answered for the replies by the forum today (they are not a page of the space), told as the other pages
        // tell it all the same.
        return right(
          DoingCommentPage(comments: const [], page: page, hasMore: false, message: spaceV4PrivacyMessage(json)),
        );
      case Right():
        break;
    }
    final Response<dynamic> response;
    switch (await _run(withTsdmAppJsonWrite(doingCommentsUrl(doid, page: page))).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        response = value;
    }
    final fragment = response.statusCode == HttpStatus.ok ? spaceAjaxFragmentOf(response.data) : null;
    if (fragment == null) {
      // The forum's message instead (the module switched off, the login asked for): its words.
      final message = tsdmAppWriteResultOf(response.data)?.reason ?? '';
      return message.isEmpty
          ? left(HttpRequestFailedException(response.statusCode))
          : right(DoingCommentPage(comments: const [], page: page, hasMore: false, message: message));
    }
    return right(parseDoingComments(fragment, doid: doid, page: page));
  });
}

/// Posts records and replies and deletes them for one account, the one current when it was built
/// ([SpaceAccountRepository]).
///
/// The forum answers a record posted, and every delete, by going back to where the form came from: the app API tells
/// it as a `redirect` result, the forum without it as the redirect itself. A delete answers the same whether or not
/// the forum took it (a record or a reply of another member is left alone silently), so the list is read again.
final class DoingWriteRepository extends SpaceAccountRepository {
  /// Constructor.
  DoingWriteRepository({required super.client, required super.currentUid});

  /// Injectable transports; a post is never retried.
  DoingWriteRepository.withTransport({required super.currentUid, required super.getPage, required super.sendForm})
    : super.withTransport();

  static const _cp = '$baseUrl/home.php?mod=spacecp&ac=doing';

  /// Where a record is posted.
  static const postUrl = '$_cp&inajax=1';

  /// Where a reply to the record [doid] is posted; to its reply [docid] when given.
  static String commentUrl(int doid, {int? docid}) => '$_cp&op=comment&doid=$doid&docid=${docid ?? 0}&inajax=1';

  /// Where the record [doid] is deleted; its reply [docid] when given.
  static String deleteUrl(int doid, {int? docid}) =>
      '$_cp&op=delete&doid=$doid${docid == null ? '' : '&docid=$docid'}&inajax=1';

  /// Post the record [message] with the [session] of a list, once.
  ///
  /// The forum keeps the beginning of a longer one ([doingMaxLength]), refuses an empty one (`should_write_that`),
  /// another post within its flood interval (`operating_too_fast`), a group that may not (`no_privilege_doing`).
  Future<SpaceWriteResult> post(SpaceSession session, String message) async {
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(
      await sendForm(postUrl, {
        'formhash': session.formHash,
        'addsubmit': 'true',
        'message': message.trim(),
        'handlekey': 'doing',
      }),
      redirectIsDone: true,
    );
  }

  /// Reply [message] to the record [doid], or to its reply [docid], once (`do_success`; `docomment_error` for a
  /// record that is gone).
  Future<SpaceWriteResult> comment(SpaceSession session, int doid, String message, {int? docid}) async {
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(
      await sendForm(commentUrl(doid, docid: docid), {
        'formhash': session.formHash,
        'commentsubmit': 'true',
        'message': message.trim(),
        'handlekey': 'doing_$doid',
      }),
    );
  }

  /// Delete the record [doid], or its reply [docid], once.
  Future<SpaceWriteResult> delete(SpaceSession session, int doid, {int? docid}) async {
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(
      await sendForm(deleteUrl(doid, docid: docid), {
        'formhash': session.formHash,
        'deletesubmit': 'true',
        'handlekey': docid == null ? 'doinghk_$doid' : 'doinghk_${doid}_$docid',
      }),
      redirectIsDone: true,
    );
  }
}

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/utils/draft_marker.dart';
import 'package:tsdm_client/features/post/utils/submission_result.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// A post form page as [PostEditRepository.fetchForm] got it.
sealed class PostEditFormAnswer {
  const PostEditFormAnswer();
}

/// The web page, parsed as it always was: a forum without the plugin, or with one older than 2.9.0.
final class PostEditFormPage extends PostEditFormAnswer {
  /// Constructor.
  const PostEditFormPage(this.document);

  /// The page.
  final uh.Document document;
}

/// The post form of the forum's app API (plugin 2.9.0, `type: post`, `schema` 16).
final class PostEditFormApi extends PostEditFormAnswer {
  /// Constructor.
  const PostEditFormApi(this.form);

  /// The form.
  final PostForm form;
}

/// The forum's message shown instead of the form (plugin 2.9.0): no permission, a password forum, an edit time limit…
final class PostEditFormRefused extends PostEditFormAnswer {
  /// Constructor.
  const PostEditFormRefused(this.message);

  /// The message, plain text.
  final String message;
}

/// Repository for editing posts.
final class PostEditRepository with LoggerMixin {
  /// Keep load and submit on one account-bound client for the editor lifetime.
  PostEditRepository({required NetClientProvider client, required int? Function() currentUid})
    : this.withTransport(
        currentUid: currentUid,
        getPage: (url) => client.get(url).run(),
        sendForm: (url, body) => client.postForm(url, data: body, singleAttempt: true).run(),
      );

  /// Injectable identity-bound transports; submissions must never automatically retry.
  PostEditRepository.withTransport({
    required int? Function() currentUid,
    required Future<SyncEither<Response<dynamic>>> Function(String) getPage,
    required Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) sendForm,
  }) : _get = getPage,
       _post = sendForm,
       _currentUid = currentUid,
       _ownerUid = currentUid();

  final Future<SyncEither<Response<dynamic>>> Function(String) _get;
  final Future<SyncEither<Response<dynamic>>> Function(String, Map<String, String>) _post;
  final int? Function() _currentUid;
  final int? _ownerUid;
  bool _invalidated = false;

  /// Once invalidated, switching back must not revive an old form.
  void invalidate() => _invalidated = true;

  /// Whether this editing session still belongs to the active account.
  bool get isCurrent => !_invalidated && _ownerUid != null && _ownerUid > 0 && _ownerUid == _currentUid();

  /// Ignore repeated verification events for the same active account.
  bool belongsTo(int? uid) => isCurrent && uid == _ownerUid;

  /// A successful POST may instead enter moderation; verify the draft marker through GET.
  ///
  /// The thread page [url] is asked in the JSON mode of the forum's app API. A structured answer (plugin 2.1.0,
  /// `schema: 3`) tells the account it was served to and whether the thread is a draft (`thread.draft`); any other
  /// answer is the page, read as before: the account from its `discuz_uid`, the draft from the marker beside the
  /// title ([isDraftThreadDocument]).
  Future<bool> confirmsDraft(String url) async {
    if (!isCurrent) return false;
    final result = await _get(withTsdmAppJson(url));
    if (!isCurrent) return false;
    return result.match((_) => false, (response) {
      if (response.statusCode != 200) return false;
      final api = threadApiAnswerOf(response.data);
      if (api != null) {
        return threadApiViewerUid(api) == _ownerUid && threadPageFromApi(api, 1).isDraft;
      }
      if (tsdmAppAnswerWithoutPage(response.data)) return false;
      final document = tsdmAppPageDocument(response.data);
      if (parseLoggedUidFromDocument(document) != _ownerUid) return false;
      return isDraftThreadDocument(document);
    });
  }

  static const _postSubmitTarget = '$baseUrl/forum.php?mod=post&action=edit&extra=&editsubmit=yes';

  static String _buildThreadInfoUrl(String fid) => '$homePage?mod=post&action=newthread&fid=$fid';

  static String _buildThreadPostUrl(String fid) =>
      '$homePage?mod=post&action=newthread&fid=$fid&extra=&topicsubmit=yes';

  /// Fetch the post form page [url] (a new thread or an edit) in the JSON mode of the forum's app API
  /// ([withTsdmAppJson], `nodoc=1`).
  ///
  /// Plugin 2.9.0 answers the form as structured fields (`type: post`, `schema` 16, [PostEditFormApi]) or the forum's
  /// message instead of it ([PostEditFormRefused]); an older plugin, or none, leaves the page alone and it is parsed as
  /// it always was ([PostEditFormPage]). An answer the plugin could not tell the form of (`unknown`) is not read: the
  /// page is asked again without the parameters and parsed as the web page.
  ///
  /// The answer must be served to the account of this session: one served to another account, or to a guest, is
  /// [IdentityChangedException] (the `uid` of the answer, the `discuz_uid` of the page).
  AsyncEither<PostEditFormAnswer> fetchForm(String url) => AsyncEither(() async {
    if (!isCurrent) return left(IdentityChangedException());
    final result = await _get(withTsdmAppJson(url));
    if (!isCurrent) return left(IdentityChangedException());
    final Response<dynamic> response;
    switch (result) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        response = value;
    }
    if (response.statusCode != 200) return left(HttpRequestFailedException(response.statusCode));
    if (postFormAnswerOf(response.data) case final json?) {
      if (tsdmAppInt(json['uid']) != _ownerUid) return left(IdentityChangedException());
      final form = PostForm.fromJson(json);
      if (form == null) return right(PostEditFormRefused(tsdmAppText(json['message'])));
      TsdmAppApi.notePostForm();
      return right(PostEditFormApi(form));
    }
    if (tsdmAppAnswerJson(response.data) == null) {
      // The web page: a forum without the plugin, or with one older than 2.9.0. Read as it always was.
      if (response.data is! String) return left(HttpRequestFailedException(response.statusCode));
      final document = parseHtmlDocument(response.data as String);
      if (parseLoggedUidFromDocument(document) != _ownerUid) return left(IdentityChangedException());
      return right(PostEditFormPage(document));
    }
    // Another JSON answer (`unknown`: the plugin could not tell the form): the web page itself, as without the plugin.
    return (await fetchData(url).run()).map(PostEditFormPage.new);
  });

  /// [fetchForm] of the form of a new thread in forum [fid].
  AsyncEither<PostEditFormAnswer> prepareForm(String fid) => fetchForm(_buildThreadInfoUrl(fid));

  /// Post the post form [form] (plugin 2.9.0) once, with the member's [edits] over every served value
  /// ([PostForm.bodyWith]), to the url the forum gave (`submit.url`); the result is read as for the web page's form
  /// ([parseSubmissionResult]): the url of the thread, [expectedTid] for an edit.
  AsyncEither<String> submitForm(PostForm form, PostFormEdits edits, {String? expectedTid}) => AsyncEither(() async {
    final url = form.submitUrl;
    final body = form
        .bodyWith(
          PostFormEdits(
            message: toOfficialMentions(edits.message),
            subject: edits.subject,
            typeId: edits.typeId,
            perm: edits.perm,
            price: edits.price,
            options: edits.options,
            save: edits.save,
          ),
        )
        .toMap();
    if (url == null || body == null) {
      // Never offered for editing (PostForm.editorSupport): nothing is sent.
      return left(ThreadPublishLocationNotFoundException());
    }
    return _submit(url, body, expectedTid: expectedTid).run();
  });

  /// Fetch edit data from given [url].
  AsyncEither<uh.Document> fetchData(String url) => AsyncEither(() async {
    if (!isCurrent) return left(IdentityChangedException());
    final result = await _get(url);
    if (!isCurrent) return left(IdentityChangedException());
    return result.flatMap((response) {
      if (response.statusCode != 200 || response.data is! String) {
        return left(HttpRequestFailedException(response.statusCode));
      }
      final document = parseHtmlDocument(response.data as String);
      if (parseLoggedUidFromDocument(document) != _ownerUid) return left(IdentityChangedException());
      return right(document);
    });
  });

  AsyncEither<String> _submit(String url, Map<String, String> body, {String? expectedTid}) => AsyncEither(() async {
    if (!isCurrent) return left(IdentityChangedException());
    final result = await _post(url, body);
    if (!isCurrent) return left(IdentityChangedException());
    final Response<dynamic> response;
    switch (result) {
      case Left(:final value) when value is HttpHandshakeFailedException && [301, 302, 303].contains(value.statusCode):
        final target = submittedThreadUrl(value.headers?.value('location'), expectedTid: expectedTid);
        return target == null ? left(ThreadPublishLocationNotFoundException()) : right(target);
      case Left(:final value):
        return left(value);
      case Right(:final value):
        response = value;
    }
    // The forum asked for a captcha or a security question when the form was posted (plugin 2.6.0 result: a site
    // asking by the number of posts or their interval decides it then): nothing was posted.
    if (tsdmAppWriteResultOf(response.data)?.asksVerification ?? false) {
      return left(PostVerificationRequiredException());
    }
    final target = parseSubmissionResult(response, expectedTid: expectedTid);
    if (target != null) return right(target);
    // The forum's refusal: its 提示信息 page, or the write result of the forum's app API (plugin 2.6.0,
    // [tsdmAppWriteResultOf]) read as that page.
    final document =
        tsdmAppWriteResultOf(response.data)?.document ??
        (response.data is String ? parseHtmlDocument(response.data as String) : null);
    final message = document?.querySelector('#messagetext');
    if (message != null && !message.classes.contains('alert_right')) {
      return left(PostEditFailedToUploadResult(message.querySelector('p')?.innerText ?? ''));
    }
    return left(ThreadPublishLocationNotFoundException());
  });

  /// Post some edited content to server. The content is in a certain post, with
  /// additional options provided by server.
  ///
  /// What's more, when editing a thread (means the first floor post in some
  /// thread), additional [threadType] and [threadTitle] are required.
  ///
  /// All fields are strings; submit once with URL-encoded form data.
  ///
  /// [fid], [tid] and [pid] is used to specify the post we made modification.
  ///
  /// [data] is post content, now in plain text.
  ///
  /// [threadType] is the number (String) of thread type.
  ///
  /// [options] is a map of option-name - option-value pair.
  AsyncVoidEither postEditedContent({
    required String formHash,
    required String postTime,
    required String delattachop,
    required String wysiwyg,
    required String fid,
    required String tid,
    required String pid,
    required String page,
    required String? threadType,
    required String? threadTitle,
    required String data,
    required Map<String, String> options,
    required String save,
    required String? perm,
    required int? price,
    String tags = '',
  }) => AsyncVoidEither(() async {
    final body = <String, String>{
      'formhash': formHash,
      'posttime': postTime,
      'delattachop': delattachop,
      'wysiwyg': wysiwyg,
      'fid': fid,
      'tid': tid,
      'pid': pid,
      'checkbox': '0',
      'page': page,
      'subject': threadTitle ?? '',
      'message': toOfficialMentions(data),
      'editsubmit': 'true',
      'save': save,
      'tags': tags,
      'price': '${price ?? ""}',
    };
    if (threadType != null) {
      body['typeid'] = threadType;
    }
    if (perm != null) {
      body['readperm'] = perm;
    }

    for (final entry in options.entries) {
      body[entry.key] = entry.value;
    }
    return (await _submit(_postSubmitTarget, body, expectedTid: tid).run()).map((_) {});
  });

  /// Fetch required info that used in posting new thread.
  ///
  /// This step is far before posting final thread content to server.
  AsyncEither<uh.Document> prepareInfo(String fid) => fetchData(_buildThreadInfoUrl(fid));

  /// Post new thread data to server.
  ///
  /// Generally the serer will response a status code of 301 with location in
  /// header to redirect to published thread page.
  AsyncEither<String> postThread(ThreadPublishInfo info) =>
      _submit(_buildThreadPostUrl(info.fid), info.toPostPayload());
}

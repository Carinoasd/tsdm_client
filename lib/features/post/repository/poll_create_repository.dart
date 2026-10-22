import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/utils/new_thread_status.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// Result kind of [PollCreateRepository.fetchForm].
enum PollFormLoadKind {
  /// Supported form.
  ready,

  /// The forum answered with a message, e.g. no permission to create polls here.
  denied,

  /// Not understood: continue in the browser.
  unsupported,

  /// Served as guest: the same account must sign in again.
  loginRequired,

  /// Served to or requested by another account.
  identityChanged,

  /// Network or HTTP failure.
  failed,
}

/// Result of [PollCreateRepository.fetchForm].
final class PollFormLoad {
  /// Constructor.
  const PollFormLoad(this.kind, {this.form, this.message});

  /// Kind.
  final PollFormLoadKind kind;

  /// Form when ready.
  final PollCreateForm? form;

  /// Plain server message when denied.
  final String? message;
}

/// Result kind of [PollCreateRepository.preflight]; only [ready] may be followed by the POST.
enum PollPreflightKind {
  /// A fresh form still accepts the confirmed poll unchanged; post with its fields.
  ready,

  /// The fresh form's limits or offered settings changed the confirmed poll; review again.
  changed,

  /// The forum no longer offers the form, see [PollPreflight.message].
  denied,

  /// The fresh form is not understood; continue in the browser.
  unsupported,

  /// The fresh form was served as guest.
  loginRequired,

  /// Served to or requested by another account.
  identityChanged,

  /// Network or HTTP failure; nothing was posted and checking again is safe.
  failed,
}

/// Result of [PollCreateRepository.preflight].
final class PollPreflight {
  /// Constructor.
  const PollPreflight(this.kind, {this.form, this.message});

  /// Kind.
  final PollPreflightKind kind;

  /// Fresh form when [kind] is ready or changed.
  final PollCreateForm? form;

  /// Plain server message when denied.
  final String? message;
}

/// What is known after the single poll POST.
enum PollCreateOutcome {
  /// The thread is verified visible without status label.
  published,

  /// The forum says, or the header shows, that it awaits moderation.
  moderated,

  /// The forum explicitly refused; nothing was created.
  rejected,

  /// The request may have created a thread; do not send again automatically.
  unconfirmed,

  /// Nothing was sent because the account changed.
  identityChanged,
}

/// Result of [PollCreateRepository.submit].
final class PollCreateResult {
  /// Constructor.
  const PollCreateResult(this.outcome, {this.tid, this.message});

  /// Outcome.
  final PollCreateOutcome outcome;

  /// Thread id when known.
  final String? tid;

  /// Plain server message.
  final String? message;
}

/// Creates ordinary polls with one account-bound client for the page lifetime.
final class PollCreateRepository with LoggerMixin {
  /// Constructor.
  PollCreateRepository({required NetClientProvider client, required int? Function() currentUid})
    : this.withTransport(
        currentUid: currentUid,
        getPage: (url) => client.get(url).run(),
        sendForm: (url, body) => client.postForm(url, data: body, singleAttempt: true).run(),
      );

  /// Injectable transports; the submission is never retried.
  PollCreateRepository.withTransport({
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
  bool _ended = false;
  int _postsDispatched = 0;

  /// Permanent: switching back to the account never revives this session.
  void invalidate() => _invalidated = true;

  /// The page left: no further request starts. A request already sent is not cancelled.
  void end() => _ended = true;

  /// Whether the owning account is still the active one, whether or not the page left.
  bool get ownerActive => !_invalidated && _ownerUid != null && _ownerUid > 0 && _ownerUid == _currentUid();

  /// Whether the session may still send requests for the active account.
  bool get isCurrent => !_ended && ownerActive;

  /// Ignore repeated verification events for the same active account.
  bool belongsTo(int? uid) => ownerActive && uid == _ownerUid;

  /// Number of poll POSTs handed to the transport by this session; a dispatched POST may have reached the forum.
  int get postsDispatched => _postsDispatched;

  /// Poll creation form url offered by the forum page.
  static String formUrl(String fid) => '$baseUrl/forum.php?mod=post&action=newthread&fid=$fid&special=1';

  /// Fetch and validate the poll form of [fid].
  ///
  /// The form is asked in the JSON mode of the forum's app API ([withTsdmAppJson]). Plugin 2.9.0 answers it as a post
  /// form (`type: post`, `schema` 16), validated from its fields ([PollCreateForm.fromPostForm]; the choice limit is
  /// `poll.max_options`), or the forum's message instead of it; an older plugin, or none, leaves the page alone and it
  /// is parsed as it always was ([PollCreateForm.parse]). A post form with fields of another plugin
  /// ([PostForm.hookFields]: their values are not given), and an answer the plugin could not tell the form of
  /// (`unknown`), are read from the web page itself, asked again without the parameters: its parser knows the neutral
  /// fields of the site's poll plugin and leaves anything else to the browser.
  Future<PollFormLoad> fetchForm(String fid) async {
    if (!isCurrent) return const PollFormLoad(PollFormLoadKind.identityChanged);
    final result = await _get(withTsdmAppJson(formUrl(fid)));
    if (!isCurrent) return const PollFormLoad(PollFormLoadKind.identityChanged);
    final Response<dynamic> response;
    switch (result) {
      case Left():
        return const PollFormLoad(PollFormLoadKind.failed);
      case Right(:final value):
        response = value;
    }
    if (response.statusCode != 200) return const PollFormLoad(PollFormLoadKind.failed);
    if (postFormAnswerOf(response.data) case final json?) {
      final served = tsdmAppInt(json['uid']);
      if (served <= 0) return const PollFormLoad(PollFormLoadKind.loginRequired);
      if (served != _ownerUid) return const PollFormLoad(PollFormLoadKind.identityChanged);
      final form = PostForm.fromJson(json);
      if (form == null) return PollFormLoad(PollFormLoadKind.denied, message: tsdmAppText(json['message']));
      TsdmAppApi.notePostForm();
      if (form.hookFields.isEmpty) return _loadOf(PollCreateForm.fromPostForm(form, fid: fid, uid: served));
    } else if (tsdmAppAnswerJson(response.data) == null) {
      return _webForm(response, fid);
    }
    // Another plugin's fields, or the plugin could not tell the form: the web page itself.
    final page = await _get(formUrl(fid));
    if (!isCurrent) return const PollFormLoad(PollFormLoadKind.identityChanged);
    return switch (page) {
      Left() => const PollFormLoad(PollFormLoadKind.failed),
      Right(:final value) =>
        value.statusCode != 200 ? const PollFormLoad(PollFormLoadKind.failed) : _webForm(value, fid),
    };
  }

  /// The poll form of [fid] in the web page [response], parsed as it always was ([PollCreateForm.parse]).
  PollFormLoad _webForm(Response<dynamic> response, String fid) {
    if (response.data is! String) return const PollFormLoad(PollFormLoadKind.failed);
    final document = parseHtmlDocument(response.data as String);
    final served = parseLoggedUidFromDocument(document);
    if (served == null) return const PollFormLoad(PollFormLoadKind.loginRequired);
    if (served != _ownerUid) return const PollFormLoad(PollFormLoadKind.identityChanged);
    return _loadOf(PollCreateForm.parse(document, fid: fid, uid: served));
  }

  static PollFormLoad _loadOf(PollFormParse parsed) => switch (parsed.kind) {
    PollFormParseKind.ready => PollFormLoad(PollFormLoadKind.ready, form: parsed.form),
    PollFormParseKind.denied => PollFormLoad(PollFormLoadKind.denied, message: parsed.message),
    PollFormParseKind.unsupported => const PollFormLoad(PollFormLoadKind.unsupported),
  };

  /// GET a fresh form of the same forum and account and check that [submission] is still posted unchanged.
  ///
  /// Never posts; every non-ready result means nothing was sent.
  Future<PollPreflight> preflight(PollCreateForm confirmed, PollSubmission submission) async {
    if (confirmed.uid != _ownerUid) return const PollPreflight(PollPreflightKind.identityChanged);
    final load = await fetchForm(confirmed.fid);
    switch (load.kind) {
      case PollFormLoadKind.ready:
        final fresh = load.form!;
        if (fresh.uid != _ownerUid || fresh.fid != confirmed.fid) {
          return const PollPreflight(PollPreflightKind.identityChanged);
        }
        final fits = pollSubmissionFitsFreshForm(submission: submission, confirmed: confirmed, fresh: fresh);
        return PollPreflight(fits ? PollPreflightKind.ready : PollPreflightKind.changed, form: fresh);
      case PollFormLoadKind.denied:
        return PollPreflight(PollPreflightKind.denied, message: load.message);
      case PollFormLoadKind.unsupported:
        return const PollPreflight(PollPreflightKind.unsupported);
      case PollFormLoadKind.loginRequired:
        return const PollPreflight(PollPreflightKind.loginRequired);
      case PollFormLoadKind.identityChanged:
        return const PollPreflight(PollPreflightKind.identityChanged);
      case PollFormLoadKind.failed:
        return const PollPreflight(PollPreflightKind.failed);
    }
  }

  /// POST [submission] exactly once and classify the answer without ever resending.
  ///
  /// [form] must be the fresh form returned by [preflight]; the transport is invoked synchronously within this call.
  Future<PollCreateResult> submit(PollCreateForm form, PollSubmission submission) async {
    if (!isCurrent || form.uid != _ownerUid) return const PollCreateResult(PollCreateOutcome.identityChanged);
    _postsDispatched++;
    final result = await _post(form.actionUrl, submission.toPayload(form));

    final Response<dynamic> response;
    switch (result) {
      case Left(:final value) when value is HttpHandshakeFailedException && [301, 302, 303].contains(value.statusCode):
        return _verify(threadTidOf(value.headers?.value('location')));
      case Left():
        // The request may still have reached the forum.
        return const PollCreateResult(PollCreateOutcome.unconfirmed);
      case Right(:final value):
        response = value;
    }
    if ([301, 302, 303].contains(response.statusCode)) {
      return _verify(threadTidOf(response.headers.value('location')));
    }
    // The write result of the forum's app API (plugin 2.6.0): the redirect the forum would have answered is verified
    // by its target, a message or a page is read as the forum's page.
    final apiResult = response.statusCode == 200 ? tsdmAppWriteResultOf(response.data) : null;
    if (apiResult != null && apiResult.asksVerification) {
      // The forum asked for a captcha or a security question when the poll was posted: nothing was created.
      return PollCreateResult(PollCreateOutcome.rejected, message: t.postEditPage.verificationRequired);
    }
    if (apiResult != null && apiResult.kind == TsdmAppWriteKind.redirect) {
      return _verify(apiResult.login ? null : threadTidOf(apiResult.url));
    }
    if (response.statusCode != 200 || (apiResult == null && response.data is! String)) {
      return const PollCreateResult(PollCreateOutcome.unconfirmed);
    }

    final document = apiResult?.document ?? parseHtmlDocument(response.data as String);
    final message = document.querySelector('#messagetext');
    if (message != null) {
      final text = (message.querySelector('p') ?? message).innerText.trim();
      final tid = threadTidOf(message.querySelector('p.alert_btnleft a[href]')?.attributes['href']);
      // Upstream showmessage: `alert_right` = forward with a *_succeed message, `alert_error` = returnable
      // failure, `alert_info` = any other forward or note. Only an explicit error proves nothing was created.
      if (message.classes.contains('alert_error') && !message.classes.contains('alert_right')) {
        return PollCreateResult(PollCreateOutcome.rejected, message: text);
      }
      if (message.classes.contains('alert_right') && mentionsModeration(text)) {
        return PollCreateResult(PollCreateOutcome.moderated, tid: tid);
      }
      // Success, information or unknown class: verify a same-site thread link with a GET, never by posting again.
      return _verify(tid);
    }
    final canonical = threadTidOf(document.querySelector('head link[rel="canonical"]')?.attributes['href']);
    if (canonical != null && parseLoggedUidFromDocument(document) == _ownerUid) {
      return _classify(canonical, classifyNewThreadHeader(document, canonical));
    }
    return const PollCreateResult(PollCreateOutcome.unconfirmed);
  }

  /// GET the new thread as its author; a redirect or message link alone never proves publication.
  ///
  /// The thread page is asked in the JSON mode of the forum's app API. A structured answer (plugin 2.1.0,
  /// `schema: 3`) tells the account it was served to and the thread's state ([classifyNewThreadApi]); any other
  /// answer is the page, read as before: the account from its `discuz_uid`, the state from the header
  /// ([classifyNewThreadHeader]).
  Future<PollCreateResult> _verify(String? tid) async {
    if (tid == null) return const PollCreateResult(PollCreateOutcome.unconfirmed);
    if (!isCurrent) return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
    final result = await _get(withTsdmAppJson('$baseUrl/forum.php?mod=viewthread&tid=$tid'));
    if (!isCurrent) return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
    return result.match((_) => PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid), (response) {
      if (response.statusCode != 200) {
        return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
      }
      final api = threadApiAnswerOf(response.data);
      if (api != null) {
        if (threadApiViewerUid(api) != _ownerUid) {
          return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
        }
        return _classify(tid, classifyNewThreadApi(api, tid));
      }
      if (tsdmAppAnswerWithoutPage(response.data)) {
        return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
      }
      final document = tsdmAppPageDocument(response.data);
      if (parseLoggedUidFromDocument(document) != _ownerUid) {
        return PollCreateResult(PollCreateOutcome.unconfirmed, tid: tid);
      }
      return _classify(tid, classifyNewThreadHeader(document, tid));
    });
  }

  PollCreateResult _classify(String tid, NewThreadHeaderStatus status) => switch (status) {
    NewThreadHeaderStatus.visible => PollCreateResult(PollCreateOutcome.published, tid: tid),
    NewThreadHeaderStatus.moderating => PollCreateResult(PollCreateOutcome.moderated, tid: tid),
    NewThreadHeaderStatus.draft || NewThreadHeaderStatus.unknown => PollCreateResult(
      PollCreateOutcome.unconfirmed,
      tid: tid,
    ),
  };
}

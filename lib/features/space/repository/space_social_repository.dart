import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Writes on walls and sends greetings for one account, the one current when it was built.
///
/// As [SpaceWriteRepository]: every request goes on the account the repository was built for, never once another
/// account is current ([isCurrent]) or once [invalidate]d, and a page or form served to another account is never
/// posted. A post is sent once (single attempt): an answer that does not tell the outcome is
/// [SpaceWriteOutcome.unconfirmed], never sent again by itself.
///
/// Every post goes as the website's popups send it (`inajax=1`): the forum's app API (plugin 2.6.0) answers its
/// result as JSON ([tsdmAppWriteResultOf]), the forum without it the AJAX answer (`succeedhandle_…('url', 'message')`,
/// `errorhandle_…('message')`).
final class SpaceSocialRepository with LoggerMixin {
  /// Constructor.
  SpaceSocialRepository({required NetClientProvider client, required int? Function() currentUid})
    : this.withTransport(
        currentUid: currentUid,
        getPage: (url) => client.get(url).run(),
        sendForm: (url, body) => client.postForm(url, data: body, singleAttempt: true).run(),
      );

  /// Injectable transports; a post is never retried.
  SpaceSocialRepository.withTransport({
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

  /// Nothing more is sent, even when the account comes back.
  void invalidate() => _invalidated = true;

  /// Whether requests may still go out for the account this repository belongs to.
  bool get isCurrent => !_invalidated && _ownerUid != null && _ownerUid > 0 && _ownerUid == _currentUid();

  /// Where a wall message, or a reply to one, is posted.
  static const commentSubmitUrl = '$baseUrl/home.php?mod=spacecp&ac=comment&inajax=1';

  /// Where the message [cid] is deleted.
  static String commentDeleteUrl(int cid) => '$baseUrl/home.php?mod=spacecp&ac=comment&op=delete&cid=$cid&inajax=1';

  /// The poke form for [uid]: a greeting, or one back ([reply]) to a greeting received from them.
  static String pokeFormUrl(int uid, {bool reply = false}) =>
      '$baseUrl/home.php?mod=spacecp&ac=poke&op=${reply ? 'reply' : 'send'}&uid=$uid';

  /// Where a greeting to [uid] is sent.
  static String pokeSubmitUrl(int uid, {bool reply = false}) => '${pokeFormUrl(uid, reply: reply)}&inajax=1';

  /// Where the greetings received from [uid] are ignored; all of them without [uid].
  static String pokeIgnoreUrl({int? uid}) =>
      '$baseUrl/home.php?mod=spacecp&ac=poke&op=ignore${uid == null ? '' : '&uid=$uid'}&inajax=1';

  /// The fields posting [message] to the wall of [ownerUid] send; a reply to the message [replyTo] goes, quoted, to the
  /// wall of that message's author (`note_wall_reply_success`: "已经回复到NAME的留言板").
  static Map<String, String> wallBody(SpaceSession session, int ownerUid, String message, {int? replyTo}) => {
    'formhash': session.formHash,
    'id': '$ownerUid',
    'idtype': 'uid',
    'commentsubmit': 'true',
    'message': message.trim(),
    if (replyTo != null) ...{
      'cid': '$replyTo',
      'handlekey': 'replycommenthk_$replyTo',
    } else ...{
      'quickcomment': 'true',
      'handlekey': 'qcwall_$ownerUid',
    },
  };

  /// Post [message] to the wall of [ownerUid] with the [session] of its page, once; [replyTo] replies to that
  /// message of the account's own wall.
  Future<SpaceWriteResult> postWall(SpaceSession session, int ownerUid, String message, {int? replyTo}) async {
    if (!isCurrent || session.uid != _ownerUid) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return _outcome(await _post(commentSubmitUrl, wallBody(session, ownerUid, message, replyTo: replyTo)));
  }

  /// Delete the wall message [cid] with the [session] of its page, once: the forum takes it from its author, the
  /// owner of the wall and a moderator of comments (`no_privilege_comment_del` otherwise).
  Future<SpaceWriteResult> deleteWall(SpaceSession session, int cid) async {
    if (!isCurrent || session.uid != _ownerUid) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return _outcome(
      await _post(commentDeleteUrl(cid), {
        'formhash': session.formHash,
        'deletesubmit': 'true',
        'handlekey': 'delcommenthk_$cid',
      }),
    );
  }

  /// Load the poke form for [uid] ([reply] to greet back); the forum refuses here already for the account itself
  /// (`not_to_their_own_greeted`), without the permission (`no_privilege_poke`), or with friends switched off.
  ///
  /// The whole page, not the popup: it names the account it was served to.
  Future<SpaceFormLoad<PokeForm>> loadPokeForm(int uid, {bool reply = false}) async {
    if (!isCurrent) return const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
    final result = await _get(withTsdmAppJson(pokeFormUrl(uid, reply: reply)));
    if (!isCurrent) return const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
    final Response<dynamic> response;
    switch (result) {
      case Left(:final value):
        error('failed to load the poke form: $value');
        return const SpaceFormLoad(SpaceFormLoadKind.failed);
      case Right(:final value):
        response = value;
    }
    if (response.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(response.data)) {
      return const SpaceFormLoad(SpaceFormLoadKind.failed);
    }
    final page = parsePokeForm(tsdmAppPageDocument(response.data), reply: reply);
    if (page.form case final form?) {
      return form.uid == _ownerUid
          ? SpaceFormLoad(SpaceFormLoadKind.ready, form: form)
          : const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
    }
    if (page.needLogin) return const SpaceFormLoad(SpaceFormLoadKind.loginRequired);
    if (page.message case final String message when message.isNotEmpty) {
      return SpaceFormLoad(SpaceFormLoadKind.denied, message: message);
    }
    return const SpaceFormLoad(SpaceFormLoadKind.failed);
  }

  /// Send the greeting [iconId] (a [PokeIcon.id] of [form]) with [note] to the member of [form], once.
  ///
  /// The forum keeps the beginning of the note only (`cutstr` to 30: about 15 Chinese characters).
  Future<SpaceWriteResult> sendPoke(PokeForm form, String iconId, String note) async {
    if (!isCurrent || form.uid != _ownerUid) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return _outcome(
      await _post(pokeSubmitUrl(form.targetUid, reply: form.reply), {
        'formhash': form.formHash,
        'pokesubmit': 'true',
        'iconid': iconId,
        'note': note.trim(),
        'from': '',
        'handlekey': form.reply ? 'pokereply' : 'propokehk_${form.targetUid}',
      }),
    );
  }

  /// Ignore the greetings received from [uid] (all of them without [uid]) with the [session] of the list, once.
  Future<SpaceWriteResult> ignorePokes(SpaceSession session, {int? uid}) async {
    if (!isCurrent || session.uid != _ownerUid) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return _outcome(
      await _post(pokeIgnoreUrl(uid: uid), {
        'formhash': session.formHash,
        'ignoresubmit': 'true',
        'handlekey': uid == null ? 'allignore' : 'pokeignore',
      }),
    );
  }

  static final _succeedRe = RegExp(r"succeedhandle_\w*\('[^']*',\s*'([^']*)'");
  static final _errorRe = RegExp(r"errorhandle_\w*\('([^']*)'");

  /// What the answer [result] of a post tells.
  SpaceWriteResult _outcome(SyncEither<Response<dynamic>> result) {
    final Response<dynamic> response;
    switch (result) {
      case Left(:final value):
        // The request may still have reached the forum.
        error('post failed, result unknown: $value');
        return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
      case Right(:final value):
        response = value;
    }
    if (response.statusCode != HttpStatus.ok) {
      return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
    }
    if (tsdmAppWriteResultOf(response.data) case final api?) {
      if (api.asksVerification) {
        return SpaceWriteResult(SpaceWriteOutcome.rejected, message: t.postEditPage.verificationRequired);
      }
      if (api.login) {
        return SpaceWriteResult(SpaceWriteOutcome.loginRequired, message: api.reason);
      }
      if (api.kind != TsdmAppWriteKind.page && api.succeeded) {
        return SpaceWriteResult(SpaceWriteOutcome.done, message: api.message.isEmpty ? null : api.message);
      }
      if (api.isError || (api.kind != TsdmAppWriteKind.page && !api.ok)) {
        return SpaceWriteResult(SpaceWriteOutcome.rejected, message: api.reason);
      }
      return SpaceWriteResult(SpaceWriteOutcome.unconfirmed, message: api.reason.isEmpty ? null : api.reason);
    }
    final text = tsdmAppAnswerText(response.data);
    if (_succeedRe.firstMatch(text)?.group(1)?.trim() case final String message) {
      return SpaceWriteResult(SpaceWriteOutcome.done, message: message.isEmpty ? null : message);
    }
    if (_errorRe.firstMatch(text)?.group(1)?.trim() case final String message) {
      return SpaceWriteResult(SpaceWriteOutcome.rejected, message: message.isEmpty ? null : message);
    }
    return const SpaceWriteResult(SpaceWriteOutcome.unconfirmed);
  }
}

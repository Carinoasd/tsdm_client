import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_account_repository.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// Writes on walls and sends greetings for one account, the one current when it was built
/// ([SpaceAccountRepository]).
final class SpaceSocialRepository extends SpaceAccountRepository {
  /// Constructor.
  SpaceSocialRepository({required super.client, required super.currentUid});

  /// Injectable transports; a post is never retried.
  SpaceSocialRepository.withTransport({required super.currentUid, required super.getPage, required super.sendForm})
    : super.withTransport();

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
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(await sendForm(commentSubmitUrl, wallBody(session, ownerUid, message, replyTo: replyTo)));
  }

  /// Delete the wall message [cid] with the [session] of its page, once: the forum takes it from its author, the
  /// owner of the wall and a moderator of comments (`no_privilege_comment_del` otherwise).
  Future<SpaceWriteResult> deleteWall(SpaceSession session, int cid) async {
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(
      await sendForm(commentDeleteUrl(cid), {
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
    final result = await getPage(withTsdmAppJson(pokeFormUrl(uid, reply: reply)));
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
      return form.uid == ownerUid
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
    if (!isCurrent || form.uid != ownerUid) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(
      await sendForm(pokeSubmitUrl(form.targetUid, reply: form.reply), {
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
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(
      await sendForm(pokeIgnoreUrl(uid: uid), {
        'formhash': session.formHash,
        'ignoresubmit': 'true',
        'handlekey': uid == null ? 'allignore' : 'pokeignore',
      }),
    );
  }
}

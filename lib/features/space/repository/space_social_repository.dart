import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_account_repository.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

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
  ///
  /// Plugin 4.0.0 answers the window as a small form (`poke`, [pokeFormFromApi]) when its `status` lists it; anything
  /// else of it reads the page as before.
  Future<SpaceFormLoad<PokeForm>> loadPokeForm(int uid, {bool reply = false}) async {
    if (!isCurrent) return const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
    if (getIt.isRegistered<NetClientProvider>()) {
      await TsdmAppApi.ensureStatus(getIt.get<NetClientProvider>());
    }
    if (TsdmAppV4.has(TsdmAppV4Group.forms, SmallFormKind.poke.name)) {
      final window = withTsdmAppV4Form(
        '${pokeFormUrl(uid, reply: reply)}&handlekey=${reply ? 'pokereply' : 'propokehk_$uid'}&infloat=yes&inajax=1',
      );
      final answer = await getPage(window);
      if (!isCurrent) return const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
      if (answer case Right(:final value) when value.statusCode == HttpStatus.ok) {
        if (pokeFormFromApi(value.data, viewer: ownerUid!, targetUid: uid, reply: reply) case final load?) {
          return load;
        }
      }
    }
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
    if (form case PokeForm(submitUrl: final url?, submitFields: final fields?)) {
      // Plugin 4.0.0: the window's own fields back as served, once; `poke_success` is the forum's success.
      final sent = await sendForm(withTsdmAppV4Write(withSmallFormInAjax(url)), {
        ...fields,
        'iconid': iconId,
        'note': note.trim(),
      });
      if (pokeOutcomeFromApi(sent, uid: ownerUid!) case final outcome?) {
        return outcome;
      }
      // No verdict by its key: the answer still tells a refusal or the login prompt, never a success on `ok` alone.
      final fallback = outcomeOf(sent);
      return fallback.outcome == SpaceWriteOutcome.done
          ? const SpaceWriteResult(SpaceWriteOutcome.unconfirmed)
          : fallback;
    }
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

/// The poke window of plugin 4.0.0 [data] (small form `poke`) for member [targetUid] ([reply] to greet back), asked by
/// account [viewer]: the form, or the forum's refusal (oneself, no permission, the member's blacklist, log in first).
/// Null for anything else, read as the web page instead: another answer, a form for another member or another `op`,
/// posting elsewhere, without a `formhash` or greetings, a refusal without a message.
SpaceFormLoad<PokeForm>? pokeFormFromApi(
  Object? data, {
  required int viewer,
  required int targetUid,
  required bool reply,
}) {
  final answer = smallFormAnswerOf(data, SmallFormKind.poke);
  switch (answer) {
    case null:
      return null;
    case SmallFormMessage(:final login) when login || answer.uid == 0:
      return const SpaceFormLoad(SpaceFormLoadKind.loginRequired);
    case _ when !answer.servedTo(viewer):
      return const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
    case SmallFormMessage(:final message):
      return message.isEmpty ? null : SpaceFormLoad(SpaceFormLoadKind.denied, message: message);
    case final SmallFormFields form:
      final json = form.json;
      final op = reply ? 'reply' : 'send';
      final url = form.submitUrl('home.php', {'mod': 'spacecp', 'ac': 'poke', 'op': op, 'uid': '$targetUid'});
      final fields = form.submitFields;
      final icon = tsdmAppMap(json['iconid']);
      final icons = [
        for (final c in tsdmAppList(icon['choices']))
          if (tsdmAppText(c['value']) case final String id when id.isNotEmpty)
            PokeIcon(
              id: id,
              label: tsdmAppText(c['label']).trim(),
              imageUrl: tsdmAppText(c['icon']).isEmpty ? null : tsdmAppText(c['icon']),
            ),
      ];
      if (json['op'] != op ||
          tsdmAppInt(json['touid']) != targetUid ||
          url == null ||
          !form.usable ||
          fields['pokesubmit'] == null ||
          (fields['formhash'] ?? '').isEmpty ||
          icons.isEmpty) {
        return null;
      }
      final selected = tsdmAppText(icon['value']);
      final name = tsdmAppText(json['username']).trim();
      return SpaceFormLoad(
        SpaceFormLoadKind.ready,
        form: PokeForm(
          uid: viewer,
          targetUid: targetUid,
          targetName: name.isEmpty ? null : name,
          formHash: fields['formhash']!,
          icons: icons,
          selected: icons.any((e) => e.id == selected) ? selected : icons.first.id,
          reply: reply,
          submitUrl: url,
          submitFields: fields,
        ),
      );
  }
}

/// What the answer [result] to a poke of plugin 4.0.0 posted for account [uid] tells by its `message_key`: done for
/// `poke_success`, the forum's refusal for any other key; null when it carries no write result (the caller reads it
/// as before).
SpaceWriteResult? pokeOutcomeFromApi(SyncEither<Response<dynamic>> result, {required int uid}) {
  final Response<dynamic> response;
  switch (result) {
    case Left():
      return null;
    case Right(:final value):
      response = value;
  }
  final TsdmAppWriteResult api;
  switch (tsdmAppV4WriteOutcomeOf(response.data)) {
    case TsdmAppV4Written(:final result):
      api = result;
    case _:
      return null;
  }
  if (api.login) {
    return SpaceWriteResult(SpaceWriteOutcome.loginRequired, message: api.reason);
  }
  if (api.uid != uid) {
    return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
  }
  if (api.messageKey == 'poke_success') {
    return SpaceWriteResult(SpaceWriteOutcome.done, message: api.message.isEmpty ? null : api.message);
  }
  if (api.messageKey.isNotEmpty) {
    return SpaceWriteResult(SpaceWriteOutcome.rejected, message: api.reason);
  }
  return null;
}

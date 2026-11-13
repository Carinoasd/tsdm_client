/// A change sent to a page of the moderation panel the account's group may not use: the plugin answers
/// `{"ok":0,"error":"modcp_noperm"}` without words or page (recorded on the test forum: a forum moderator approving
/// new members, `forum.php?mod=modcp&action=moderate&op=members&tsdmapp=json&tsdmv=4`). The app tells "no permission"
/// instead of its plain "failed", for every change of the panel's pages of plugin 4.0.0 (`tsdmv=4`: the new members,
/// the moderation queue, a ban, and the others sent through the same reader) and those of 3.9.0 alike.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/modcp_v4.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

import 'tsdmapp_v4_fake.dart';

const _mod = 33;

/// The plugin's "no permission" served to [uid].
Map<String, dynamic> _noperm(int uid) => {'ok': 0, 'error': 'modcp_noperm', 'uid': uid, 'formhash': 'f1f2f3f4'};

ModerateGet _getter(Object? data) =>
    (_) async => data == null ? left(HttpRequestFailedException(null)) : right((statusCode: 200, data: data));

ModeratePost _poster(Object? data, List<String> posted) => (url, _) async {
  posted.add(url);
  return right((statusCode: 200, data: data));
};

void main() {
  setUpAll(() async {
    registerV4TestServices();
    await LocaleSettings.setLocale(AppLocale.en);
  });
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  test('plugin 4.0.0: new members approved without the permission', () async {
    knowV4Status();
    final json = jsonDecode(jsonEncode(v4Json('g2_modcp_q_threads_2.json'))) as Map<String, dynamic>;
    json['op'] = 'members';
    json['fid'] = 0;
    json['items'] = null;
    json['uid'] = _mod;
    json['members'] = [
      {
        'uid': 120,
        'username': 'newbie',
        'regdate': 1794511524,
        'regip': '198.51.100.4',
        'email': '',
        'message': '',
        'submittimes': 1,
        'submitdate': 1794511524,
        'admin': '',
        'moddate': 0,
        'can_delete': 1,
      },
    ];
    final list = memberReviewFromApi(json, uid: _mod)!;
    final posted = <String>[];
    final outcome = await ModcpRepository(
      get: _getter(null),
      post: _poster(_noperm(_mod), posted),
      currentUid: () => _mod,
    ).submitMemberReview(list, MemberReviewAction.validate, ['120']).run();
    expect(
      outcome.getRight().toNullable(),
      isA<ModcpWriteRefused>().having((e) => e.message, 'message', t.modcp.noPermission),
    );
    expect(posted.single, contains('tsdmv=4'));
  });

  test('plugin 4.0.0: the moderation queue and a ban without the permission', () {
    expect(
      ModerateRepository.queueV4OutcomeOf(_noperm(_mod), uid: _mod).getRight().toNullable(),
      isA<ModerateRefused>().having((e) => e.message, 'message', t.modcp.noPermission),
    );
    expect(
      ModerateRepository.memberBanV4OutcomeOf(_noperm(_mod), uid: _mod).getRight().toNullable(),
      isA<MemberBanRefused>().having((e) => e.message, 'message', t.modcp.noPermission),
    );
    // Served to another account: dropped as before.
    expect(
      ModerateRepository.queueV4OutcomeOf(_noperm(70), uid: _mod).getLeft().toNullable(),
      isA<IdentityChangedException>(),
    );
  });

  test('plugin 3.9.0: a note added without the permission', () async {
    final home = modcpHomeFromApi({
      ...jsonDecode(File('test/data/tsdmapp_390/modcp_home.json').readAsStringSync()) as Map<String, dynamic>,
      'uid': _mod,
    })!;
    final posted = <String>[];
    final get = _getter(null);
    final post = _poster(_noperm(_mod), posted);
    final sent = await ModcpPagesRepository(
      panel: ModcpRepository(get: get, post: post, currentUid: () => _mod),
      get: get,
      post: post,
      currentUid: () => _mod,
    ).addNote(home, message: '交接', toSupermod: true, toModerator: true, days: 30).run();
    expect(
      sent.getRight().toNullable()?.outcome,
      isA<ModcpWriteRefused>().having((e) => e.message, 'message', t.modcp.noPermission),
    );
    expect(posted, hasLength(1));
  });

  test('plugin 3.9.0: the words of a page it attaches are kept', () {
    final answer = ModcpPagesRepository.pageOf<ModcpHome>(
      {
        ..._noperm(_mod),
        'document': '<html><body><div id="messagetext" class="alert_error"><p>论坛的原话</p></div></body></html>',
      },
      uid: _mod,
      read: modcpHomeFromApi,
    );
    expect(
      answer.getRight().toNullable(),
      isA<ModcpRefused<ModcpHome>>().having((e) => e.message, 'message', '论坛的原话'),
    );
  });
}

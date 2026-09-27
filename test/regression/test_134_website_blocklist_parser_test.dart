import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/website_blocklist_repository.dart';
import 'package:tsdm_client/instance.dart';

import 'fixtures/website_blocklist_fixtures.dart';

/// Website blacklist (#126, the forum's `blockuser` plugin page): parsing the list, the quota, the lookup and the
/// add / remove forms in the observed structure, failing closed on anything that is not exactly that. All pages are
/// synthetic (see the fixtures for what is observed and what is made up).
WebsiteBlocklistDocument _parse(String raw, {int? lookup}) =>
    parseWebsiteBlocklistDocument(raw, expectedUid: blocklistOwner, lookupUid: lookup);

WebsiteBlocklistFailure _failureOf(String raw, {int? lookup}) {
  try {
    _parse(raw, lookup: lookup);
  } on WebsiteBlocklistRejected catch (e) {
    return e.failure;
  }
  fail('page was accepted');
}

String _listPage(List<String> rows, {String? quota = 'default', String extra = ''}) => blocklistPage(
  rows: rows,
  quota: quota == 'default' ? blocklistQuota(rows.length, 10) : quota,
  extra: extra,
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('list', () {
    test('every row, its name and its remove form are read; layout links are not rows', () {
      final page = _parse(_listPage([blocklistRow(2001, 'Alpha'), blocklistRow(2002, 'Bravo')]));
      expect(page.list.rows.map((e) => (e.uid, e.username, e.removable)), [
        (2001, 'Alpha', true),
        (2002, 'Bravo', true),
      ]);
      expect(page.list.ownerUid, blocklistOwner);
      expect(page.list.complete, isTrue);
      expect(page.list.contains(4242), isFalse, reason: 'the sidebar friend is not on the list');
    });

    test('the quota is read from the page with either slash, not assumed', () {
      final rows = [blocklistRow(2001, 'Alpha'), blocklistRow(2002, 'Bravo')];
      final wide = _parse(_listPage(rows, quota: '已屏蔽 2／25 人'));
      expect((wide.list.quota?.used, wide.list.quota?.limit), (2, 25));
      final ascii = _parse(_listPage(rows, quota: '已屏蔽 2/25 人'));
      expect((ascii.list.quota?.used, ascii.list.quota?.limit), (2, 25));
    });

    test('an unknown count is not a complete list', () {
      for (final quota in [null, '已屏蔽 2 人', '已屏蔽 2／0 人', '1／10 2／10']) {
        final page = _parse(_listPage([blocklistRow(2001, 'Alpha'), blocklistRow(2002, 'Bravo')], quota: quota));
        expect(page.list.quota, isNull, reason: quota);
        expect(page.list.complete, isFalse, reason: quota);
      }
      final empty = _parse(_listPage([], quota: null));
      expect(empty.list.rows, isEmpty);
      expect(empty.list.complete, isFalse, reason: 'no rows and no count is not an empty list');
    });

    test('an empty list is only reported for the plugin page with its list table', () {
      final empty = _parse(_listPage([]));
      expect(empty.list.rows, isEmpty);
      expect(empty.list.complete, isTrue);

      // A normal page of the account without the plugin is not an empty list.
      expect(_failureOf(blocklistDocument('<p>插件未启用</p>')), WebsiteBlocklistFailure.unsupported);
      // The plugin page without its list table is not an empty list either.
      final listTable = RegExp('<table id="bu_list".*?</table>', dotAll: true);
      expect(_failureOf(_listPage([]).replaceAll(listTable, '')), WebsiteBlocklistFailure.unsupported);
      // Nor another table in its place.
      final otherTable = _listPage([], extra: '<table class="dt"><tbody></tbody></table>').replaceAll(listTable, '');
      expect(_failureOf(otherTable), WebsiteBlocklistFailure.unsupported);
      // Two plugin containers are not understood.
      expect(
        _failureOf(_listPage([]).replaceFirst('<div id="ft">', '<div id="bu_page"></div><div id="ft">')),
        WebsiteBlocklistFailure.unsupported,
      );
    });

    test('a count that does not match the rows, or pages, make the list incomplete', () {
      final miscounted = _parse(_listPage([blocklistRow(2001, 'Alpha')], quota: blocklistQuota(3, 10)));
      expect(miscounted.list.complete, isFalse);

      final paged = _parse(_listPage([blocklistRow(2001, 'Alpha')], extra: '<div class="pg"><a href="#">2</a></div>'));
      expect(paged.list.complete, isFalse);
    });

    for (final (name, row) in [
      ('another uid in the row id', blocklistRow(2001, 'Alpha', rowUid: '2002')),
      ('another uid in the link', blocklistRow(2001, 'Alpha', linkUid: '2002')),
      ('another uid in the label', blocklistRow(2001, 'Alpha', labelUid: '2002')),
      ('a hexadecimal uid in the link', blocklistRow(2001, 'Alpha', linkUid: '0x7d1')),
      ('a repeated uid in the link', blocklistRow(2001, 'Alpha', linkUid: '2001&amp;uid=2002')),
      ('no row id', blocklistRow(2001, 'Alpha').replaceFirst(' id="bu_row_2001"', '')),
      ('no uid label', blocklistRow(2001, 'Alpha').replaceFirst('<span class="bu-uid">UID 2001</span>', '')),
      ('a missing cell', blocklistRow(2001, 'Alpha').replaceFirst('<td>2026-09-01</td>', '')),
      (
        'a second user',
        blocklistRow(
          2001,
          'Alpha',
        ).replaceFirst('<td>2026-09-01', '<td><a href="home.php?mod=space&amp;uid=2002">x</a>'),
      ),
      ('the account itself', blocklistRow(blocklistOwner, 'Self')),
      ('an unrelated row', '<tr><td colspan="3"><a href="home.php?mod=space&amp;uid=2001">Alpha</a></td></tr>'),
    ]) {
      test('a row with $name refuses the page', () {
        expect(_failureOf(_listPage([row], quota: null)), WebsiteBlocklistFailure.unsupported);
      });
    }

    test('a user listed twice refuses the page', () {
      expect(
        _failureOf(_listPage([blocklistRow(2001, 'Alpha'), blocklistRow(2001, 'Alpha')])),
        WebsiteBlocklistFailure.unsupported,
      );
    });

    test('pages of another account, guests, challenges and forum errors are refused', () {
      expect(
        _failureOf(blocklistPage(uid: 1001, quota: blocklistQuota(0, 10))),
        WebsiteBlocklistFailure.accountMismatch,
      );
      expect(
        _failureOf('<html><body><form id="lsform"></form>$blocklistLookupForm</body></html>'),
        WebsiteBlocklistFailure.notLoggedIn,
      );
      expect(
        _failureOf('<html><head><title>Just a moment...</title></head><body></body></html>'),
        WebsiteBlocklistFailure.challenge,
      );
      expect(
        _failureOf(blocklistDocument('<div class="alert_error">synthetic refusal</div>')),
        WebsiteBlocklistFailure.forumError,
      );
    });

    test('a cut off page is refused', () {
      final raw = _listPage([blocklistRow(2001, 'Alpha')]);
      expect(_failureOf(raw.substring(0, raw.length - 20)), WebsiteBlocklistFailure.unsupported);
    });
  });

  group('lookup form', () {
    test('the observed GET form with hidden routing is the plugin page; without it the list is still read', () {
      expect(_parse(_listPage([blocklistRow(2001, 'Alpha')])).list.rows, hasLength(1));
      final without = blocklistPage(rows: [blocklistRow(2001, 'Alpha')], quota: blocklistQuota(1, 10), lookupForm: '');
      expect(_parse(without).list.rows, hasLength(1));
    });

    for (final (name, form) in [
      (
        'routing in the action as well',
        blocklistLookupForm.replaceFirst('action="home.php"', 'action="home.php?mod=spacecp&amp;ac=plugin"'),
      ),
      (
        'a repeated hidden field',
        blocklistLookupForm.replaceFirst('</form>', '<input type="hidden" name="id" value="other:spacecp" /></form>'),
      ),
      ('another plugin', blocklistLookupForm.replaceFirst('blockuser:spacecp', 'other:spacecp')),
      ('another host', blocklistLookupForm.replaceFirst('action="home.php"', 'action="https://example.com/home.php"')),
      ('a POST method', blocklistLookupForm.replaceFirst('method="get"', 'method="post"')),
      ('no query box', blocklistLookupForm.replaceFirst('name="bu_q"', 'name="q"')),
    ]) {
      test('a lookup form with $name is not understood', () {
        final raw = blocklistPage(rows: [blocklistRow(2001, 'Alpha')], quota: blocklistQuota(1, 10), lookupForm: form);
        expect(_failureOf(raw), WebsiteBlocklistFailure.unsupported);
      });
    }
  });

  group('remove forms', () {
    test('the payload is exactly the served fields, bound to exactly the row', () {
      final page = _parse(_listPage([blocklistRow(2001, 'Alpha'), blocklistRow(2002, 'Bravo')]));
      expect(page.removePayload(2001), {
        'formhash': blocklistToken,
        'blockuserdel': blocklistRemoveFlag,
        'buid': '2001',
      });
      expect(page.actionOf(add: false, uid: 2001).toString(), websiteBlocklistUrl);
      expect(page.removePayload(2003), isNull, reason: 'no form for a user not listed');
      expect(page.addPayload(2001), isNull, reason: 'a remove form is never used to add');
    });

    const addFlag = '<input type="hidden" name="blockuseradd" value="$blocklistAddFlag" />';
    for (final (name, row) in [
      ('a blank token', blocklistRow(2001, 'Alpha', token: '')),
      ('a blank target', blocklistRow(2001, 'Alpha', targetValue: '')),
      ('another target', blocklistRow(2001, 'Alpha', targetValue: '2002')),
      ('a hexadecimal target', blocklistRow(2001, 'Alpha', targetValue: '0x7d1')),
      ('a blank flag', blocklistRow(2001, 'Alpha', flagValue: '')),
      ('the add flag', blocklistRow(2001, 'Alpha', flagName: 'blockuseradd')),
      ('both flags', blocklistRow(2001, 'Alpha', extraFields: addFlag)),
      ('an unknown field', blocklistRow(2001, 'Alpha', extraFields: '<input type="hidden" name="op" value="x" />')),
      ('a text field', blocklistRow(2001, 'Alpha', extraFields: '<input type="text" name="note" value="" />')),
      (
        'a repeated field',
        blocklistRow(2001, 'Alpha', extraFields: '<input type="hidden" name="buid" value="2001" />'),
      ),
      (
        'a named submit button',
        blocklistRow(2001, 'Alpha', button: '<button type="submit" name="go" value="1">解除</button>'),
      ),
      (
        'two submit buttons',
        blocklistRow(2001, 'Alpha', button: '<button type="submit">a</button><button type="submit">b</button>'),
      ),
      ('no submit button', blocklistRow(2001, 'Alpha', button: '')),
      (
        'a disabled field',
        blocklistRow(2001, 'Alpha', extraFields: '<input type="hidden" name="x" value="y" disabled />'),
      ),
      (
        'a foreign action',
        blocklistRow(
          2001,
          'Alpha',
          action: 'https://example.com/home.php?mod=spacecp&amp;ac=plugin&amp;id=blockuser:spacecp',
        ),
      ),
      (
        'another plugin',
        blocklistRow(2001, 'Alpha', action: 'home.php?mod=spacecp&amp;ac=plugin&amp;id=other:spacecp'),
      ),
      ('a repeated parameter', blocklistRow(2001, 'Alpha', action: '$blocklistAction&amp;id=blockuser:spacecp')),
      ('a target in the action', blocklistRow(2001, 'Alpha', action: '$blocklistAction&amp;buid=2002')),
      ('a GET method', blocklistRow(2001, 'Alpha').replaceFirst('method="post"', 'method="get"')),
      ('an unknown form class', blocklistRow(2001, 'Alpha').replaceFirst('class="bu-delform"', 'class="x"')),
    ]) {
      test('a row with $name is listed but can not be removed here', () {
        final page = _parse(_listPage([row]));
        expect(page.list.rows.single.uid, 2001);
        expect(page.list.rows.single.removable, isFalse);
        expect(page.removePayload(2001), isNull);
        expect(page.actionOf(add: false, uid: 2001), isNull);
      });
    }
  });

  group('lookup', () {
    String lookupPage(String confirmation, {List<String> rows = const []}) =>
        blocklistPage(rows: rows, quota: blocklistQuota(rows.length, 10), confirmation: confirmation);

    test('the returned member and its add form are read from the confirmation', () {
      final page = _parse(lookupPage(blocklistConfirmation(2003, 'Charlie')), lookup: 2003);
      final found = page.lookup!;
      expect((found.uid, found.username, found.alreadyListed, found.canAdd), (2003, 'Charlie', false, true));
      expect(page.addPayload(2003), {'formhash': blocklistToken, 'blockuseradd': blocklistAddFlag, 'buid': '2003'});
      expect(page.actionOf(add: true, uid: 2003).toString(), websiteBlocklistUrl);
      expect(page.addPayload(2004), isNull);
      expect(page.list.contains(2003), isFalse, reason: 'the lookup result is not a list row');
    });

    test('a confirmation is ignored when no lookup was asked', () {
      final page = _parse(lookupPage(blocklistConfirmation(2003, 'Charlie')));
      expect((page.lookup, page.addPayload(2003)), (null, null));
    });

    test('a member already on the list is reported as such, without an add', () {
      final page = _parse(lookupPage('', rows: [blocklistRow(2003, 'Charlie')]), lookup: 2003);
      expect((page.lookup!.alreadyListed, page.lookup!.canAdd, page.lookup!.username), (true, false, 'Charlie'));
      final shown = _parse(
        lookupPage(blocklistConfirmation(2003, 'Charlie'), rows: [blocklistRow(2003, 'Charlie')]),
        lookup: 2003,
      );
      expect((shown.lookup!.alreadyListed, shown.lookup!.canAdd, shown.addPayload(2003)), (true, false, null));
    });

    test('no confirmation is no result', () {
      expect(_parse(lookupPage('<p>找不到</p>'), lookup: 2003).lookup, isNull);
    });

    const removeFlag = '<input type="hidden" name="blockuserdel" value="$blocklistRemoveFlag" />';
    for (final (name, confirmation) in [
      ('no form', blocklistConfirmation(2003, 'Charlie', withForm: false)),
      ('a blank token', blocklistConfirmation(2003, 'Charlie', token: '')),
      ('a blank target', blocklistConfirmation(2003, 'Charlie', targetValue: '')),
      ('the remove flag', blocklistConfirmation(2003, 'Charlie', flagName: 'blockuserdel')),
      ('both flags', blocklistConfirmation(2003, 'Charlie', extraFields: removeFlag)),
      (
        'a named submit button',
        blocklistConfirmation(2003, 'Charlie', button: '<button type="submit" name="ok" value="1">x</button>'),
      ),
      ('a target in the action', blocklistConfirmation(2003, 'Charlie', action: '$blocklistAction&amp;buid=2003')),
    ]) {
      test('a member with $name can not be added here', () {
        final page = _parse(lookupPage(confirmation), lookup: 2003);
        expect((page.lookup!.uid, page.lookup!.canAdd, page.addPayload(2003)), (2003, false, null));
      });
    }

    test('a page about another member than the one asked for is refused', () {
      expect(
        _failureOf(lookupPage(blocklistConfirmation(2004, 'Delta')), lookup: 2003),
        WebsiteBlocklistFailure.targetMismatch,
      );
      expect(
        _failureOf(lookupPage(blocklistConfirmation(2003, 'Charlie', shownUid: '2004')), lookup: 2003),
        WebsiteBlocklistFailure.targetMismatch,
      );
      expect(
        _failureOf(lookupPage(blocklistConfirmation(2003, 'Charlie', targetValue: '2004')), lookup: 2003),
        WebsiteBlocklistFailure.targetMismatch,
      );
    });

    test('a confirmation whose member can not be read, or add forms elsewhere, are refused', () {
      final noUid = blocklistConfirmation(2003, 'Charlie').replaceFirst('UID 2003', 'UID');
      expect(_failureOf(lookupPage(noUid), lookup: 2003), WebsiteBlocklistFailure.unsupported);
      final noName = blocklistConfirmation(2003, 'Charlie').replaceFirst(' id="bu_confirmname"', '');
      expect(_failureOf(lookupPage(noName), lookup: 2003), WebsiteBlocklistFailure.unsupported);
      final twice = blocklistConfirmation(2003, 'Charlie') * 2;
      expect(_failureOf(lookupPage(twice), lookup: 2003), WebsiteBlocklistFailure.unsupported);
      final stray = blocklistConfirmation(
        2003,
        'Charlie',
      ).replaceFirst('<div id="bu_confirm" class="bu-confirm">', '').replaceFirst(RegExp(r'</div>\s*$'), '');
      expect(_failureOf(lookupPage(stray), lookup: 2003), WebsiteBlocklistFailure.unsupported);
    });
  });

  group('typed target', () {
    test('uids and forum profile links are accepted by the same strict rules, anything else is not', () {
      expect(parseWebsiteBlocklistTarget(' 2001 '), 2001);
      expect(parseWebsiteBlocklistTarget('2147483647'), 2147483647);
      expect(parseWebsiteBlocklistTarget('https://www.tsdm39.com/home.php?mod=space&uid=2002'), 2002);
      expect(parseWebsiteBlocklistTarget('https://www.tsdm39.com/home.php?mod=space&uid=2002&do=profile'), 2002);
      expect(parseWebsiteBlocklistTarget('https://www.tsdm39.com/space-uid-2003.html'), 2003);
      for (final bad in [
        '',
        '0',
        '-5',
        '12a',
        '007',
        '2147483648',
        '99999999999',
        'home.php?mod=space&uid=2001',
        'https://example.com/home.php?mod=space&uid=2001',
        'https://www.tsdm39.com/home.php?mod=spacecp&uid=2001',
        'https://www.tsdm39.com/home.php?mod=space&uid=2147483648',
        'https://www.tsdm39.com/home.php?mod=space&uid=0x7d1',
        'https://www.tsdm39.com/home.php?mod=space&uid=+2001',
        'https://www.tsdm39.com/home.php?mod=space&uid=02001',
        'https://www.tsdm39.com/home.php?mod=space&uid=2001&uid=2002',
        'https://www.tsdm39.com/home.php?mod=space&mod=spacecp&uid=2001',
        'https://www.tsdm39.com/space-uid-2147483648.html',
        'https://www.tsdm39.com/space-uid-0x7d1.html',
        'javascript:alert(1)',
      ]) {
        expect(parseWebsiteBlocklistTarget(bad), isNull, reason: bad);
      }
    });
  });
}

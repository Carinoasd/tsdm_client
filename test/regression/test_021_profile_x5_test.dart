import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart' as editable;
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

/// Discuz! X5 samples captured with a test account on 2026-09-05 (ids, names and hashes replaced, friends count
/// raised to 3 so it differs from the other statistics).
String _data(String name) => File('test/data/$name').readAsStringSync();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('profile statistics on X5', () {
    test('friends count comes from the 好友数 anchor, not from the last number of the block', () async {
      final either = await buildProfile(parseHtmlDocument(_data('profile_self_x5.html'))).run();
      final profile = either.toNullable();
      expect(profile, isNotNull, reason: '$either');
      expect(profile!.username, 'Alice');
      // The X5 fragment carries every statistic; the last one is 主题数 0.
      expect(profile.friendsCount, contains('主题数'));
      final info = parseFriendsInfo(profile.friendsCount);
      expect(info.count, '3');
      expect(info.url, 'https://www.tsdm39.com/home.php?mod=space&uid=1000&do=friend&view=me&from=space');
    });

    test('the X3 fragment with a single anchor still works', () {
      final info = parseFriendsInfo(
        '<a href="home.php?mod=space&amp;uid=1000&amp;do=friend&amp;view=me&amp;from=space" target="_blank">好友数 12</a>',
      );
      expect(info.count, '12');
      expect(info.url, 'https://www.tsdm39.com/home.php?mod=space&uid=1000&do=friend&view=me&from=space');
    });

    test('a missing fragment shows a dash', () {
      expect(parseFriendsInfo(null), (count: '-', url: null));
      expect(parseFriendsInfo('  ').count, '-');
    });
  });

  group('editable profile form on X5', () {
    test('privacy selects without a selected option fall back to the first option', () {
      final form = parseHtmlDocument(_data('profile_edit_form_x5.html')).querySelector('form[target="frame_profile"]');
      expect(form, isNotNull);
      final profile = editable.UserProfile.fromForm(form!);
      expect(profile, isNotNull, reason: 'X5 renders bio/msn/site/birthday privacy selects with no selected option');
      expect(profile!.formHash, 'XXXXXXXX');
      expect(profile.usernameReadonly, 'Alice');
      expect(profile.gender, editable.Gender.private);
      expect(profile.genderVisibility, editable.Visibility.public);
      expect(profile.bioVisibility, editable.Visibility.public);
      expect(profile.birthdayVisibility, editable.Visibility.public);
      expect(profile.msnVisibility, editable.Visibility.public);
      expect(profile.homepageVisibility, editable.Visibility.public);
      expect(profile.birthdayYear, isNull);
      expect(profile.birthdayAvailableYears, isNotEmpty);
      expect(profile.timeZone?.value, '9999');
      expect(profile.availableTimeZones.length, greaterThan(10));
      expect(profile.pageStyle, isNull, reason: 'X5 has no page style row');
    });

    test('an explicitly selected privacy option is still honoured', () {
      final html = _data('profile_edit_form_x5.html').replaceFirst(
        '<select name="privacy[bio]">',
        '<select name="privacy[bio]"><option value="3" selected="selected">保密</option>',
      );
      final form = parseHtmlDocument(html).querySelector('form[target="frame_profile"]')!;
      expect(editable.UserProfile.fromForm(form)!.bioVisibility, editable.Visibility.private);
    });
  });
}

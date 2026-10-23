import 'package:collection/collection.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/profile/models/birthday_info.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

typedef _Keys = UserProfileKeys;

/// The text fields of [UserProfile] by their key.
const List<String> _textKeys = [
  _Keys.qq,
  _Keys.msn,
  _Keys.homepage,
  _Keys.bio,
  _Keys.hobby,
  _Keys.location,
  _Keys.nickname,
  _Keys.wordsToSay,
  _Keys.skill,
  _Keys.favoriteBangumi,
];

/// The profile editor of the forum's app API (plugin 3.0.0, `type: form`, `form: profile`): the page's form as
/// served, posted with the member's changes ([bodyWith]).
///
/// The forum only updates the fields a post carries, and merges the privacy settings it is given into the stored
/// ones, so the app posts the form's own fields (`submit.fields`) and the fields the member changed, each with the
/// controls and the privacy of its cell, and nothing else: no field the app does not show, no field left as it was
/// (posting it again would store the plugin's first option of a select without a chosen one, and run the forum's
/// word filter over text the member did not touch), no field of another tab. A control of a changed cell the member
/// did not change is posted as served, a `\r` of a select value included (an option the site set up with CRLF line
/// breaks: the forum stores it trimmed).
final class ProfileApiForm {
  ProfileApiForm._({
    required this.submitUrl,
    required this.submitFields,
    required this.cells,
    required this.titles,
    required this.profile,
  });

  /// The url the form posts to (`submit.url`), absolute, `multipart/form-data`.
  final String submitUrl;

  /// The form's hidden fields and its submit button, as served.
  final List<(String, String)> submitFields;

  /// The controls of each cell the app edits (the field's controls and its privacy), by its key in [UserProfileKeys].
  final Map<String, List<PostFormInput>> cells;

  /// The titles of the fields by the name the forum names a refused one with (`parent.show_error("field3")`).
  final Map<String, String> titles;

  /// The profile as served, which the member's changes are told from.
  final UserProfile profile;

  /// The editor in the answer [form], with the profile it shows; null when it is not the base tab's form the app
  /// edits (another tab, the verification tab, no target, no form hash): the page is then read as before.
  static ProfileApiForm? fromApi(SmallFormFields form) {
    final json = form.json;
    final submitUrl = form.submitUrl('home.php', const {'mod': 'spacecp', 'ac': 'profile', 'op': 'base'});
    final formHash = form.submitFields['formhash'] ?? '';
    if (json['op'] != 'base' ||
        tsdmAppInt(json['vid']) != 0 ||
        !form.multipart ||
        submitUrl == null ||
        formHash.isEmpty) {
      return null;
    }
    final submitFields = <(String, String)>[...form.submitFields.entries.map((e) => (e.key, e.value))];
    // Every field the browser posts for the page as served: a form whose list field (`name[]`) is checked more than
    // once can not be posted as a map, which the app's transports take; such a page is read as before.
    final served = PostFormBody(submitFields);
    final cells = <String, List<PostFormInput>>{};
    final titles = <String, String>{};
    final keys = <String>[];
    final locked = <String>[];
    final fields = <String, Map<String, dynamic>>{};

    for (final field in tsdmAppList(json['fields'])) {
      final id = tsdmAppText(field['id']);
      if (id.isEmpty) {
        continue;
      }
      fields[id] = field;
      titles[id] = tsdmAppText(field['title']);
      final controls = smallFormInputs(field['inputs']);
      final privacy = PostFormInput.fromJson(field['privacy']);
      for (final c in [...controls, ?privacy]) {
        served.addAll(_servedPairs(c));
        titles[c.name] = titles[id]!;
      }
      final known = id == _Keys.gender || id == _Keys.birthday || _textKeys.contains(id);
      if (!known) {
        continue;
      }
      if (controls.isNotEmpty) {
        keys.add(id);
        cells[id] = [...controls, ?privacy];
      } else if (field['text'] is String) {
        keys.add(id);
        locked.add(id);
        // Not changeable: only its privacy is the member's to set.
        if (privacy != null) {
          cells[id] = [privacy];
        }
      }
    }
    final customStatus = PostFormInput.fromJson(json['customstatus']);
    final signature = PostFormInput.fromJson(tsdmAppMap(json['signature'])['input']);
    final timeOffset = PostFormInput.fromJson(json['timeoffset']);
    for (final (key, input, title) in [
      (_Keys.customTitle, customStatus, t.editUserProfilePage.customTitle),
      (_Keys.signature, signature, t.editUserProfilePage.signature),
      (_Keys.timezone, timeOffset, t.editUserProfilePage.timezone),
    ]) {
      if (input != null && input.name == key) {
        served.addAll(_servedPairs(input));
        keys.add(key);
        cells[key] = [input];
        titles[key] = title;
      }
    }
    if (served.toMap() == null) {
      return null;
    }

    String? value(String id, [String? name]) {
      final field = fields[id];
      if (field == null) {
        return null;
      }
      final control = smallFormInputs(field['inputs']).firstWhereOrNull((e) => e.name == (name ?? id));
      return control?.value ?? (field['text'] is String ? field['text'] as String : null);
    }

    Visibility visibility(String id) =>
        Visibility.fromValue(int.tryParse(PostFormInput.fromJson(fields[id]?['privacy'])?.value ?? '')) ??
        Visibility.public;

    final birthYears = smallFormInputs(fields[_Keys.birthday]?['inputs'])
        .firstWhereOrNull((e) => e.name == _Keys.birthYear)
        ?.choices
        .map((e) => int.tryParse(e.value))
        .whereType<int>()
        .toList();
    final timeZones = [for (final c in timeOffset?.choices ?? const <PostFormChoice>[]) TimeZone(c.label, c.value)];

    final profile = UserProfile(
      formHash: formHash,
      usernameReadonly: tsdmAppText(json['username']),
      gender: Gender.fromValue(int.tryParse(value(_Keys.gender) ?? '')) ?? Gender.private,
      genderVisibility: visibility(_Keys.gender),
      birthdayYear: int.tryParse(value(_Keys.birthday, _Keys.birthYear) ?? ''),
      birthdayAvailableYears: birthYears ?? const [],
      birthdayMonth: int.tryParse(value(_Keys.birthday, _Keys.birthMonth) ?? ''),
      birthdayDay: int.tryParse(value(_Keys.birthday, _Keys.birthday) ?? ''),
      birthdayVisibility: visibility(_Keys.birthday),
      qq: int.tryParse(value(_Keys.qq) ?? ''),
      qqVisibility: visibility(_Keys.qq),
      msn: value(_Keys.msn),
      msnVisibility: visibility(_Keys.msn),
      homepage: value(_Keys.homepage),
      homepageVisibility: visibility(_Keys.homepage),
      bio: value(_Keys.bio) ?? '',
      bioVisibility: visibility(_Keys.bio),
      hobby: value(_Keys.hobby),
      hobbyVisibility: visibility(_Keys.hobby),
      location: value(_Keys.location),
      locationVisibility: visibility(_Keys.location),
      nickname: value(_Keys.nickname),
      nicknameVisibility: visibility(_Keys.nickname),
      wordsToSay: value(_Keys.wordsToSay),
      wordsToSayVisibility: visibility(_Keys.wordsToSay),
      skill: value(_Keys.skill),
      skillVisibility: visibility(_Keys.skill),
      favoriteBangumi: value(_Keys.favoriteBangumi),
      favoriteBangumiVisibility: visibility(_Keys.favoriteBangumi),
      // Not a profile field of the forum: the page style is never part of this form.
      pageStyle: null,
      availablePageStyles: const [],
      customTitle: customStatus?.value,
      signature: fixProfileSignature(signature?.value),
      timeZone: timeZones.firstWhereOrNull((e) => e.value == timeOffset?.value),
      availableTimeZones: timeZones,
      apiKeys: keys,
      lockedKeys: locked,
    );
    return ProfileApiForm._(
      submitUrl: submitUrl,
      submitFields: submitFields,
      cells: cells,
      titles: titles,
      profile: profile,
    );
  }

  /// The fields of [profile] the app edits, by the name the forum reads them with.
  static Map<String, String> _values(UserProfile profile) {
    String v(Object? value) => value?.toString() ?? '';
    return {
      _Keys.gender: v(profile.gender.value),
      _Keys.gender.visibility(): v(profile.genderVisibility.value),
      _Keys.birthYear: v(profile.birthdayYear),
      _Keys.birthMonth: v(profile.birthdayMonth),
      _Keys.birthday: v(profile.birthdayDay),
      _Keys.birthday.visibility(): v(profile.birthdayVisibility.value),
      _Keys.qq: v(profile.qq),
      _Keys.qq.visibility(): v(profile.qqVisibility.value),
      _Keys.msn: v(profile.msn),
      _Keys.msn.visibility(): v(profile.msnVisibility.value),
      _Keys.homepage: v(profile.homepage),
      _Keys.homepage.visibility(): v(profile.homepageVisibility.value),
      _Keys.bio: profile.bio,
      _Keys.bio.visibility(): v(profile.bioVisibility.value),
      _Keys.hobby: v(profile.hobby),
      _Keys.hobby.visibility(): v(profile.hobbyVisibility.value),
      _Keys.location: v(profile.location),
      _Keys.location.visibility(): v(profile.locationVisibility.value),
      _Keys.nickname: v(profile.nickname),
      _Keys.nickname.visibility(): v(profile.nicknameVisibility.value),
      _Keys.wordsToSay: v(profile.wordsToSay),
      _Keys.wordsToSay.visibility(): v(profile.wordsToSayVisibility.value),
      _Keys.skill: v(profile.skill),
      _Keys.skill.visibility(): v(profile.skillVisibility.value),
      _Keys.favoriteBangumi: v(profile.favoriteBangumi),
      _Keys.favoriteBangumi.visibility(): v(profile.favoriteBangumiVisibility.value),
      _Keys.customTitle: v(profile.customTitle),
      _Keys.signature: v(profile.signature),
      _Keys.timezone: v(profile.timeZone?.value),
    };
  }

  /// What the browser posts for control [input] as served: a checkbox or a radio only when checked and not
  /// disabled, a file nothing, any other control its value.
  static Iterable<(String, String)> _servedPairs(PostFormInput input) => switch (input.type) {
    'file' => const [],
    'radio' => input.checked && !input.disabled ? [(input.name, input.value ?? 'on')] : const [],
    _ => input.submitted,
  };

  /// The day of the birthday: the forum prints the days of the month stored (28 for February), the member may pick
  /// any day of another month; the forum checks the date when it saves.
  static bool _isBirthDay(String name, String value) {
    final day = int.tryParse(value);
    return name == _Keys.birthday && day != null && day >= 1 && day <= 31;
  }

  /// The fields to post for [edited], the profile [profile] as the member changed it: the form's own fields, and each
  /// cell the member changed (its value or its privacy) with every control of the cell, the member's values where
  /// changed and the served ones elsewhere. A cell the member did not change, and a field the app does not show, is
  /// not posted.
  ///
  /// Left with the title of the field when a changed select value is not one of its choices (the birthday's day
  /// excepted, see [_isBirthDay]): nothing is posted, rather than a value dropped without a word.
  Either<String, Map<String, String>> bodyWith(UserProfile edited) {
    final body = PostFormBody(submitFields);
    final before = _values(profile);
    final after = _values(edited);
    for (final MapEntry(key: key, value: controls) in cells.entries) {
      if (controls.every((c) => before[c.name] == after[c.name])) {
        continue;
      }
      for (final control in controls) {
        final value = after[control.name];
        if (value == null || value == before[control.name] || control.type == 'hidden' || control.type == 'file') {
          body.addAll(_servedPairs(control));
          continue;
        }
        if (control.type == 'select' &&
            value.isNotEmpty &&
            !control.choices.any((c) => c.value == value) &&
            !_isBirthDay(control.name, value)) {
          return left(titles[control.name] ?? titles[key] ?? key);
        }
        body.add(control.name, value);
      }
    }
    final map = body.toMap();
    return map == null ? left('') : right(map);
  }
}

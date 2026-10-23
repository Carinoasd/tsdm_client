import 'package:collection/collection.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/profile/models/birthday_info.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

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
/// served, posted with the member's changes over it ([bodyWith]).
///
/// The forum only updates the fields a post carries, so the app posts what the page printed (`submit.fields`, every
/// control of every field and its privacy, the custom title, the signature, the time zone, as the browser posts them)
/// and nothing else: no fixed set of fields, no field of another tab. Select values are posted as served, a `\r`
/// included (an option the site set up with CRLF line breaks: the forum stores it trimmed).
final class ProfileApiForm {
  ProfileApiForm._({
    required this.submitUrl,
    required this.served,
    required this.inputs,
    required this.titles,
    required this.profile,
  });

  /// The url the form posts to (`submit.url`), absolute, `multipart/form-data`.
  final String submitUrl;

  /// Every field the browser posts for the page as served, in order.
  final List<(String, String)> served;

  /// The controls by name, for the choices of a select.
  final Map<String, PostFormInput> inputs;

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
    final served = <(String, String)>[...form.submitFields.entries.map((e) => (e.key, e.value))];
    final inputs = <String, PostFormInput>{};
    final titles = <String, String>{};
    final keys = <String>[];
    final locked = <String>[];
    final fields = <String, Map<String, dynamic>>{};
    void serve(PostFormInput? input) {
      if (input == null) {
        return;
      }
      inputs[input.name] = input;
      switch (input.type) {
        case 'file':
          break;
        case 'radio':
          // As a checkbox: only the checked one of the group, never a disabled one.
          if (input.checked && !input.disabled) {
            served.add((input.name, input.value ?? 'on'));
          }
        default:
          served.addAll(input.submitted);
      }
    }

    for (final field in tsdmAppList(json['fields'])) {
      final id = tsdmAppText(field['id']);
      if (id.isEmpty) {
        continue;
      }
      fields[id] = field;
      titles[id] = tsdmAppText(field['title']);
      final controls = smallFormInputs(field['inputs'])..forEach(serve);
      final privacy = PostFormInput.fromJson(field['privacy']);
      serve(privacy);
      if (privacy != null) {
        titles[privacy.name] = titles[id]!;
      }
      for (final c in controls) {
        titles[c.name] = titles[id]!;
      }
      final known = id == _Keys.gender || id == _Keys.birthday || _textKeys.contains(id);
      if (!known) {
        continue;
      }
      if (controls.isNotEmpty) {
        keys.add(id);
      } else if (field['text'] is String) {
        keys.add(id);
        locked.add(id);
      }
    }
    final customStatus = PostFormInput.fromJson(json['customstatus']);
    final signature = PostFormInput.fromJson(tsdmAppMap(json['signature'])['input']);
    final timeOffset = PostFormInput.fromJson(json['timeoffset']);
    for (final (key, input) in [
      (_Keys.customTitle, customStatus),
      (_Keys.signature, signature),
      (_Keys.timezone, timeOffset),
    ]) {
      if (input != null && input.name == key) {
        serve(input);
        keys.add(key);
      }
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
    return ProfileApiForm._(submitUrl: submitUrl, served: served, inputs: inputs, titles: titles, profile: profile);
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

  /// The fields to post for [edited], the profile [profile] as the member changed it: every served field, and over
  /// it each value the member changed, only for a field the page printed (a select only to one of its choices). A
  /// field the member did not change is posted as served, never rebuilt from the app's model. Null when the body
  /// cannot be posted as a map (a list field posted twice).
  Map<String, String>? bodyWith(UserProfile edited) {
    final body = PostFormBody(served);
    final before = _values(profile);
    for (final MapEntry(key: name, value: value) in _values(edited).entries) {
      if (before[name] == value) {
        continue;
      }
      final input = inputs[name];
      if (input == null || input.type == 'hidden' || input.type == 'file') {
        continue;
      }
      if (input.type == 'select' && value.isNotEmpty && !input.choices.any((c) => c.value == value)) {
        continue;
      }
      body.set(name, value);
    }
    return body.toMap();
  }
}

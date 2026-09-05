import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/profile/models/birthday_info.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;

part 'editable_user_profile.mapper.dart';

typedef _Keys = UserProfileKeys;

extension _IntToVisibilityExt on int? {
  Visibility? toVisibility() => Visibility.fromValue(this);
}

/// Fix signature text.
///
/// Because signatures are considered as html text, which incorrectly prepend server host after submit to server.
/// Use this function to remove those duplicate hosts.
String? _fixSignature(String? signature) {
  if (signature == null) {
    return null;
  } else {
    return signature.replaceAll(RegExp('(https://(www\\.)?$baseHostAlt/)+https://'), 'https://');
  }
}

/// Available genders.
enum Gender {
  /// Not public.
  private(0),

  /// Male.
  male(1),

  /// Female.
  female(2);

  /// Constructor.
  const Gender(this.value);

  /// Deserialize.
  static Gender? fromValue(int? value) => switch (value) {
    0 => .private,
    1 => .male,
    2 => .female,
    _ => null,
  };

  /// The value.
  final int value;
}

/// The visibility of items in user profile.
enum Visibility {
  /// Public to everyone.
  public(0),

  /// Only visible for friends.
  friendsOnly(1),

  /// Not public to anyone.
  private(3);

  /// Constructor.
  const Visibility(this.value);

  /// Deserialize.
  static Visibility? fromValue(int? value) => switch (value) {
    0 => .public,
    1 => .friendsOnly,
    3 => .private,
    _ => null,
  };

  /// The value.
  final int value;
}

/// Web page style.
///
/// Use this modal accept available page styles dynamically for flexibility.
@MappableClass()
final class PageStyle with PageStyleMappable {
  /// Constructor.
  const PageStyle(this.name, this.value);

  /// Page style name.
  ///
  /// We do not have i18n on this field.
  final String name;

  /// The value used in form.
  final int value;
}

/// Timezone.
@MappableClass()
final class TimeZone with TimeZoneMappable {
  /// Constructor.
  const TimeZone(this.name, this.value);

  /// Page style name.
  ///
  /// We do not have i18n on this field.
  final String name;

  /// The value used in form.
  ///
  /// Not a integer to store string directly.
  final String value;
}

/// The Model of data when editing or viewing current user's profile.
///
/// It's generally editable and has different fields compared to common user profile.
@MappableClass()
final class UserProfile with UserProfileMappable {
  /// Constructor.
  const UserProfile({
    required this.formHash,
    required this.usernameReadonly,
    required this.gender,
    required this.genderVisibility,
    required this.birthdayYear,
    required this.birthdayAvailableYears,
    required this.birthdayMonth,
    required this.birthdayDay,
    required this.birthdayVisibility,
    required this.qq,
    required this.qqVisibility,
    required this.msn,
    required this.msnVisibility,
    required this.homepage,
    required this.homepageVisibility,
    required this.bio,
    required this.bioVisibility,
    required this.hobby,
    required this.hobbyVisibility,
    required this.location,
    required this.locationVisibility,
    required this.nickname,
    required this.nicknameVisibility,
    required this.wordsToSay,
    required this.wordsToSayVisibility,
    required this.skill,
    required this.skillVisibility,
    required this.favoriteBangumi,
    required this.favoriteBangumiVisibility,
    required this.pageStyle,
    required this.availablePageStyles,
    required this.customTitle,
    required this.signature,
    required this.timeZone,
    required this.availableTimeZones,
  });

  /// The selected `<option>` of the `<select>` matched by [selectSelector] under [root].
  ///
  /// Falls back to the first option, which is what a browser submits when no option carries `selected`: Discuz! X5
  /// renders several privacy selects that way (no `selected` on any option), the X3 template always marked one.
  static uh.Element? _selectedOption(uh.Element root, String selectSelector) {
    final select = root.querySelector(selectSelector);
    return select?.querySelector('option[selected]') ?? select?.querySelector('option');
  }

  /// Visibility chosen in the privacy select of the row for [key].
  static Visibility? _visibilityOf(uh.Element root, String key) =>
      _selectedOption(root, 'tr#tr_$key select[name="${key.visibility()}"]')?.attributes['value']?.parseToInt().toVisibility();

  /// Build model from the user profile form in web page.
  static UserProfile? fromForm(uh.Element root) {
    final formHash = root.querySelector('input[name="formhash"]')?.attributes['value'];
    final t = root.querySelector('table');
    if (formHash == null || t == null) {
      talker.error('failed to parse editable user profile: formHash=$formHash, dataRoot found=${t != null}');
      return null;
    }

    final username = t.querySelector('tr:nth-child(1) > td')?.innerText;

    final gender = Gender.fromValue(
      _selectedOption(t, 'td#td_${_Keys.gender} > select#${_Keys.gender}')?.attributes['value']?.parseToInt(),
    );
    if (gender == null) {
      talker.error('failed to parse editable user profile: invalid gender');
      return null;
    }
    final genderVisibility = _visibilityOf(t, _Keys.gender);

    final birthdayAvailableYears = <int>[];
    int? birthdayYear;
    for (final y in t.querySelectorAll('td#td_${_Keys.birthday} > select#${_Keys.birthYear} > option')) {
      final y2 = y.attributes['value'];
      if (y2 == '') {
        // Option for not selected state.
        continue;
      }
      final year = y2?.parseToInt();
      if (year == null) {
        talker.error('failed to parse editable user profile: birthday year value not found');
        continue;
      }
      if (y.hasAttribute('selected')) {
        birthdayYear = year;
      }

      birthdayAvailableYears.add(year);
    }
    final birthdayMonth = t
        .querySelector(
          'td#td_${_Keys.birthday} > select#${_Keys.birthMonth} '
          '> option[selected]',
        )
        ?.attributes['value']
        ?.parseToInt();
    final birthdayDay = t
        .querySelector(
          'td#td_${_Keys.birthday} > select#${_Keys.birthday} '
          '> option[selected]',
        )
        ?.attributes['value']
        ?.parseToInt();
    final birthdayVisibility = _visibilityOf(t, _Keys.birthday);

    final qq = t.querySelector('td#td_${_Keys.qq} > input')?.attributes['value']?.parseToInt();
    final qqVisibility = _visibilityOf(t, _Keys.qq);

    final msn = t.querySelector('td#td_${_Keys.msn} > input')?.attributes['value'];
    final msnVisibility = _visibilityOf(t, _Keys.msn);

    final homepage = t.querySelector('td#td_${_Keys.homepage} > input')?.attributes['value']?.trim();
    final homepageVisibility = _visibilityOf(t, _Keys.homepage);

    final bio = t.querySelector('td#td_${_Keys.bio} > textarea')?.innerText.trim() ?? '';
    final bioVisibility = _visibilityOf(t, _Keys.bio);

    final hobby = t.querySelector('td#td_${_Keys.hobby} > textarea')?.innerText.trim();
    final hobbyVisibility = _visibilityOf(t, _Keys.hobby);

    final location = t.querySelector('td#td_${_Keys.location} > input')?.attributes['value'];
    final locationVisibility = _visibilityOf(t, _Keys.location);

    final nickname = t.querySelector('td#td_${_Keys.nickname} > input')?.attributes['value'];
    final nicknameVisibility = _visibilityOf(t, _Keys.nickname);

    final wordsToSay = t.querySelector('td#td_${_Keys.wordsToSay} > input')?.attributes['value'];
    final wordsToSayVisibility = _visibilityOf(t, _Keys.wordsToSay);

    final skill = t.querySelector('td#td_${_Keys.skill} > input')?.attributes['value'];
    final skillVisibility = _visibilityOf(t, _Keys.skill);

    final favoriteBangumi = t.querySelector('td#td_${_Keys.favoriteBangumi} > input')?.attributes['value'];
    final favoriteBangumiVisibility = _visibilityOf(t, _Keys.favoriteBangumi);

    final availablePageStyles = <PageStyle>[];
    PageStyle? pageStyle;
    for (final ps in t.querySelectorAll('td#td_${_Keys.pageStyle} > select[name="${_Keys.pageStyle}"] > option')) {
      final psv = ps.attributes['value']?.parseToInt();
      if (psv == null) {
        talker.error('failed to parse editable user profile: invalid page style value: ${ps.attributes["value"]}');
        continue;
      }
      final psn = ps.innerText.trim();
      if (ps.hasAttribute('selected')) {
        pageStyle = PageStyle(psn, psv);
      }
      availablePageStyles.add(PageStyle(psn, psv));
    }

    final customTitle = t.querySelector('td#td_${_Keys.customTitle} > input')?.attributes['value'];

    final signature = t.querySelector('td#td_${_Keys.signature} textarea#${_Keys.signature}message')?.innerText.trim();

    final availableTimeZones = <TimeZone>[];
    TimeZone? timeZone;

    for (final tz in t.querySelectorAll('td#td_${_Keys.timezone} > select[name="${_Keys.timezone}"] > option')) {
      final tzv = tz.attributes['value'];
      if (tzv == null) {
        talker.error('failed to parse editable user profile: invalid time zone value "${tz.attributes["value"]}"');
        continue;
      }

      final tzn = tz.innerText.trim();
      if (tz.hasAttribute('selected')) {
        timeZone = TimeZone(tzn, tzv);
      }

      availableTimeZones.add(TimeZone(tzn, tzv));
    }

    if ([
      genderVisibility,
      birthdayVisibility,
      bioVisibility,
      qqVisibility,
      msnVisibility,
      homepageVisibility,
      bioVisibility,
      hobbyVisibility,
      locationVisibility,
      nicknameVisibility,
      wordsToSayVisibility,
      skillVisibility,
      favoriteBangumiVisibility,
    ].any((v) => v == null)) {
      talker.error(
        'failed to parse editable user profile: invalid visibility: ${[
          genderVisibility,
          birthdayVisibility,
          bioVisibility,
          qqVisibility,
          homepageVisibility,
          msnVisibility,
          bioVisibility,
          hobbyVisibility,
          locationVisibility,
          nicknameVisibility,
          wordsToSayVisibility,
          skillVisibility,
          favoriteBangumiVisibility,
        ]}',
      );
      return null;
    }

    return UserProfile(
      formHash: formHash,
      usernameReadonly: username ?? '',
      gender: gender,
      genderVisibility: genderVisibility!,
      birthdayYear: birthdayYear,
      birthdayAvailableYears: birthdayAvailableYears,
      birthdayMonth: birthdayMonth,
      birthdayDay: birthdayDay,
      birthdayVisibility: birthdayVisibility!,
      qq: qq,
      qqVisibility: qqVisibility!,
      msn: msn,
      msnVisibility: msnVisibility!,
      homepage: homepage,
      homepageVisibility: homepageVisibility!,
      bio: bio,
      bioVisibility: bioVisibility!,
      hobby: hobby,
      hobbyVisibility: hobbyVisibility!,
      location: location,
      locationVisibility: locationVisibility!,
      nickname: nickname,
      nicknameVisibility: nicknameVisibility!,
      wordsToSay: wordsToSay,
      wordsToSayVisibility: wordsToSayVisibility!,
      skill: skill,
      skillVisibility: skillVisibility!,
      favoriteBangumi: favoriteBangumi,
      favoriteBangumiVisibility: favoriteBangumiVisibility!,
      pageStyle: pageStyle,
      availablePageStyles: availablePageStyles,
      customTitle: customTitle,
      signature: _fixSignature(signature),
      timeZone: timeZone,
      availableTimeZones: availableTimeZones,
    );
  }

  /// Available form hash.
  final String formHash;

  /// Username.
  ///
  /// Not editable.
  final String usernameReadonly;

  /// Gender.
  final Gender gender;

  /// The visibility of gender.
  final Visibility genderVisibility;

  /// Birthday.
  ///
  /// Note that:
  ///
  /// 1. Only have year, month and day.
  /// 2. Available years shall be described in data. If the birthday is invalid, no error is returned from server side
  ///   but the incorrect value is neither saved too - the date time will be reset to null.
  /// 3. All segments of birthday (year, month and day) can be used individually, it's valid to only have month or only
  ///   have day.
  final int? birthdayYear;

  /// See [birthdayYear] for description.
  final int? birthdayMonth;

  /// See [birthdayYear] for description.
  final int? birthdayDay;

  /// The visibility of [birthdayYear], [birthdayMonth] and [birthdayDay].
  final Visibility birthdayVisibility;

  /// All available years.
  ///
  /// Only these years are legal.
  final List<int> birthdayAvailableYears;

  /// QQ.
  ///
  /// Only numbers not start with 0 are allowed.
  final int? qq;

  /// The visibility of [qq].
  final Visibility qqVisibility;

  /// MSN.
  final String? msn;

  /// The visibility of [msn].
  final Visibility msnVisibility;

  /// User homepage.
  final String? homepage;

  /// The visibility of [homepage].
  final Visibility homepageVisibility;

  /// Biography.
  final String bio;

  /// The visibility of [bio].
  ///
  /// Multiline.
  final Visibility bioVisibility;

  /// Hobby.
  ///
  /// Multiline.
  final String? hobby;

  /// The visibility of [hobby].
  final Visibility hobbyVisibility;

  /// From where.
  final String? location;

  /// The visibility of [location].
  final Visibility locationVisibility;

  /// Nickname.
  final String? nickname;

  /// The visibility of [nickname].
  final Visibility nicknameVisibility;

  /// Words to say.
  final String? wordsToSay;

  /// The visibility of [wordsToSay].
  final Visibility wordsToSayVisibility;

  /// Skill;
  final String? skill;

  /// The visibility of [skill].
  final Visibility skillVisibility;

  /// Favorite bangumi.
  final String? favoriteBangumi;

  /// The visibility of [favoriteBangumi].
  final Visibility favoriteBangumiVisibility;

  /// Current web page style.
  final PageStyle? pageStyle;

  /// All available web page styles.
  final List<PageStyle> availablePageStyles;

  /// Custom title.
  final String? customTitle;

  /// Signature.
  ///
  /// Multiline.
  final String? signature;

  /// Timezone.
  final TimeZone? timeZone;

  /// All available time zones.
  final List<TimeZone> availableTimeZones;
}

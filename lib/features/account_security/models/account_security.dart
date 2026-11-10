import 'package:flutter/foundation.dart';

/// The ways of the forum's account center (`home.php?mod=spacecp&ac=account`, Discuz! X5) the app changes natively.
///
/// Each one opens with `op=verify&method=<name>`: the forum asks for a check first when the site wants one
/// (`security_verify`), then prints a small form posted back to the same url with a signature.
enum AccountMethod {
  /// The password (`newpassword`, `renewpassword`).
  password('chgpassword'),

  /// The security question and its answer (`questionidnew`, `answernew`).
  question('chgquestion'),

  /// The email (`email`).
  email('chgemail')
  ;

  const AccountMethod(this.method);

  /// The forum's name of the way (`method`).
  final String method;

  /// The way named [method], null for one the app leaves to the web page (`chgusername`, the bindings…).
  static AccountMethod? of(String? method) {
    for (final e in values) {
      if (e.method == method) {
        return e;
      }
    }
    return null;
  }
}

/// One row of the account center the app handles: the forum's title, what it shows of the current value, the way to
/// change it.
@immutable
final class AccountSecurityItem {
  /// Constructor.
  const AccountSecurityItem({required this.method, required this.title, required this.value});

  /// The way to change it.
  final AccountMethod method;

  /// The forum's title of the row (`账号密码`, `安全问题`, `安全邮箱`).
  final String title;

  /// What the forum shows of the current value (the masked email), empty when nothing worth showing (the password's
  /// asterisks).
  final String value;
}

/// The account center page of an account: the rows the app handles and the form hash the forum gave them.
@immutable
final class AccountSecurityOverview {
  /// Constructor.
  const AccountSecurityOverview({required this.formHash, required this.items});

  /// The form hash of the session, carried by the links of the rows.
  final String formHash;

  /// The rows, in the forum's order.
  final List<AccountSecurityItem> items;
}

/// A field of a form of the account center, as the forum printed it.
@immutable
sealed class AccountFormField {
  const AccountFormField({required this.name, required this.label});

  /// The field's name, sent as it is.
  final String name;

  /// The forum's label of the field, without the trailing colon.
  final String label;
}

/// A text input: a password ([obscure]) or plain text.
final class AccountTextField extends AccountFormField {
  /// Constructor.
  const AccountTextField({required super.name, required super.label, required this.obscure});

  /// A password input: shown hidden, never kept anywhere.
  final bool obscure;
}

/// A select of the forum: [options] as value and text, [initial] the value selected on the page.
final class AccountChoiceField extends AccountFormField {
  /// Constructor.
  const AccountChoiceField({required super.name, required super.label, required this.options, required this.initial});

  /// The options, value and text, in the forum's order.
  final List<(String, String)> options;

  /// The value selected when the page was printed.
  final String initial;
}

/// The form of a way of the account center, signed by the forum for this session.
@immutable
final class AccountMethodForm {
  /// Constructor.
  const AccountMethodForm({required this.method, required this.action, required this.hidden, required this.fields});

  /// The way.
  final AccountMethod method;

  /// Where the form is posted (the forum's signed url, on the main host).
  final Uri action;

  /// The fields sent as they are: the hidden inputs and the submit flag.
  final List<(String, String)> hidden;

  /// The fields the user fills in, in the forum's order.
  final List<AccountFormField> fields;
}

/// The check the forum asks before a way of the account center: the current password (`verify=password`).
@immutable
final class AccountVerifyForm {
  /// Constructor.
  const AccountVerifyForm({required this.action, required this.hidden});

  /// Where the password is posted.
  final Uri action;

  /// The fields sent as they are: the hidden inputs and the submit flag.
  final List<(String, String)> hidden;
}

/// What a step of the account center answered (the forum's AJAX fragments).
@immutable
sealed class AccountStep {
  const AccountStep();
}

/// Passed (no check asked, or the check done): the form is at [url], signed for this session.
final class AccountStepSigned extends AccountStep {
  /// Constructor.
  const AccountStepSigned(this.url);

  /// The signed url of the form.
  final Uri url;
}

/// The forum lets the user choose the check: [password] is the link of the password check, null when the site does
/// not offer it ([others] tells whether it offers another one: the email or the phone code).
final class AccountStepChoose extends AccountStep {
  /// Constructor.
  const AccountStepChoose({required this.password, required this.others});

  /// The link of the password check.
  final Uri? password;

  /// Another check is offered.
  final bool others;
}

/// The password check's form.
final class AccountStepVerify extends AccountStep {
  /// Constructor.
  const AccountStepVerify(this.form);

  /// The form.
  final AccountVerifyForm form;
}

/// The way's own form.
final class AccountStepForm extends AccountStep {
  /// Constructor.
  const AccountStepForm(this.form);

  /// The form.
  final AccountMethodForm form;
}

/// The forum's message: [text] as plain text, [success] when the forum went on as after a change (it reloads the
/// page).
final class AccountStepMessage extends AccountStep {
  /// Constructor.
  const AccountStepMessage(this.text, {required this.success});

  /// The message.
  final String text;

  /// The forum reloads the page after it: the change was made.
  final bool success;
}

/// Nothing the app knows.
final class AccountStepUnknown extends AccountStep {
  /// Constructor.
  const AccountStepUnknown();
}

/// A tab of the privacy page (`home.php?mod=spacecp&ac=privacy&op=<op>`).
@immutable
final class PrivacyTab {
  /// Constructor.
  const PrivacyTab({required this.op, required this.title});

  /// The tab's `op` (`base`, `feed`, `other`).
  final String op;

  /// The forum's title of the tab.
  final String title;
}

/// A setting of the privacy page.
@immutable
sealed class PrivacyItem {
  const PrivacyItem({required this.name, required this.label});

  /// The field's name, sent as it is.
  final String name;

  /// The forum's label.
  final String label;
}

/// A select (who may see the friends, the wall…): [options] as value and text, [value] the one selected.
final class PrivacyChoice extends PrivacyItem {
  /// Constructor.
  const PrivacyChoice({required super.name, required super.label, required this.options, required this.value});

  /// The options, value and text, in the forum's order.
  final List<(String, String)> options;

  /// The value selected.
  final String value;

  /// The text of [value].
  String get valueLabel => options.firstWhere((e) => e.$1 == value, orElse: () => (value, value)).$2;

  /// Copy with another [value].
  PrivacyChoice withValue(String value) => PrivacyChoice(name: name, label: label, options: options, value: value);
}

/// A checkbox (an action published to the feed): sent with [value] when [checked].
final class PrivacyToggle extends PrivacyItem {
  /// Constructor.
  const PrivacyToggle({required super.name, required super.label, required this.value, required this.checked});

  /// The value sent when checked.
  final String value;

  /// Checked.
  final bool checked;

  /// Copy with another [checked].
  PrivacyToggle withChecked({required bool checked}) =>
      PrivacyToggle(name: name, label: label, value: value, checked: checked);
}

/// The form of a tab of the privacy page.
@immutable
final class PrivacySection {
  /// Constructor.
  const PrivacySection({required this.tab, required this.action, required this.fixed, required this.items});

  /// The tab.
  final PrivacyTab tab;

  /// Where the form is posted.
  final Uri action;

  /// The fields sent as they are: the hidden inputs and the submit flag (`privacysubmit`, `privacy3submit`).
  final List<(String, String)> fixed;

  /// The settings, in the forum's order.
  final List<PrivacyItem> items;

  /// Copy with other [items].
  PrivacySection withItems(List<PrivacyItem> items) =>
      PrivacySection(tab: tab, action: action, fixed: fixed, items: items);

  /// The form as sent: the forum replaces every setting of the tab with what is sent (`privacy.php`), so all of them
  /// are, the selects with their value and the checked boxes.
  List<(String, String)> get pairs => [
    ...fixed,
    for (final item in items)
      switch (item) {
        PrivacyChoice(:final name, :final value) => (name, value),
        PrivacyToggle(:final name, :final value, checked: true) => (name, value),
        PrivacyToggle() => null,
      },
  ].whereType<(String, String)>().toList();

  /// The values of the settings, to compare two states of the tab.
  Map<String, String> get values => {
    for (final item in items)
      item.name: switch (item) {
        PrivacyChoice(:final value) => value,
        PrivacyToggle(:final checked) => checked ? '1' : '0',
      },
  };
}

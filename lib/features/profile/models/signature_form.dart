import 'dart:convert';

import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// The tabs of the forum's profile editor (`home.php?mod=spacecp&ac=profile&op=…`) the signature may be printed in,
/// in the order they are tried after the default one: the 个人信息 tab first (where Discuz! X5 prints it by
/// default), then the others the forum lists (`child/spacecp/profile.php`). The verification and password tabs never
/// hold it.
const signatureProfileTabs = ['info', 'base', 'contact', 'edu', 'work'];

/// The name the forum reads the signature with (`sightml`).
const _signatureName = 'sightml';

/// The signature of the member as the profile editor of the forum prints it: its BBCode, the limits of the member's
/// user group, and the form the editor posts it with.
///
/// The forum prints the signature in one tab of the profile editor only (the one whose items hold `sightml`: the
/// base tab on the forum, the 个人信息 tab on a default Discuz! X5), and saves only the fields a post carries, so
/// the signature is posted with the form's own fields alone ([bodyWith]): no other field of the tab is touched.
final class SignatureForm {
  /// Constructor.
  const SignatureForm({
    required this.uid,
    required this.value,
    required this.submitUrl,
    required this.submitFields,
    this.max,
    this.bbcode = true,
    this.imgcode = false,
  });

  /// The account the form was served to.
  final int uid;

  /// The signature as BBCode (the forum turns the stored HTML back into BBCode for the editor).
  final String value;

  /// The url the form posts to, absolute, `multipart/form-data`.
  final String submitUrl;

  /// The form's hidden fields and its submit button, as served.
  final Map<String, String> submitFields;

  /// The longest signature the member's user group keeps (`maxsigsize`), counted with [signatureLength]; null when
  /// the page does not tell it (the web page without the forum's app API).
  final int? max;

  /// Whether the member's user group may use BBCode in the signature (`allowsigbbcode`).
  final bool bbcode;

  /// Whether the member's user group may use images in the signature (`allowsigimgcode`).
  final bool imgcode;

  /// The signature form of the profile editor answered by the forum's app API ([form], plugin 3.0.0, `form:
  /// profile`): null when this tab prints no signature (the member's group has none, or another tab holds it), or the
  /// form can not be posted (no target, no form hash).
  static SignatureForm? fromApi(SmallFormFields form) {
    final json = form.json;
    final signature = tsdmAppMap(json['signature']);
    final input = PostFormInput.fromJson(signature['input']);
    if (input == null || input.name != _signatureName) {
      return null;
    }
    final submitUrl = form.submitUrl('home.php', const {'mod': 'spacecp', 'ac': 'profile'});
    final fields = form.submitFields;
    if (submitUrl == null || !form.multipart || (fields['formhash'] ?? '').isEmpty) {
      return null;
    }
    final max = tsdmAppInt(signature['max']);
    return SignatureForm(
      uid: form.uid,
      value: fixProfileSignature(input.value) ?? '',
      submitUrl: submitUrl,
      submitFields: fields,
      max: max > 0 ? max : null,
      bbcode: tsdmAppInt(signature['bbcode']) == 1,
      imgcode: tsdmAppInt(signature['imgcode']) == 1,
    );
  }

  /// The signature form of the profile editor's web page [doc] served to account [uid]; null when the page prints no
  /// signature (another tab holds it, or the member's group has none).
  static SignatureForm? fromDocument(uh.Document doc, int uid) {
    final textarea = doc.querySelector('textarea[name="$_signatureName"]');
    if (textarea == null) {
      return null;
    }
    uh.Element? form = textarea;
    while (form != null && form.localName != 'form') {
      form = form.parent;
    }
    final formHash = form?.querySelector('input[name="formhash"]')?.attributes['value'] ?? '';
    final action = form?.attributes['action'] ?? '';
    final target = Uri.tryParse(action);
    if (formHash.isEmpty || target == null || !isForumScriptUri(target, 'home.php')) {
      return null;
    }
    final query = uniqueQueryParameters(target);
    if (query == null || query['mod'] != 'spacecp' || query['ac'] != 'profile') {
      return null;
    }
    // The editor's script tells the group's switches: `allowbbcode = parseInt('1'),allowimgcode = parseInt('0')`.
    final script = doc.querySelectorAll('script').map((e) => e.text ?? '').join('\n');
    bool flag(String name) => RegExp("$name\\s*=\\s*parseInt\\('(\\d*)'\\)").firstMatch(script)?.group(1) == '1';
    return SignatureForm(
      uid: uid,
      value: fixProfileSignature(textarea.text) ?? '',
      submitUrl: Uri.parse(baseUrl).replace(path: '/home.php', query: target.query).toString(),
      submitFields: {'formhash': formHash, 'profilesubmit': 'true', 'profilesubmitbtn': 'true'},
      bbcode: flag('allowbbcode'),
      imgcode: flag('allowbbcode') && flag('allowimgcode'),
    );
  }

  /// Whether the signature [value] is kept whole by the forum ([max] null: not known, taken as kept).
  bool fits(String value) => max == null || signatureFits(value, max!);

  /// The fields to post for the signature [value]: the form's own fields and the signature, nothing else.
  Map<String, String> bodyWith(String value) => {...submitFields, _signatureName: value};
}

/// Length of a signature [value] as the forum counts it before it cuts the signature to its user group's
/// `maxsigsize` (`cutstr` on UTF-8): a tab, a line feed or a printable ASCII character counts 1, any other ASCII
/// character (a carriage return) 0, any other character 2.
///
/// The forum counts `&amp;`, `&quot;`, `&lt;` and `&gt;` written in the signature as one character each; they are
/// counted as written here, so such a signature is only ever taken as longer than the forum would, never shorter.
int signatureLength(String value) => value.runes.fold(
  0,
  (sum, rune) => sum + (rune == 9 || rune == 10 || (rune >= 32 && rune <= 126) ? 1 : (rune < 0x80 ? 0 : 2)),
);

/// Whether the forum keeps the signature [value] whole for the limit [max]: `cutstr` leaves alone a value of at most
/// [max] bytes, and cuts any other once [signatureLength] passes [max].
bool signatureFits(String value, int max) => utf8.encode(value).length <= max || signatureLength(value) <= max;

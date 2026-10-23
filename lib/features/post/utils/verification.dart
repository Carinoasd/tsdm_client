import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

final _updateRe = RegExp(r'\bupdate(seccode|secqaa)\s*\(');

/// Whether the web page (or the reply window's fragment) [document] of a post form asks for a captcha or a security
/// question before posting: inside the form (`form#postform`), the placeholders the forum's `seccheck` template prints
/// (`span#seccode_…`, `span#secqaa_…`, filled by the page script `updateseccode`/`updatesecqaa`), or the fields
/// themselves as another theme may print them (`seccodeverify`, `secanswer`…).
///
/// Only the website shows them: such a form is never posted from the app. The forum prints none on an edit page (and
/// does not check one there).
bool documentAsksVerification(uh.Document document) {
  final scope = document.querySelector('form#postform') ?? document.querySelector('#ct') ?? document.documentElement;
  return scope != null && elementAsksVerification(scope);
}

/// [documentAsksVerification] inside [scope] only (the quick reply form of a thread page, `form#fastpostform`).
bool elementAsksVerification(uh.Element scope) {
  if (scope.querySelector(
        '[id^="seccode_"], [id^="secqaa_"], [name^="seccode"], [name^="secqaa"], [name="secanswer"]',
      ) !=
      null) {
    return true;
  }
  return scope.querySelectorAll('script').any((e) => _updateRe.hasMatch(e.text ?? ''));
}

/// Which checks the forum refused a post for: the message key of the forum's app API (`submit_seccode_invalid`,
/// `submit_secqaa_invalid`), else the forum's own words in either language pack.
({bool seccode, bool secqaa})? refusedVerification({String messageKey = '', String? reason}) {
  // The key tells which one; the words only when there is none (the forum's own answer).
  if (messageKey == 'submit_seccode_invalid') {
    return (seccode: true, secqaa: false);
  }
  if (messageKey == 'submit_secqaa_invalid') {
    return (seccode: false, secqaa: true);
  }
  if (messageKey.isNotEmpty) {
    // Another refusal of the forum, whatever its words.
    return null;
  }
  final text = reason ?? '';
  final seccode = messageKey == 'submit_seccode_invalid' || text.contains('验证码填写错误') || text.contains('驗證碼填寫錯誤');
  final secqaa = messageKey == 'submit_secqaa_invalid' || text.contains('验证问答填写错误') || text.contains('驗證問答填寫錯誤');
  return seccode || secqaa ? (seccode: seccode, secqaa: secqaa) : null;
}

/// The checks to answer after the forum refused a post for [refused]: those of the answer posted ([answered], their
/// ids kept), those the form told ([told]), and the refused ones, with ids of the app's own when none is known.
SecCheck refusedCheck(({bool seccode, bool secqaa}) refused, {SecCheck? answered, SecCheck? told, String? modid}) {
  final known = answered?.merge(told) ?? told;
  return (known ?? SecCheck.generated(modid: modid ?? SecCheck.postModid)).merge(
    SecCheck.generated(
      seccode: refused.seccode,
      secqaa: refused.secqaa,
      modid: known?.modid ?? modid ?? SecCheck.postModid,
    ),
  );
}

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

import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/account_security/models/account_security.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The account center page of the forum (Discuz! X5).
const accountCenterUrl = '$baseUrl/home.php?mod=spacecp&ac=account';

/// The privacy page's tab [op].
String privacyPageUrl(String op) => '$baseUrl/home.php?mod=spacecp&ac=privacy&op=$op';

/// The tabs of the privacy page the app shows: `filter` (the ignored notices, feeds and friend groups) belongs to the
/// blocking pages and is never read nor posted here.
const privacyOps = {'base', 'feed', 'other'};

/// The query every url of a way of the account center carries.
Map<String, String> _accountQuery(AccountMethod method) => {
  'mod': 'spacecp',
  'ac': 'account',
  'op': 'verify',
  'method': method.method,
};

/// The url opening [method] in the account center with [formHash], as the forum's link does (the AJAX float).
String accountMethodOpenUrl(AccountMethod method, String formHash) =>
    '$accountCenterUrl&op=verify&method=${method.method}&formhash=${Uri.encodeQueryComponent(formHash)}'
    '&inajax=1&infloat=yes&handlekey=security_verify';

/// [url] asked as the forum's AJAX float: `inajax=1` added when missing.
Uri asAccountFloat(Uri url) {
  if (url.queryParameters['inajax'] == '1') {
    return url;
  }
  return url.replace(query: '${url.query}${url.query.isEmpty ? '' : '&'}inajax=1');
}

/// [raw] (maybe relative, html escaped) as the url of [method] on the main host, null when it is anything else.
Uri? _accountUrl(String? raw, AccountMethod method, {Map<String, String> more = const {}}) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(raw.replaceAll('&amp;', '&'));
  if (uri == null) {
    return null;
  }
  return canonicalForumOperationUrl(uri, {..._accountQuery(method), ...more});
}

/// Plain text of [e] with white space collapsed.
String _text(uh.Element? e) => (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// [label] without the colon the forum ends some labels with.
String _label(String label) => label.replaceFirst(RegExp(r'\s*[:：]\s*$'), '').trim();

/// The rows of the account center page [raw] the app handles, for the account [expectedUid].
///
/// Null for a page that is not the account center of that account (a guest page, another account, a message), so
/// the caller never acts on someone else's page. A row is taken only with its link to a way of [AccountMethod], on
/// the forum's host; the form hash comes from those links.
AccountSecurityOverview? parseAccountOverview(String raw, {required int expectedUid}) {
  final doc = parseHtmlDocument(raw);
  if (forumPageProblem(doc, expectedUid: expectedUid, requireIdentity: true) != null) {
    return null;
  }
  final items = <AccountSecurityItem>[];
  final seen = <AccountMethod>{};
  var formHash = '';
  for (final row in doc.querySelectorAll('table.tfm tr')) {
    for (final a in row.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      final method = AccountMethod.of(Uri.tryParse(href?.replaceAll('&amp;', '&') ?? '')?.queryParameters['method']);
      if (method == null || _accountUrl(href, method) == null || !seen.add(method)) {
        continue;
      }
      final link = _accountUrl(href, method)!;
      formHash = link.queryParameters['formhash'] ?? formHash;
      final cell = row.querySelector('td')?.clone(true) as uh.Element?;
      cell?.querySelectorAll('p, a, script').forEach((e) => e.remove());
      final value = _text(cell);
      items.add(
        AccountSecurityItem(
          method: method,
          title: _text(row.querySelector('th')),
          value: RegExp(r'^\*+$').hasMatch(value) ? '' : value,
        ),
      );
      break;
    }
  }
  if (items.isEmpty || formHash.isEmpty) {
    return null;
  }
  return AccountSecurityOverview(formHash: formHash, items: items);
}

/// The hidden inputs and the submit flag [submit] of [form], null when the form has another kind of input, has no
/// form hash, or has no such flag.
List<(String, String)>? _hiddenOf(uh.Element form, String submit) {
  final out = <(String, String)>[];
  var flag = false;
  for (final e in form.querySelectorAll('input[type="hidden"], button')) {
    final name = e.attributes['name'];
    if (name == null || name.isEmpty || e.attributes.containsKey('disabled')) {
      continue;
    }
    if (e.localName == 'button') {
      if (name == submit && !flag) {
        out.add((name, e.attributes['value'] ?? 'true'));
        flag = true;
      }
      continue;
    }
    out.add((name, e.attributes['value'] ?? ''));
  }
  if (!flag || !out.any((e) => e.$1 == 'formhash' && e.$2.isNotEmpty)) {
    return null;
  }
  return out;
}

/// The label the forum gave the input [e] of [form] (`<label for=…>`, or the row's `<th>`).
String _labelOf(uh.Element form, uh.Element e) {
  final id = e.attributes['id'];
  if (id != null && id.isNotEmpty) {
    for (final l in form.querySelectorAll('label')) {
      if (l.attributes['for'] == id) {
        return _label(_text(l));
      }
    }
  }
  var p = e.parent;
  while (p != null && p.localName != 'tr' && p != form) {
    p = p.parent;
  }
  return p?.localName == 'tr' ? _label(_text(p!.querySelector('th'))) : '';
}

/// The way's own form [form] of [method], posted to [action]; null when it has a field the app does not know (it would
/// be left out), or none to fill in.
AccountMethodForm? _methodForm(uh.Element form, AccountMethod method, Uri action) {
  final hidden = _hiddenOf(form, 'submit');
  if (hidden == null) {
    return null;
  }
  final fields = <AccountFormField>[];
  for (final e in form.querySelectorAll('input, select, textarea')) {
    final name = e.attributes['name'];
    final type = (e.attributes['type'] ?? 'text').toLowerCase();
    if (e.attributes.containsKey('disabled') || (e.localName == 'input' && type == 'hidden')) {
      continue;
    }
    if (name == null || name.isEmpty) {
      return null;
    }
    if (e.localName == 'select') {
      if (e.attributes.containsKey('multiple')) {
        return null;
      }
      final options = [
        for (final o in e.querySelectorAll('option')) (o.attributes['value'] ?? _text(o), _text(o)),
      ];
      if (options.isEmpty) {
        return null;
      }
      final selected = e.querySelector('option[selected]');
      fields.add(
        AccountChoiceField(
          name: name,
          label: _labelOf(form, e),
          options: options,
          initial: selected == null ? options.first.$1 : (selected.attributes['value'] ?? _text(selected)),
        ),
      );
      continue;
    }
    if (e.localName == 'input' && (type == 'text' || type == 'password' || type == 'email')) {
      fields.add(AccountTextField(name: name, label: _labelOf(form, e), obscure: type == 'password'));
      continue;
    }
    return null;
  }
  if (fields.isEmpty) {
    return null;
  }
  // The password is never asked in plain text.
  if (method == AccountMethod.password && fields.any((e) => e is! AccountTextField || !e.obscure)) {
    return null;
  }
  return AccountMethodForm(method: method, action: action, hidden: hidden, fields: fields);
}

/// What the forum answered [raw] (an AJAX fragment, or a page) at a step of [method] in the account center.
///
/// * The signed link of the way's form (`showWindow("<method>", "…&idstring=…&sign=…")`): [AccountStepSigned].
/// * The way's form, posted back to its signed url: [AccountStepForm].
/// * The password check's form (`verify=password`): [AccountStepVerify].
/// * The choice of the check: [AccountStepChoose].
/// * Anything else with text: the forum's message, [AccountStepMessage].
///
/// Every url is taken only on the forum's host, for [method].
AccountStep parseAccountStep(String raw, {required AccountMethod method}) {
  final html = unwrapAjax(raw);
  final signed = RegExp('showWindow\\(\\s*["\']${method.method}["\']\\s*,\\s*["\']([^"\']+)["\']').firstMatch(html);
  if (signed != null) {
    final url = _accountUrl(signed.group(1), method);
    if (url != null && (url.queryParameters['sign'] ?? '').isNotEmpty) {
      return AccountStepSigned(url);
    }
  }
  final doc = parseHtmlDocument(html);
  for (final form in doc.querySelectorAll('form')) {
    final action = _accountUrl(form.attributes['action'], method);
    if (action == null || (form.attributes['method'] ?? 'get').toLowerCase() != 'post') {
      continue;
    }
    final params = action.queryParameters;
    if (params['verify'] == 'password' && params['security_submit'] == 'yes') {
      final hidden = _hiddenOf(form, 'security_submit');
      final input = form.querySelector('input[name="password"]');
      if (hidden == null || input == null || (input.attributes['type'] ?? '').toLowerCase() != 'password') {
        return const AccountStepUnknown();
      }
      return AccountStepVerify(AccountVerifyForm(action: action, hidden: hidden));
    }
    if (params['submit'] == 'yes' && (params['sign'] ?? '').isNotEmpty) {
      final parsed = _methodForm(form, method, action);
      return parsed == null ? const AccountStepUnknown() : AccountStepForm(parsed);
    }
  }
  Uri? password;
  var others = false;
  for (final a in doc.querySelectorAll('a[href]')) {
    final url = _accountUrl(a.attributes['href'], method);
    final verify = url?.queryParameters['verify'];
    if (verify == null || verify.isEmpty) {
      continue;
    }
    if (verify == 'password') {
      password ??= url;
    } else {
      others = true;
    }
  }
  if (password != null || others) {
    return AccountStepChoose(password: password, others: others);
  }
  // A form the app did not take (another host, an unknown field) is never read as a message.
  if (doc.querySelector('form') != null) {
    return const AccountStepUnknown();
  }
  final message = doc.querySelector('#messagetext p') ?? doc.querySelector('.alert_error, .alert_right, .alert_info');
  final element = message ?? doc.body;
  final clone = element?.clone(true) as uh.Element?;
  clone?.querySelectorAll('script, style').forEach((e) => e.remove());
  final text = _text(clone);
  if (text.isEmpty) {
    return const AccountStepUnknown();
  }
  // The forum reloads the page after a change (`setTimeout("location.reload();", 1500)`), never after a refusal.
  return AccountStepMessage(text, success: html.contains('location.reload()'));
}

/// The tabs of the privacy page [doc] the app shows ([privacyOps]), in the forum's order.
List<PrivacyTab> parsePrivacyTabs(uh.Document doc) {
  final tabs = <PrivacyTab>[];
  for (final a in doc.querySelectorAll('ul.tb li a[href]')) {
    final uri = Uri.tryParse((a.attributes['href'] ?? '').replaceAll('&amp;', '&'));
    if (uri == null) {
      continue;
    }
    final op = uri.queryParameters['op'];
    if (op == null || !privacyOps.contains(op) || tabs.any((e) => e.op == op)) {
      continue;
    }
    if (canonicalForumOperationUrl(uri, {'mod': 'spacecp', 'ac': 'privacy', 'op': op}) == null) {
      continue;
    }
    tabs.add(PrivacyTab(op: op, title: _text(a)));
  }
  return tabs;
}

/// The privacy page [raw] of the account [expectedUid] at its tab [op]: the tabs it lists and the form of [op].
///
/// The form is null when the page has none for [op], or one with a field the app does not know: saving it would send
/// only a part of the tab, and the forum replaces the whole tab with what is sent. Null altogether for a page that is
/// not the privacy page of that account.
({List<PrivacyTab> tabs, PrivacySection? section})? parsePrivacyPage(
  String raw, {
  required int expectedUid,
  required String op,
}) {
  final doc = parseHtmlDocument(raw);
  if (forumPageProblem(doc, expectedUid: expectedUid, requireIdentity: true) != null) {
    return null;
  }
  final tabs = parsePrivacyTabs(doc);
  if (tabs.isEmpty) {
    return null;
  }
  final tab = tabs.where((e) => e.op == op).firstOrNull;
  if (tab == null) {
    return (tabs: tabs, section: null);
  }
  final query = {'mod': 'spacecp', 'ac': 'privacy', 'op': op};
  for (final form in doc.querySelectorAll('form')) {
    final raw = form.attributes['action'];
    final uri = raw == null ? null : Uri.tryParse(raw.replaceAll('&amp;', '&'));
    final action = uri == null ? null : canonicalForumOperationUrl(uri, query);
    if (action == null || (form.attributes['method'] ?? 'get').toLowerCase() != 'post') {
      continue;
    }
    return (tabs: tabs, section: _privacySection(form, tab, action));
  }
  return (tabs: tabs, section: null);
}

PrivacySection? _privacySection(uh.Element form, PrivacyTab tab, Uri action) {
  final fixed = <(String, String)>[];
  final items = <PrivacyItem>[];
  String? submit;
  for (final e in form.querySelectorAll('input, select, textarea, button')) {
    final name = e.attributes['name'];
    final type = (e.attributes['type'] ?? (e.localName == 'button' ? 'submit' : 'text')).toLowerCase();
    if (e.attributes.containsKey('disabled')) {
      continue;
    }
    if (e.localName == 'button' || type == 'submit') {
      if (name != null && name.isNotEmpty) {
        if (submit != null && submit != name) {
          return null;
        }
        if (submit == null) {
          submit = name;
          fixed.add((name, e.attributes['value'] ?? 'true'));
        }
      }
      continue;
    }
    if (name == null || name.isEmpty) {
      return null;
    }
    if (e.localName == 'select') {
      if (e.attributes.containsKey('multiple')) {
        return null;
      }
      final options = [
        for (final o in e.querySelectorAll('option')) (o.attributes['value'] ?? _text(o), _text(o)),
      ];
      if (options.isEmpty) {
        return null;
      }
      final selected = e.querySelector('option[selected]');
      items.add(
        PrivacyChoice(
          name: name,
          label: _labelOf(form, e),
          options: options,
          value: selected == null ? options.first.$1 : (selected.attributes['value'] ?? _text(selected)),
        ),
      );
      continue;
    }
    switch (type) {
      case 'hidden':
        fixed.add((name, e.attributes['value'] ?? ''));
      case 'checkbox':
        final label = e.parent?.localName == 'label' ? _text(e.parent) : _labelOf(form, e);
        items.add(
          PrivacyToggle(
            name: name,
            label: label,
            value: e.attributes['value'] ?? 'on',
            checked: e.attributes.containsKey('checked'),
          ),
        );
      default:
        // A text box or a radio a plugin added: not shown, so the tab is not saved at all.
        return null;
    }
  }
  if (submit == null || items.isEmpty || !fixed.any((e) => e.$1 == 'formhash' && e.$2.isNotEmpty)) {
    return null;
  }
  return PrivacySection(tab: tab, action: action, fixed: fixed, items: items);
}

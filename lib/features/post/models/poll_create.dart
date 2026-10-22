import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/utils/discuz_text.dart';
import 'package:universal_html/html.dart' as uh;

export 'package:tsdm_client/features/post/utils/discuz_text.dart' show discuzEscape, discuzStrLen;

/// Subject limit enforced by the upstream post handler (`dstrlen($subject) > 255`).
const int pollSubjectServerLimit = discuzSubjectServerLimit;

/// Conservative client guard for one poll choice, NOT an observed form limit.
///
/// Upstream stores each escaped choice in a `varchar(80)` column; the live database schema is not verified.
const pollOptionStorageGuard = 80;

/// Characters one choice occupies once the server escaped it for storage.
int pollOptionStorageLength(String option) => discuzEscape(option).runes.length;

/// Parse the expiration field into days: `0` is unlimited, `null` is invalid.
///
/// The server treats only an empty string or exactly `'0'` as unlimited; `'00'` or `' 0 '` would end the poll
/// immediately. The app therefore converts once and posts the canonical value (see [PollSubmission.expirationValue]).
int? parsePollExpiryDays(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 0;
  if (!RegExp(r'^\d+$').hasMatch(trimmed)) return null;
  return int.tryParse(trimmed);
}

enum _TokenKind { identifier, number, string, regex, punctuation }

typedef _Token = ({_TokenKind kind, String text});

const _regexPrefixKeywords = {'return', 'typeof', 'case', 'do', 'else', 'in', 'of', 'new', 'delete', 'void', 'throw'};

/// Tokens of an inline script with comments dropped and string/regex literals kept as single tokens.
///
/// Returns null for an unterminated comment or literal. This is a bounded scanner, never an interpreter.
List<_Token>? _scriptTokens(String source) {
  final tokens = <_Token>[];
  final n = source.length;
  bool isIdentifier(String c) => RegExp(r'[A-Za-z0-9_$]').hasMatch(c);
  var i = 0;
  while (i < n) {
    final c = source[i];
    if (c.trim().isEmpty) {
      i++;
    } else if (source.startsWith('//', i) || source.startsWith('<!--', i)) {
      final end = source.indexOf('\n', i);
      i = end < 0 ? n : end + 1;
    } else if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      if (end < 0) return null;
      i = end + 2;
    } else if (c == '"' || c == "'" || c == '`') {
      final value = StringBuffer();
      var j = i + 1;
      var closed = false;
      while (j < n) {
        final d = source[j];
        if (d == r'\') {
          if (j + 1 < n) value.write(source[j + 1]);
          j += 2;
          continue;
        }
        if (d == c) {
          closed = true;
          break;
        }
        if (d == '\n' && c != '`') return null;
        value.write(d);
        j++;
      }
      if (!closed) return null;
      tokens.add((kind: _TokenKind.string, text: value.toString()));
      i = j + 1;
    } else if (c == '/' &&
        switch (tokens.lastOrNull) {
          null => true,
          (kind: _TokenKind.punctuation, :final text) => text != ')' && text != ']',
          (kind: _TokenKind.identifier, :final text) => _regexPrefixKeywords.contains(text),
          _ => false,
        }) {
      var j = i + 1;
      var inClass = false;
      var closed = false;
      while (j < n) {
        final d = source[j];
        if (d == r'\') {
          j += 2;
          continue;
        }
        if (d == '\n') return null;
        if (d == '[') {
          inClass = true;
        } else if (d == ']') {
          inClass = false;
        } else if (d == '/' && !inClass) {
          closed = true;
          break;
        }
        j++;
      }
      if (!closed) return null;
      j++;
      while (j < n && isIdentifier(source[j])) {
        j++;
      }
      tokens.add((kind: _TokenKind.regex, text: ''));
      i = j;
    } else if (isIdentifier(c)) {
      var j = i + 1;
      while (j < n && (isIdentifier(source[j]) || (RegExp(r'\d').hasMatch(c) && source[j] == '.'))) {
        j++;
      }
      final text = source.substring(i, j);
      tokens.add((kind: RegExp(r'^\d').hasMatch(text) ? _TokenKind.number : _TokenKind.identifier, text: text));
      i = j;
    } else {
      tokens.add((kind: _TokenKind.punctuation, text: c));
      i++;
    }
  }
  return tokens;
}

/// Values of the supported `var maxoptions = parseInt('<digits>');` declarations in one inline script.
///
/// Occurrences inside comments or string literals are not declarations. Returns null when the script cannot be
/// scanned or `maxoptions` is assigned in any other form, so the caller falls back to the browser.
List<int>? maxOptionsDeclarations(String script) {
  final tokens = _scriptTokens(script);
  if (tokens == null) return null;
  bool punct(int index, String text) =>
      index >= 0 && index < tokens.length && tokens[index].kind == _TokenKind.punctuation && tokens[index].text == text;
  final values = <int>[];
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i].kind != _TokenKind.identifier || tokens[i].text != 'maxoptions') continue;
    final assigned =
        (punct(i + 1, '=') && !punct(i + 2, '=')) ||
        ('+-*/%&|^'.split('').any((op) => punct(i + 1, op)) && punct(i + 2, '=')) ||
        (punct(i + 1, '+') && punct(i + 2, '+')) ||
        (punct(i + 1, '-') && punct(i + 2, '-')) ||
        (punct(i - 1, '+') && punct(i - 2, '+')) ||
        (punct(i - 1, '-') && punct(i - 2, '-'));
    if (!assigned) continue;
    final declared =
        i >= 1 &&
        tokens[i - 1] == (kind: _TokenKind.identifier, text: 'var') &&
        !punct(i - 2, '.') &&
        punct(i + 1, '=') &&
        i + 3 < tokens.length &&
        tokens[i + 2] == (kind: _TokenKind.identifier, text: 'parseInt') &&
        punct(i + 3, '(') &&
        i + 4 < tokens.length &&
        tokens[i + 4].kind == _TokenKind.string &&
        RegExp(r'^\d{1,6}$').hasMatch(tokens[i + 4].text) &&
        punct(i + 5, ')') &&
        (i + 6 == tokens.length || punct(i + 6, ';'));
    if (!declared) return null;
    values.add(int.parse(tokens[i + 4].text));
  }
  return values;
}

/// A checkbox of the poll section as served, e.g. `visibilitypoll` or `overt`.
final class PollFlagField {
  /// Constructor.
  const PollFlagField({required this.name, required this.value, required this.initiallyChecked});

  /// Form field name.
  final String name;

  /// Value posted when checked.
  final String value;

  /// Served `checked` attribute.
  final bool initiallyChecked;
}

/// A validated ordinary (special=1) poll creation form of one forum, served to one account.
final class PollCreateForm {
  /// Constructor.
  const PollCreateForm({
    required this.fid,
    required this.uid,
    required this.actionUrl,
    required this.formHash,
    required this.postTime,
    required this.wysiwyg,
    required this.maxOptions,
    required this.initialMaxChoices,
    required this.initialExpiration,
    required this.visibility,
    required this.overt,
    required this.neutralPluginFields,
    required this.passthroughFields,
    required this.subjectLimit,
    required this.content,
    required this.forumName,
    this.postForm,
  });

  /// Forum id bound to this form.
  final String fid;

  /// Account the form was served to.
  final int uid;

  /// Validated same-origin submit url.
  final String actionUrl;

  /// Form token.
  final String formHash;

  /// Served post time.
  final String postTime;

  /// Served editor mode.
  final String wysiwyg;

  /// Dynamic `maxoptions` of the forum.
  final int maxOptions;

  /// Served `maxchoices` value.
  final int initialMaxChoices;

  /// Served `expiration` value.
  final String initialExpiration;

  /// "Results visible after voting" checkbox, null when not served.
  final PollFlagField? visibility;

  /// "Public voters" checkbox, null when not served.
  final PollFlagField? overt;

  /// Recognized site plugin fields served with their neutral value `0`; absent fields stay absent.
  final Map<String, String> neutralPluginFields;

  /// Other served hidden fields posted back unchanged (e.g. `checkbox`, `save`).
  final Map<String, String> passthroughFields;

  /// Subject limit counted with [discuzStrLen].
  final int subjectLimit;

  /// Ordinary parts: thread types, bool options, served body.
  final PostEditContent content;

  /// Forum name in the breadcrumb, if any.
  final String? forumName;

  /// The post form of the forum's app API this form was built from ([fromPostForm], plugin 2.9.0), posted back with
  /// the poll over every served value ([PollSubmission.toPayload]); null for a form parsed from the web page.
  final PostForm? postForm;

  /// Poll-section field names this client understands.
  static const _knownPollFields = {
    'special',
    'polls',
    'tpolloption',
    'polloption[]',
    'polloptions',
    'pollimage[]',
    'maxchoices',
    'expiration',
    'visibilitypoll',
    'overt',
    'pollplusviewcredit',
    'pollpluslockday',
  };

  /// Fields this client fills or posts back; a `required` attribute on any other control is not understood.
  static const _filledFields = {
    'formhash',
    'posttime',
    'wysiwyg',
    'special',
    'polls',
    'fid',
    'typeid',
    'subject',
    'message',
    'tpolloption',
    'polloption[]',
    'polloptions',
    'maxchoices',
    'expiration',
  };

  /// Controls whose value is posted: a disabled one would not be sent by the website.
  static const Set<String> _essentialFields = {
    ..._filledFields,
    'visibilitypoll',
    'overt',
    'pollplusviewcredit',
    'pollpluslockday',
    'readperm',
    'checkbox',
    'mastertid',
    'delattachop',
    'save',
  };

  /// Controls the user edits here; the website would not let them be changed when read-only.
  static const _editedFields = {'subject', 'message', 'polloptions', 'maxchoices', 'expiration', 'typeid'};

  static final _pollFieldRe = RegExp('^(poll|tpoll|maxchoices|expiration|visibilitypoll|overt)');

  /// Whether [name] belongs to the poll section rather than the ordinary editor.
  static bool isPollField(String name) => name == 'special' || _pollFieldRe.hasMatch(name);

  /// Own `disabled` attribute or an enclosing disabled fieldset inside [form].
  static bool _isDisabled(uh.Element control, uh.Element form) {
    for (uh.Element? e = control; e != null && e != form; e = e.parent) {
      if (e.attributes.containsKey('disabled') && (e == control || e.localName == 'fieldset')) return true;
    }
    return false;
  }

  /// Validate the special=1 form of [fid] served to [uid]; anything not understood falls back to the browser.
  static PollFormParse parse(uh.Document document, {required String fid, required int uid}) {
    final form = document.querySelector('form#postform');
    if (form == null) {
      final message = document.querySelector('#messagetext');
      if (message == null) return const PollFormParse.unsupported();
      final text = (message.querySelector('p') ?? message).innerText.trim();
      return PollFormParse.denied(text);
    }

    final action = draftForumUri(form.attributes['action']);
    final query = action?.queryParameters ?? const <String, String>{};
    if (action == null ||
        action.path != '/forum.php' ||
        query['mod'] != 'post' ||
        query['action'] != 'newthread' ||
        query['fid'] != fid ||
        query['topicsubmit'] != 'yes' ||
        (query.containsKey('special') && query['special'] != '1')) {
      return const PollFormParse.unsupported();
    }

    final controls = form.querySelectorAll('input[name], select[name], textarea[name]');
    List<uh.Element> named(String name) => controls.where((e) => e.attributes['name'] == name).toList();
    String? single(String name, {String tag = 'input'}) {
      final nodes = named(name);
      if (nodes.length != 1 || nodes.first.localName != tag) return null;
      return nodes.first.localName == 'textarea' ? nodes.first.text ?? '' : nodes.first.attributes['value'] ?? '';
    }

    // Challenges and structured editors are only handled by the website.
    if (controls.any((e) {
      final name = e.attributes['name']!;
      return name.startsWith('seccode') || name.startsWith('secqaa') || name == 'secanswer';
    })) {
      return const PollFormParse.unsupported();
    }

    // A required control the app does not fill, or a disabled/read-only control it would post or edit, means the
    // website expects something this editor cannot reproduce. Unknown optional template fields are left alone.
    for (final control in controls) {
      final name = control.attributes['name']!;
      final isRequired =
          control.attributes.containsKey('required') || control.attributes['aria-required']?.toLowerCase() == 'true';
      if (isRequired && !_filledFields.contains(name)) return const PollFormParse.unsupported();
      if (_essentialFields.contains(name) && _isDisabled(control, form)) return const PollFormParse.unsupported();
      if (_editedFields.contains(name) && control.attributes.containsKey('readonly')) {
        return const PollFormParse.unsupported();
      }
    }
    // Served bool options inside a disabled fieldset would be shown as editable here.
    if (form.querySelectorAll('fieldset[disabled] input[type="checkbox"][name]').isNotEmpty) {
      return const PollFormParse.unsupported();
    }

    final formHash = single('formhash');
    final postTime = single('posttime');
    final wysiwyg = single('wysiwyg');
    if (formHash == null || formHash.isEmpty || postTime == null || wysiwyg == null) {
      return const PollFormParse.unsupported();
    }
    if (single('special') != '1' || single('polls') != 'yes') return const PollFormParse.unsupported();
    final tpolloption = single('tpolloption');
    if (tpolloption != '1' && tpolloption != '2') return const PollFormParse.unsupported();
    // Bulk entry avoids posting repeated `polloption[]` keys, which the Android client cannot encode.
    if (single('polloptions', tag: 'textarea') == null) return const PollFormParse.unsupported();
    final maxChoices = single('maxchoices');
    final expiration = single('expiration');
    if (maxChoices == null || expiration == null) return const PollFormParse.unsupported();
    if (named('fid').any((e) => e.attributes['value'] != fid)) return const PollFormParse.unsupported();

    // Every poll-looking field must be understood; empty per-row templates are never posted.
    for (final control in controls) {
      final name = control.attributes['name']!;
      if (!isPollField(name)) continue;
      if (!_knownPollFields.contains(name)) return const PollFormParse.unsupported();
      if (name == 'pollimage[]' && (control.attributes['value'] ?? '').isNotEmpty) {
        return const PollFormParse.unsupported();
      }
    }

    PollFlagField? flag(String name) {
      final nodes = named(name);
      if (nodes.isEmpty) return null;
      final node = nodes.first;
      if (nodes.length != 1 ||
          node.localName != 'input' ||
          node.attributes['type'] != 'checkbox' ||
          node.attributes['value'] != '1' ||
          node.attributes.containsKey('disabled')) {
        throw const FormatException('Unsupported poll flag');
      }
      return PollFlagField(name: name, value: '1', initiallyChecked: node.attributes.containsKey('checked'));
    }

    final PollFlagField? visibility;
    final PollFlagField? overt;
    try {
      visibility = flag('visibilitypoll');
      overt = flag('overt');
    } on FormatException {
      return const PollFormParse.unsupported();
    }

    final neutral = <String, String>{};
    for (final name in const ['pollplusviewcredit', 'pollpluslockday']) {
      final nodes = named(name);
      if (nodes.isEmpty) continue;
      // Non-neutral or unknown plugin rules would be lost by this editor.
      if (nodes.length != 1 || nodes.first.localName != 'input' || nodes.first.attributes['value']?.trim() != '0') {
        return const PollFormParse.unsupported();
      }
      neutral[name] = '0';
    }

    final maxOptionValues = <int>{};
    for (final script in document.querySelectorAll('script')) {
      final type = script.attributes['type']?.toLowerCase();
      if (script.attributes.containsKey('src') || (type != null && type.isNotEmpty && !type.contains('javascript'))) {
        continue;
      }
      final text = script.text ?? '';
      if (!text.contains('maxoptions')) continue;
      final values = maxOptionsDeclarations(text);
      if (values == null) return const PollFormParse.unsupported();
      maxOptionValues.addAll(values);
    }
    if (maxOptionValues.length != 1 || maxOptionValues.first < 2) return const PollFormParse.unsupported();

    final content = PostEditContent.fromPollCreateDocument(document);
    if (content == null) return const PollFormParse.unsupported();

    final passthrough = <String, String>{if (named('fid').isNotEmpty) 'fid': fid};
    for (final name in const ['checkbox', 'mastertid', 'delattachop']) {
      final value = single(name);
      if (value != null) passthrough[name] = value;
    }
    // The draft switch stays at its served empty value: poll drafts are not created in the app.
    final save = form.querySelector('#postsave[name="save"]');
    if (save != null) {
      if ((save.attributes['value'] ?? '').isNotEmpty) return const PollFormParse.unsupported();
      passthrough['save'] = '';
    }

    final served = content.threadTitleMaxLength;
    return PollFormParse.ready(
      PollCreateForm(
        fid: fid,
        uid: uid,
        actionUrl: Uri.parse(baseUrl).replace(path: action.path, query: action.query).toString(),
        formHash: formHash,
        postTime: postTime,
        wysiwyg: wysiwyg,
        maxOptions: maxOptionValues.first,
        initialMaxChoices: int.tryParse(maxChoices.trim()) ?? 1,
        initialExpiration: expiration,
        visibility: visibility,
        overt: overt,
        neutralPluginFields: Map.unmodifiable(neutral),
        passthroughFields: Map.unmodifiable(passthrough),
        subjectLimit: served != null && served > 0 && served < pollSubjectServerLimit ? served : pollSubjectServerLimit,
        content: content,
        forumName: document.querySelectorAll('div#pt > div.z > a[href*="fid="]').lastOrNull?.text?.trim(),
      ),
    );
  }

  /// Poll inputs of the post form of the forum's app API this client understands; [_knownPollFields] of the page.
  static const _knownPollInputs = {
    'polls',
    'fid',
    'tpolloption',
    'polloptions',
    'maxchoices',
    'expiration',
    'visibilitypoll',
    'overt',
  };

  /// Validate the post form [form] of the forum's app API (plugin 2.9.0) as the special=1 form of [fid] served to
  /// [uid], as [parse] validates the web page: a new poll ([PostForm.special] 1, `poll` block), posted to a new thread
  /// url of [fid], with the bulk choice field (`tpolloption` and the `polloptions` text area: one choice per line, the
  /// repeated `polloption[]` fields cannot be posted) and the editable poll fields neither read-only nor unknown; the
  /// result flags only as plain checkboxes posting `1`; no captcha, no field of another plugin, nothing the plugin
  /// says to leave to the website ([PostForm.unsupported]), a body the transport can carry ([PostFormBody.toMap]).
  /// The choice limit is the forum's (`poll.max_options`), not read from the page script.
  ///
  /// A form with fields other plugins printed ([PostForm.hookFields]) is not taken here: the caller reads the web
  /// page instead, whose parser knows the neutral fields of the site's poll plugin ([neutralPluginFields]).
  static PollFormParse fromPostForm(PostForm form, {required String fid, required int uid}) {
    if (form.uid != uid ||
        form.action != 'newthread' ||
        form.special != 1 ||
        form.asksVerification ||
        form.unsupported.isNotEmpty ||
        form.hookFields.isNotEmpty ||
        form.message == null) {
      return const PollFormParse.unsupported();
    }
    final action = draftForumUri(form.submitUrl);
    final query = action?.queryParameters ?? const <String, String>{};
    if (action == null ||
        query['action'] != 'newthread' ||
        query['fid'] != fid ||
        (query.containsKey('special') && query['special'] != '1')) {
      return const PollFormParse.unsupported();
    }
    final fields = form.submitFields;
    final formHash = fields['formhash'];
    final postTime = fields['posttime'];
    final wysiwyg = fields['wysiwyg'];
    if (formHash == null || formHash.isEmpty || postTime == null || wysiwyg == null) {
      return const PollFormParse.unsupported();
    }
    if ((fields['special'] ?? '1') != '1' || (fields['save'] ?? '').isNotEmpty) {
      return const PollFormParse.unsupported();
    }
    final inputs = form.blockInputs('poll');
    PostFormInput? input(String name) => inputs.where((e) => e.name == name).firstOrNull;
    if (inputs.any((e) => !_knownPollInputs.contains(e.name)) ||
        input('polls')?.value != 'yes' ||
        input('tpolloption') == null ||
        input('polloptions')?.type != 'textarea' ||
        input('fid')?.value != fid) {
      return const PollFormParse.unsupported();
    }
    final maxChoices = input('maxchoices');
    final expiration = input('expiration');
    if (maxChoices == null ||
        expiration == null ||
        [maxChoices, expiration, input('polloptions')!].any((e) => e.readonly || e.disabled)) {
      return const PollFormParse.unsupported();
    }
    PollFlagField? flag(String name) {
      final node = input(name);
      if (node == null) return null;
      if (!node.isCheckbox || node.value != '1' || node.disabled) throw const FormatException('Unsupported poll flag');
      return PollFlagField(name: name, value: '1', initiallyChecked: node.checked);
    }

    final PollFlagField? visibility;
    final PollFlagField? overt;
    try {
      visibility = flag('visibilitypoll');
      overt = flag('overt');
    } on FormatException {
      return const PollFormParse.unsupported();
    }
    final maxOptions = form.pollMaxOptions;
    if (maxOptions == null || maxOptions < 2) return const PollFormParse.unsupported();
    final content = PostEditContent.fromPostForm(form);
    if (content == null || form.body().toMap() == null) return const PollFormParse.unsupported();
    return PollFormParse.ready(
      PollCreateForm(
        fid: fid,
        uid: uid,
        actionUrl: form.submitUrl!,
        formHash: formHash,
        postTime: postTime,
        wysiwyg: wysiwyg,
        maxOptions: maxOptions,
        initialMaxChoices: int.tryParse(maxChoices.value?.trim() ?? '') ?? 1,
        initialExpiration: expiration.value ?? '',
        visibility: visibility,
        overt: overt,
        neutralPluginFields: const {},
        passthroughFields: const {},
        subjectLimit: form.subjectLimit,
        content: content,
        forumName: form.forumName,
        postForm: form,
      ),
    );
  }

  /// Preselected read permission, posted back unchanged.
  String? get readPerm => content.permList?.where((e) => e.selected).lastOrNull?.perm;

  /// Served bool options of the ordinary editor, without any poll field.
  List<PostEditContentOption> get extraOptions =>
      (content.options ?? const []).where((e) => !isPollField(e.name)).toList();
}

/// Kind of [PollFormParse].
enum PollFormParseKind {
  /// Supported form.
  ready,

  /// The forum answered with a message (e.g. no permission).
  denied,

  /// Unknown or structured form: continue in the browser.
  unsupported,
}

/// Result of [PollCreateForm.parse].
final class PollFormParse {
  /// Supported form.
  const PollFormParse.ready(PollCreateForm this.form) : kind = PollFormParseKind.ready, message = null;

  /// Message page.
  const PollFormParse.denied(String this.message) : kind = PollFormParseKind.denied, form = null;

  /// Browser fallback.
  const PollFormParse.unsupported() : kind = PollFormParseKind.unsupported, form = null, message = null;

  /// Kind.
  final PollFormParseKind kind;

  /// Form when [kind] is ready.
  final PollCreateForm? form;

  /// Plain server text when [kind] is denied.
  final String? message;
}

/// Why the poll input cannot be submitted.
enum PollInputIssue {
  /// Subject is empty.
  subjectEmpty,

  /// Subject exceeds [PollCreateForm.subjectLimit].
  subjectTooLong,

  /// The selected thread type is not offered by the form (types are optional for polls).
  threadTypeUnavailable,

  /// "Results visible after voting" or "public voters" is on but the form no longer offers it.
  flagUnavailable,

  /// A checked additional option is no longer offered or can no longer be changed.
  extraOptionUnavailable,

  /// A choice contains a line break, which the bulk encoding would split.
  optionLineBreak,

  /// A choice exceeds [pollOptionStorageGuard] once escaped.
  optionTooLong,

  /// Fewer than 2 non-empty choices.
  tooFewOptions,

  /// More choices than the forum's `maxoptions`.
  tooManyOptions,

  /// Max choices is not an integer between 1 and the number of choices.
  maxChoicesInvalid,

  /// Expiration is neither empty/0 nor a positive integer.
  expiryInvalid,
}

/// Raw poll input as typed by the user.
final class PollDraft {
  /// Constructor.
  const PollDraft({
    required this.subject,
    required this.message,
    required this.options,
    required this.maxChoices,
    required this.expiry,
    required this.visibleAfterVote,
    required this.publicVoters,
    required this.threadType,
    required this.extraOptions,
  });

  /// Subject.
  final String subject;

  /// Optional body (BBCode).
  final String message;

  /// Choice rows, blank rows included.
  final List<String> options;

  /// Max choices text.
  final String maxChoices;

  /// Expiration text in days.
  final String expiry;

  /// Results visible only after voting.
  final bool visibleAfterVote;

  /// Voters are public.
  final bool publicVoters;

  /// Selected thread type.
  final PostEditThreadType? threadType;

  /// Served bool options with the user's choice.
  final List<PostEditContentOption> extraOptions;
}

/// Outcome of [validatePollDraft]: either issues or one canonical submission.
final class PollValidation {
  /// Constructor.
  const PollValidation({required this.issues, required this.optionIssues, this.submission});

  /// Field issues.
  final Set<PollInputIssue> issues;

  /// Issue of each choice row (same index as [PollDraft.options]).
  final Map<int, PollInputIssue> optionIssues;

  /// Submission when valid.
  final PollSubmission? submission;

  /// Whether the draft can be confirmed.
  bool get isValid => submission != null;
}

/// Validate [draft] against [form]; the confirmation and the payload use the returned submission only.
PollValidation validatePollDraft(PollDraft draft, PollCreateForm form) {
  final issues = <PollInputIssue>{};
  final optionIssues = <int, PollInputIssue>{};

  final subject = draft.subject.trim();
  if (subject.isEmpty) {
    issues.add(PollInputIssue.subjectEmpty);
  } else if (discuzStrLen(discuzEscape(subject)) > form.subjectLimit) {
    issues.add(PollInputIssue.subjectTooLong);
  }

  // Upstream skips `post_type_isnull` for special threads: a poll may have no type even where ordinary threads need
  // one. A positive selection must be one of the served choices.
  final types = form.content.threadTypeList ?? const [];
  final selectedType = draft.threadType;
  final typeId = int.tryParse(selectedType?.typeID ?? '') ?? 0;
  final PostEditThreadType? threadType;
  if (typeId > 0) {
    threadType = types.where((e) => e.typeID == selectedType!.typeID).firstOrNull;
    if (threadType == null) issues.add(PollInputIssue.threadTypeUnavailable);
  } else {
    threadType = null;
  }

  if ((draft.visibleAfterVote && form.visibility == null) || (draft.publicVoters && form.overt == null)) {
    issues.add(PollInputIssue.flagUnavailable);
  }

  final offeredExtras = {for (final option in form.extraOptions) option.name: option};
  final extras = <PostEditContentOption>[];
  for (final option in draft.extraOptions.where((e) => e.checked)) {
    final offered = offeredExtras[option.name];
    if (offered == null) {
      issues.add(PollInputIssue.extraOptionUnavailable);
    } else if (!offered.disabled) {
      if (offered.value != option.value) issues.add(PollInputIssue.extraOptionUnavailable);
      extras.add(offered.copyWith(checked: true));
    } else if (!offered.checked) {
      // Served disabled and unchecked: the website would not send it.
      issues.add(PollInputIssue.extraOptionUnavailable);
    }
  }

  final options = <String>[];
  for (var i = 0; i < draft.options.length; i++) {
    final option = draft.options[i].trim();
    if (option.contains('\n') || option.contains('\r')) {
      optionIssues[i] = PollInputIssue.optionLineBreak;
    } else if (pollOptionStorageLength(option) > pollOptionStorageGuard) {
      optionIssues[i] = PollInputIssue.optionTooLong;
    }
    if (option.isNotEmpty) options.add(option);
  }
  if (optionIssues.isNotEmpty) issues.addAll(optionIssues.values);
  if (options.length < 2) issues.add(PollInputIssue.tooFewOptions);
  if (options.length > form.maxOptions) issues.add(PollInputIssue.tooManyOptions);

  final maxChoicesText = draft.maxChoices.trim();
  final maxChoices = RegExp(r'^\d+$').hasMatch(maxChoicesText) ? int.tryParse(maxChoicesText) : null;
  if (maxChoices == null || maxChoices < 1 || maxChoices > options.length) {
    issues.add(PollInputIssue.maxChoicesInvalid);
  }

  final expiry = parsePollExpiryDays(draft.expiry);
  if (expiry == null) issues.add(PollInputIssue.expiryInvalid);

  if (issues.isNotEmpty) return PollValidation(issues: issues, optionIssues: optionIssues);
  return PollValidation(
    issues: const {},
    optionIssues: const {},
    submission: PollSubmission(
      subject: subject,
      message: draft.message,
      options: List.unmodifiable(options),
      maxChoices: maxChoices!,
      expiryDays: expiry!,
      visibleAfterVote: draft.visibleAfterVote,
      publicVoters: draft.publicVoters,
      threadType: threadType,
      extraOptions: List.unmodifiable(extras),
    ),
  );
}

/// Whether [submission], confirmed on [confirmed], is posted unchanged with the freshly served [fresh] form.
///
/// Token and post time may be refreshed; any change of limits, offered flags, types, options, plugin rules, read
/// permission or editor mode that would alter or invalidate the confirmed poll returns false.
bool pollSubmissionFitsFreshForm({
  required PollSubmission submission,
  required PollCreateForm confirmed,
  required PollCreateForm fresh,
}) {
  if (fresh.fid != confirmed.fid || fresh.uid != confirmed.uid || fresh.wysiwyg != confirmed.wysiwyg) return false;
  if (fresh.readPerm != confirmed.readPerm) return false;
  final plugin = fresh.neutralPluginFields;
  if (plugin.length != confirmed.neutralPluginFields.length ||
      plugin.entries.any((e) => confirmed.neutralPluginFields[e.key] != e.value)) {
    return false;
  }
  final revalidated = validatePollDraft(
    PollDraft(
      subject: submission.subject,
      message: submission.message,
      options: submission.options,
      maxChoices: '${submission.maxChoices}',
      expiry: '${submission.expiryDays}',
      visibleAfterVote: submission.visibleAfterVote,
      publicVoters: submission.publicVoters,
      threadType: submission.threadType,
      extraOptions: submission.extraOptions,
    ),
    fresh,
  ).submission;
  if (revalidated == null) return false;
  String extras(PollSubmission s) => [for (final e in s.extraOptions) '${e.name}=${e.value}'].join('&');
  return revalidated.subject == submission.subject &&
      revalidated.message == submission.message &&
      revalidated.options.join('\n') == submission.options.join('\n') &&
      revalidated.maxChoices == submission.maxChoices &&
      revalidated.expiryDays == submission.expiryDays &&
      revalidated.visibleAfterVote == submission.visibleAfterVote &&
      revalidated.publicVoters == submission.publicVoters &&
      revalidated.threadType?.typeID == submission.threadType?.typeID &&
      extras(revalidated) == extras(submission);
}

/// The exact poll shown in the confirmation and posted once.
final class PollSubmission {
  /// Constructor.
  const PollSubmission({
    required this.subject,
    required this.message,
    required this.options,
    required this.maxChoices,
    required this.expiryDays,
    required this.visibleAfterVote,
    required this.publicVoters,
    required this.threadType,
    required this.extraOptions,
  });

  /// Trimmed subject.
  final String subject;

  /// Optional body.
  final String message;

  /// Trimmed non-empty choices in order.
  final List<String> options;

  /// Max choices, 1 means single choice.
  final int maxChoices;

  /// Days until the poll ends, 0 means unlimited.
  final int expiryDays;

  /// Results visible only after voting.
  final bool visibleAfterVote;

  /// Voters are public.
  final bool publicVoters;

  /// Selected thread type.
  final PostEditThreadType? threadType;

  /// Checked served bool options.
  final List<PostEditContentOption> extraOptions;

  /// Canonical expiration: empty for unlimited, never `'00'` or a padded zero.
  String get expirationValue => expiryDays == 0 ? '' : '$expiryDays';

  /// URL-encoded fields for [form], one value per key.
  ///
  /// A form of the forum's app API ([PollCreateForm.postForm], plugin 2.9.0) posts every served field as the website
  /// would ([PostForm.body]) with the poll over it: the title, the body, the choices one per line (`tpolloption` 2,
  /// `polloptions`), the limits, the result flags, the type and the checked additional options.
  Map<String, String> toPayload(PollCreateForm form) {
    if (form.postForm case final PostForm postForm) {
      return _postFormPayload(form, postForm);
    }
    final body = <String, String>{
      ...form.passthroughFields,
      'formhash': form.formHash,
      'posttime': form.postTime,
      'wysiwyg': form.wysiwyg,
      'special': '1',
      'polls': 'yes',
      'subject': subject,
      'message': toOfficialMentions(message),
      'tpolloption': '2',
      'polloptions': options.join('\n'),
      'maxchoices': '$maxChoices',
      'expiration': expirationValue,
      ...form.neutralPluginFields,
    };
    if (form.visibility != null && visibleAfterVote) body[form.visibility!.name] = form.visibility!.value;
    if (form.overt != null && publicVoters) body[form.overt!.name] = form.overt!.value;
    // Without a selection the served selector posts its neutral `0`, as the website does.
    final typeId = threadType?.typeID;
    if (typeId != null) {
      body['typeid'] = typeId;
    } else if (form.content.threadTypeList?.isNotEmpty ?? false) {
      body['typeid'] = '0';
    }
    final perm = form.readPerm;
    if (perm != null && perm.isNotEmpty) body['readperm'] = perm;
    for (final option in extraOptions) {
      body[option.name] = option.value;
    }
    return body;
  }

  Map<String, String> _postFormPayload(PollCreateForm form, PostForm postForm) {
    final checked = {for (final option in extraOptions) option.name};
    final body =
        postForm.bodyWith(
            PostFormEdits(
              message: toOfficialMentions(message),
              subject: subject,
              typeId: threadType?.typeID,
              options: {
                for (final option in form.extraOptions.where((e) => !e.disabled))
                  option.name: checked.contains(option.name),
              },
            ),
          )
          // One choice per line: the repeated `polloption[]` fields of the website's rows cannot be posted.
          ..removeWhere((name) => name == 'polloption[]' || name == 'pollimage[]')
          ..set('tpolloption', '2')
          ..set('polloptions', options.join('\n'))
          ..set('maxchoices', '$maxChoices')
          ..set('expiration', expirationValue);
    if (form.visibility case final flag?) body.set(flag.name, visibleAfterVote ? flag.value : null);
    if (form.overt case final flag?) body.set(flag.name, publicVoters ? flag.value : null);
    // The confirmed form was checked to carry the body as a map (PollCreateForm.fromPostForm).
    return body.toMap() ?? const {};
  }
}

/// Carries the ordinary subject/body when the user switches between the ordinary and poll editors.
///
/// Bound to the account that typed it; the receiving page ignores it for any other account.
final class ThreadModeTransfer {
  /// Constructor.
  const ThreadModeTransfer({required this.uid, required this.fid, required this.subject, required this.body});

  /// Account that typed the content.
  final int uid;

  /// Forum of the editor.
  final String fid;

  /// Subject.
  final String subject;

  /// Body (forum BBCode).
  final String body;

  /// The transfer only applies to the same account and forum.
  bool appliesTo({required int? uid, required String fid}) => uid != null && uid == this.uid && fid == this.fid;
}

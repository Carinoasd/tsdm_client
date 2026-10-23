part of 'models.dart';

final _hashRe = RegExp(r'^\w+$');
final _updateSecCodeRe = RegExp(
  r'''updateseccode\(\s*['"](\w+)['"](?:\s*,\s*['"][^'"]*['"]\s*,\s*['"]([\w:]+)['"])?''',
);
final _updateSecQaaRe = RegExp(r'''updatesecqaa\(\s*['"](\w+)['"]''');

/// What the forum asks before it takes a post (Discuz `seccheck`): a captcha ([seccode]), a security question
/// ([secqaa]) or both, and the ids the answers go with.
///
/// Each check has an id (`idhash`: `c…` for the captcha, `q…` for the question). The forum keeps the expected answer
/// under that id (a cookie of the session and a row of its own) when the image or the question is asked, and finds it
/// again by the id posted with the answer (`seccodehash`, `secqaahash`), so the image or question must be asked with
/// the id the answer is posted with. [modid] names the page the check belongs to (`forum::post` for the post forms and
/// the reply window, `forum::viewthread` for the quick reply); it matters to a captcha of a plugin only.
@MappableClass()
final class SecCheck with SecCheckMappable {
  /// Constructor.
  const SecCheck({
    this.seccode = false,
    this.secqaa = false,
    this.seccodeHash = '',
    this.secqaaHash = '',
    this.modid = postModid,
  });

  /// The checks of a form refused for them when posted (a site asking by the number of posts or their interval decides
  /// only then, and the form told no ids): ids of the app's own, unique enough for the session (the forum takes any
  /// word as an id, see [SecCheck]).
  factory SecCheck.generated({bool seccode = false, bool secqaa = false, String modid = postModid}) {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return SecCheck(
      seccode: seccode,
      secqaa: secqaa,
      seccodeHash: seccode ? 'cSA$stamp' : '',
      secqaaHash: secqaa ? 'qSA$stamp' : '',
      modid: modid,
    );
  }

  /// The checks of the post forms and the reply window.
  static const postModid = 'forum::post';

  /// The checks of the quick reply of a thread page.
  static const viewthreadModid = 'forum::viewthread';

  /// The checks of the forum's app API answer [json] (`seccheck` of a post form, schema 16; `reply.seccheck` of a thread
  /// page, plugin 2.9.1): `{"seccode":1,"secqaa":0,"seccode_hash":"cS…","secqaa_hash":null,"modid":"forum::post"}`.
  /// Null when it asks for nothing; a check asked without an id gets one of its own ([SecCheck.generated]).
  static SecCheck? fromJson(Object? json, {String modid = postModid}) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final seccode = json['seccode'] == 1 || json['seccode'] == true;
    final secqaa = json['secqaa'] == 1 || json['secqaa'] == true;
    if (!seccode && !secqaa) {
      return null;
    }
    String? hash(String key) {
      final value = json[key];
      return value is String && _hashRe.hasMatch(value) ? value : null;
    }

    final named = json['modid'];
    final generated = SecCheck.generated(
      seccode: seccode,
      secqaa: secqaa,
      modid: named is String && RegExp(r'^[\w:]+$').hasMatch(named) ? named : modid,
    );
    return generated.copyWith(
      seccodeHash: seccode ? hash('seccode_hash') ?? generated.seccodeHash : '',
      secqaaHash: secqaa ? hash('secqaa_hash') ?? generated.secqaaHash : '',
    );
  }

  /// The checks of the web page form [scope] (a post form, the reply window, the quick reply form): the placeholders the
  /// forum's `seccheck` template prints (`span#seccode_<id>`, `span#secqaa_<id>`, filled by the page script
  /// `updateseccode('<id>', …, '<modid>')` / `updatesecqaa('<id>')`), or the fields as another theme may print them
  /// (`seccodehash`, `secqaahash`). Null when the form asks for nothing, or for a check whose id it does not tell.
  static SecCheck? fromElement(uh.Element? scope, {String modid = postModid}) {
    if (scope == null) {
      return null;
    }
    final scripts = scope.querySelectorAll('script').map((e) => e.text ?? '').join('\n');
    String? placeholder(String prefix) {
      final id = scope.querySelector('[id^="$prefix"]')?.id.substring(prefix.length);
      return id != null && _hashRe.hasMatch(id) ? id : null;
    }

    String? field(String name) {
      final value = scope.querySelector('input[name="$name"]')?.attributes['value'];
      return value != null && _hashRe.hasMatch(value) ? value : null;
    }

    final codeScript = _updateSecCodeRe.firstMatch(scripts);
    final seccodeHash = placeholder('seccode_') ?? codeScript?.group(1) ?? field('seccodehash');
    final secqaaHash = placeholder('secqaa_') ?? _updateSecQaaRe.firstMatch(scripts)?.group(1) ?? field('secqaahash');
    final asksCode = seccodeHash != null || scope.querySelector('[name="seccodeverify"]') != null;
    final asksQaa = secqaaHash != null || scope.querySelector('[name="secanswer"]') != null;
    if ((!asksCode && !asksQaa) || (asksCode && seccodeHash == null) || (asksQaa && secqaaHash == null)) {
      return null;
    }
    return SecCheck(
      seccode: asksCode,
      secqaa: asksQaa,
      seccodeHash: seccodeHash ?? '',
      secqaaHash: secqaaHash ?? '',
      modid: codeScript?.group(2) ?? field('seccodemodid') ?? modid,
    );
  }

  /// A captcha is asked.
  final bool seccode;

  /// A security question is asked.
  final bool secqaa;

  /// The id of the captcha (`seccodehash`), empty without [seccode].
  final String seccodeHash;

  /// The id of the question (`secqaahash`), empty without [secqaa].
  final String secqaaHash;

  /// The page the checks belong to (`seccodemodid`).
  final String modid;

  /// Whether anything is asked.
  bool get any => seccode || secqaa;

  /// Every check of this and of [other], with the ids of this one where both ask.
  SecCheck merge(SecCheck? other) {
    if (other == null) {
      return this;
    }
    return SecCheck(
      seccode: seccode || other.seccode,
      secqaa: secqaa || other.secqaa,
      seccodeHash: seccode ? seccodeHash : other.seccodeHash,
      secqaaHash: secqaa ? secqaaHash : other.secqaaHash,
      modid: seccode ? modid : other.modid,
    );
  }
}

/// The answers to the checks of a [SecCheck], as they are posted with the form.
@MappableClass()
final class SecCheckAnswer with SecCheckAnswerMappable {
  /// Constructor.
  const SecCheckAnswer({required this.check, this.seccode = '', this.secanswer = ''});

  /// The checks answered.
  final SecCheck check;

  /// What the captcha shows.
  final String seccode;

  /// The answer to the question.
  final String secanswer;

  /// Whether these answers cover every check [required] asks (the answers of a check of another id still count: the
  /// forum looks the answer up by the id posted with it).
  bool covers(SecCheck? required) =>
      required == null || ((!required.seccode || check.seccode) && (!required.secqaa || check.secqaa));

  /// The fields posted with the form: the forum checks `seccodeverify` against the captcha of `seccodehash` (and
  /// `seccodemodid`), `secanswer` against the question of `secqaahash`.
  Map<String, String> get fields => {
    if (check.seccode) ...{
      'seccodehash': check.seccodeHash,
      'seccodemodid': check.modid,
      'seccodeverify': seccode.trim(),
    },
    if (check.secqaa) ...{'secqaahash': check.secqaaHash, 'secanswer': secanswer.trim()},
  };
}

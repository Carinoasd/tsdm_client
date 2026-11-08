import 'package:collection/collection.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/utils/discuz_text.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// The first `schema` of a post form answer: plugin 2.9.0 answers the forms of a new thread, a reply (the page and the
/// reply window) and an edit as structured fields (`type: post`) when they are asked in the JSON mode
/// ([withTsdmAppJson]). Fields are only ever added: a later schema is read the same way.
const postFormSchema = 16;

/// The answer [data] of a post form page asked in the JSON mode, when the plugin answered it (plugin 2.9.0): the form
/// (`ok` 1, `type: post`, `schema` [postFormSchema] or later), or the forum's message shown instead of the form (`ok` 0,
/// `error: message`, with `login` and the `uid` it was served to: no permission, a password forum, a thread gone, the
/// login prompt…).
///
/// Null for anything else, which the caller reads as the web page as before: the page itself (a forum without the
/// plugin, or with an older one, leaves these pages alone), an `unknown` answer (the plugin could not tell the form),
/// a write result.
Map<String, dynamic>? postFormAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  if (json['ok'] == 1) {
    final schema = json['schema'];
    return json['type'] == 'post' && schema is num && schema >= postFormSchema ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && json['login'] is int) {
    return json;
  }
  return null;
}

/// One choice of a select control of a post form.
final class PostFormChoice {
  /// Constructor.
  const PostFormChoice({required this.value, required this.label});

  /// Value posted when chosen.
  final String value;

  /// Text shown for it.
  final String label;
}

/// One control of a post form answer (`{name, type, value, …}`): `types.input`, `stand`, `readperm`, `price.input`,
/// `tags.input`, `mygroup`, every item of `options` and of the `inputs` of a block (`poll`, `rushreply`…).
///
/// [value] is what the page printed, as the browser holds it: the value of a text, hidden or textarea control, the
/// value a checkbox posts when checked, the chosen value of a select (the last option marked selected, else the
/// first).
final class PostFormInput {
  /// Constructor.
  const PostFormInput({
    required this.name,
    required this.type,
    required this.value,
    this.checked = false,
    this.disabled = false,
    this.readonly = false,
    this.label = '',
    this.choices = const [],
  });

  /// The control described by [json], null when it names no field.
  static PostFormInput? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      return null;
    }
    final choices = json['choices'];
    return PostFormInput(
      name: name,
      type: tsdmAppText(json['type']),
      value: _text(json['value']),
      checked: _flag(json['checked']),
      disabled: _flag(json['disabled']),
      readonly: _flag(json['readonly']),
      label: tsdmAppText(json['label']),
      choices: choices is List
          ? [
              for (final choice in choices.whereType<Map<String, dynamic>>())
                if (_text(choice['value']) case final String value)
                  PostFormChoice(value: value, label: tsdmAppText(choice['label'])),
            ]
          : const [],
    );
  }

  /// Field name.
  final String name;

  /// `text`, `hidden`, `textarea`, `checkbox` or `select`.
  final String type;

  /// Value as served, see [PostFormInput].
  final String? value;

  /// A checkbox served checked.
  final bool checked;

  /// A checkbox served disabled: the browser never posts it.
  final bool disabled;

  /// A control the website does not let the member change (the options of a poll edited without the permission).
  final bool readonly;

  /// Label of a checkbox, empty when the page printed none.
  final String label;

  /// Choices of a select, in order.
  final List<PostFormChoice> choices;

  /// Whether this is a checkbox.
  bool get isCheckbox => type == 'checkbox';

  /// What the browser posts for this control as served: a checkbox only when checked and not disabled (with `on`
  /// when it has no value), any other control its value; nothing for a control without one (a select without
  /// choices).
  Iterable<(String, String)> get submitted sync* {
    if (isCheckbox) {
      if (checked && !disabled) {
        yield (name, value ?? 'on');
      }
    } else if (value case final String v) {
      yield (name, v);
    }
  }
}

/// The fields of a form submission, in order: names may repeat (a list field `name[]`).
final class PostFormBody {
  /// Constructor.
  PostFormBody([Iterable<(String, String)> pairs = const []]) : _pairs = [...pairs];

  final List<(String, String)> _pairs;

  /// Every field in order.
  List<(String, String)> get pairs => List.unmodifiable(_pairs);

  /// Append [name] with [value].
  void add(String name, String value) => _pairs.add((name, value));

  /// Append the fields [submitted] posts for a control ([PostFormInput.submitted]).
  void addAll(Iterable<(String, String)> submitted) => _pairs.addAll(submitted);

  /// Replace every value of [name] with [value], a change the member made; null leaves the field out (an unchecked
  /// checkbox).
  void set(String name, String? value) {
    _pairs.removeWhere((pair) => pair.$1 == name);
    if (value != null) {
      _pairs.add((name, value));
    }
  }

  /// Leave out every field whose name [test] accepts.
  void removeWhere(bool Function(String name) test) => _pairs.removeWhere((pair) => test(pair.$1));

  /// The last value of [name], null when it is not sent.
  String? valueOf(String name) {
    for (final (n, v) in _pairs.reversed) {
      if (n == name) {
        return v;
      }
    }
    return null;
  }

  /// The fields with one value per name, the form the app's transports post (a map: the Android client sends nothing
  /// else): the last value of a name sent twice, as the forum keeps it (PHP takes the last value of a plain name).
  ///
  /// Null when a list field (`name[]`) is sent more than once: the forum reads every value of it, which a map cannot
  /// carry, so such a form is left to the website.
  Map<String, String>? toMap() {
    final map = <String, String>{};
    final lists = <String>{};
    for (final (name, value) in _pairs) {
      if (name.endsWith('[]') && !lists.add(name)) {
        return null;
      }
      map[name] = value;
    }
    return map;
  }
}

/// The edits the member made to a post form: what the app posts instead of the served values.
final class PostFormEdits {
  /// Constructor.
  const PostFormEdits({
    required this.message,
    this.subject,
    this.typeId,
    this.perm,
    this.price,
    this.options = const {},
    this.save,
    this.attachNew = const [],
    this.rewardPrice,
    this.hongbao,
    this.activity,
    this.debate,
    this.poll,
    this.cronPublish,
  });

  /// The poll settings of the first post of a poll edited ([PostForm.pollEdit]), null to post them as served.
  final PollEdits? poll;

  /// When a new thread is published ([PostForm.offersCronPublish]), null for now: the forum keeps it a draft until then.
  final DateTime? cronPublish;

  /// The activity of a new activity thread or of the first post of one edited ([PostForm.activity]), null to post the
  /// served fields.
  final ActivityEdits? activity;

  /// The debate of a new debate thread or of the first post of one edited ([PostForm.debate]), null to post the served
  /// fields.
  final DebateEdits? debate;

  /// The reward price of a new reward thread, or the raised price of an open one edited by its author
  /// ([PostForm.reward], [RewardFormInfo.editable]), null to keep the served one.
  final int? rewardPrice;

  /// The red packet of a new red packet thread ([PostForm.hongbao]), null for none: the form then posts no `hb_*`
  /// field, and the plugin skips the packet.
  final HongbaoEdits? hongbao;

  /// The post as it is posted (BBCode, mentions in the forum's format).
  final String message;

  /// The attachments uploaded for this post while it was edited ([AttachmentUpload]), by `aid`: each is posted as
  /// `attachnew[aid][description]` so the forum binds it to the post, as the web page does for a new upload.
  final List<int> attachNew;

  /// The title, null to keep the served one.
  final String? subject;

  /// The chosen thread type, null to keep the served one; only posted when the form offers the type selector.
  final String? typeId;

  /// The chosen read permission, null to keep the served one.
  final String? perm;

  /// The chosen price, null to keep the served one.
  final int? price;

  /// The checkbox options the member left checked (true) or unchecked (false), by name; an option not named here
  /// keeps its served state. A disabled option is never posted, whatever is asked.
  final Map<String, bool> options;

  /// `1` to save a draft (only when the form offers it, [PostForm.canSaveDraft]); anything else publishes with the
  /// served value.
  final String? save;
}

/// The forum's file upload for a post form (`attach.upload` of the forum's app API, plugin 3.0.0 and later): the url
/// and the `uid` and `hash` the website's uploader posts (`swfconfig`), and what may go up.
///
/// The website posts the file as `Filedata` together with `uid` and `hash` to [url] with `type=image` added for an
/// image, and reads the plain text answer `DISCUZUPLOAD|uid|error|aid|isimage|path|filename|…`.
final class AttachmentUpload {
  /// Constructor.
  const AttachmentUpload({
    required this.url,
    required this.uid,
    required this.hash,
    required this.maxKb,
    required this.image,
    required this.imageExts,
  });

  /// The upload of a form's `attach.upload`, null when it names none or lacks what an upload needs (url, uid, hash).
  static AttachmentUpload? fromJson(Object? json) {
    final map = tsdmAppMap(json);
    final url = draftForumUri(tsdmAppText(map['url']));
    final uid = map['uid'];
    final hash = tsdmAppText(map['hash']);
    if (url == null || url.path != '/misc.php' || uid is! num || uid <= 0 || hash.isEmpty) {
      return null;
    }
    final maxKb = map['max_kb'];
    return AttachmentUpload(
      url: url,
      uid: uid.toInt(),
      hash: hash,
      maxKb: maxKb is num && maxKb > 0 ? maxKb.toInt() : null,
      image: map['image'] == 1,
      imageExts: tsdmAppText(map['image_exts'])
          .split(';')
          .map((e) => e.trim().replaceFirst(RegExp(r'^\*?\.'), '').toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList(),
    );
  }

  /// `misc.php?mod=swfupload&…&fid=N` on the forum host.
  final Uri url;

  /// The member uploading, posted as `uid`.
  final int uid;

  /// The upload hash of the member, posted as `hash`.
  final String hash;

  /// The largest file in KiB (`max_kb`), null when the forum names none.
  final int? maxKb;

  /// Whether images may go up (`image`: the member's group allows image attachments).
  final bool image;

  /// The image extensions the forum takes (`image_exts`: `*.jpg;*.jpeg;*.gif;*.png`), without dot, lower case.
  final List<String> imageExts;

  /// The url an image is posted to: [url] with `type=image`, as the website's image uploader does.
  ///
  /// With `simple=2` the forum answers `DISCUZUPLOAD|1|error|aid|…` (`parseAttachmentUploadAnswer`); without it only
  /// the bare aid (or the negated error).
  Uri get imageUrl => url.replace(queryParameters: {...url.queryParameters, 'type': 'image', 'simple': '2'});

  /// Whether the forum takes an image file named [filename], by its extension; any when the forum names none.
  bool acceptsImage(String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    return imageExts.isEmpty || imageExts.contains(ext);
  }

  /// The fields the upload posts beside the file.
  Map<String, String> get fields => {'uid': '$uid', 'hash': hash};
}

/// What the app's editors can do with a post form (plugin 2.9.0).
enum PostFormSupport {
  /// The editor takes it.
  supported,

  /// The forum asks for a captcha or a security question (`seccheck`): only the website shows them. Never posted.
  verification,

  /// Something the editor cannot preserve (see [PostForm.editorSupport]): continue on the website.
  unsupported,
}

/// A post form as the forum's app API answers it (plugin 2.9.0, `type: post`, `schema` [postFormSchema]): the form of
/// a new thread, a reply or an edit, as the forum built it for the page, with every value the browser would post when
/// the member pressed the button right away ([body]).
final class PostForm {
  PostForm._(this.json);

  /// The form of the answer [json] ([postFormAnswerOf]), null when it is not one (the forum's message).
  static PostForm? fromJson(Map<String, dynamic> json) {
    final schema = json['schema'];
    if (json['ok'] != 1 || json['type'] != 'post' || schema is! num || schema < postFormSchema) {
      return null;
    }
    return PostForm._(json);
  }

  /// The answer.
  final Map<String, dynamic> json;

  /// The account the form was served to (0 for a guest).
  int get uid => tsdmAppInt(json['uid']);

  /// `newthread`, `reply` or `edit`.
  String get action => tsdmAppText(json['action']);

  /// The form is for the first post of a thread (a new thread, the first post edited).
  bool get first => json['first'] == 1;

  /// Name of the forum, null when the answer names none.
  String? get forumName {
    final name = tsdmAppText(tsdmAppMap(json['forum'])['name']).trim();
    return name.isEmpty ? null : name;
  }

  /// Whether the forum marks the title as awaiting moderation (`(需审核)`: new threads or replies of this forum go to
  /// the moderators first); null when the page does not tell (the edit page).
  bool? get moderated => switch (json['moderated']) {
    final num v => v != 0,
    _ => null,
  };

  Map<String, dynamic> get _submit => tsdmAppMap(json['submit']);

  /// The hidden fields of the form and its submit button, as served (`submit.fields`): the form hash, the post time,
  /// the reply's encrypted `noticeauthor`… Each request gets its own: never kept nor made up.
  Map<String, String> get submitFields => {
    for (final MapEntry(:key, :value) in tsdmAppMap(_submit['fields']).entries)
      if (_text(value) case final String v) key: v,
  };

  /// The url the form posts to (`submit.url`), absolute; null unless it is a same-site `forum.php?mod=post` url of
  /// this form's [action] with its submit flag (`topicsubmit`, `replysubmit`, `editsubmit`). The answer of a write
  /// is asked by the transport ([withTsdmAppJsonWrite]); the reply window posts with `inajax=1` added, as the website
  /// does.
  String? get submitUrl {
    final uri = draftForumUri(tsdmAppText(_submit['url']));
    if (uri == null || uri.path != '/forum.php') {
      return null;
    }
    final query = uri.queryParameters;
    if (query['mod'] != 'post') {
      return null;
    }
    final matches = switch (action) {
      // A trade posts to `newtrade` (the template's action).
      'newthread' => (query['action'] == 'newthread' || query['action'] == 'newtrade') && query['topicsubmit'] == 'yes',
      'reply' => query['action'] == 'reply' && query['replysubmit'] == 'yes',
      'edit' => query['action'] == 'edit' && query['editsubmit'] == 'yes',
      _ => false,
    };
    return matches ? Uri.parse(baseUrl).replace(path: uri.path, query: uri.query).toString() : null;
  }

  Map<String, dynamic>? _block(String key) =>
      json[key] is Map<String, dynamic> ? json[key] as Map<String, dynamic> : null;

  List<PostFormInput> _inputs(Object? value) =>
      value is List ? value.map(PostFormInput.fromJson).whereType<PostFormInput>().toList() : const [];

  /// The title as served (the edited post's title, empty for a new one); null when the form has no title field.
  String? get subject => _block('subject') == null ? null : tsdmAppText(_block('subject')!['value']);

  /// The forum's own subject limit, counted with [discuzSubjectLength] (`subject.unit`: `dstrlen`); null when the
  /// forum does not check it here (the first post of a special thread or a thread sort, a reply to a trade, a group
  /// free of the post limits, no limit set), or counts it another way.
  int? get subjectMax => _limit(_block('subject'), 'max', 'dstrlen');

  /// The forum's minimum subject length when the member gives a title, as [subjectMax].
  int? get subjectMin => _limit(_block('subject'), 'min', 'dstrlen');

  /// The subject limit every submission is checked against, whatever the forum's settings, the thread type or the
  /// member's group (`subject.hard_max`: `checkpost()`'s 255, counted as [subjectMax]); [discuzSubjectServerLimit] when
  /// the answer names none.
  int get subjectHardMax => _limit(_block('subject'), 'hard_max', 'dstrlen') ?? discuzSubjectServerLimit;

  /// The subject limit of a submission: the forum's own ([subjectMax]) when it checks one, never above what every
  /// submission is checked against ([subjectHardMax]).
  int get subjectLimit {
    final max = subjectMax;
    final hard = subjectHardMax;
    return max != null && max < hard ? max : hard;
  }

  /// The post as served (BBCode; the edited post with its image attachments as `[attachimg]`, empty for a new post
  /// and for a reply that quotes: the quote is in `noticetrimstr`, which the forum puts in front of the message), null
  /// when the editor is not the BBCode one (`unsupported`).
  String? get message {
    final value = _block('message')?['value'];
    return value is String ? value : null;
  }

  /// The forum's minimum post size in UTF-8 bytes (without the quoted part: [messageMinExcludesQuote],
  /// [discuzMessageTooShort]); null when the forum does not check it here (a special thread, a group free of the post
  /// limits, no minimum set), or counts it another way.
  int? get messageMin => _limit(_block('message'), 'min', 'bytes');

  /// The forum's maximum post size in UTF-8 bytes ([discuzMessageBytes]), as [messageMin].
  int? get messageMax => _limit(_block('message'), 'max', 'bytes');

  /// Whether the forum counts [messageMin] without the quoted part (`message.min_excludes_quote`, as `checkpost()`
  /// does); assumed when the answer does not say.
  bool get messageMinExcludesQuote => _block('message')?['min_excludes_quote'] != 0;

  /// A limit [key] of the block [block] counted in [unit]: positive, and the block names that unit (or none: the
  /// first answers of plugin 2.9.0 counted that way without saying so).
  static int? _limit(Map<String, dynamic>? block, String key, String unit) {
    final value = block?[key];
    final named = block?['unit'];
    if (value is! num || value <= 0 || (named != null && named != unit)) {
      return null;
    }
    return value.toInt();
  }

  Map<String, dynamic>? get _types => _block('types');

  /// The thread type selector (`typeid`), null when the form has none: no types, or the post keeps a type only
  /// moderators may choose (`locked`: the form then posts no `typeid` at all).
  PostFormInput? get typeInput => typeLocked ? null : PostFormInput.fromJson(_types?['input']);

  /// Whether a new thread must choose a type.
  bool get typeRequired => _types?['required'] == 1;

  /// Whether the type of the post is one only moderators may choose: kept as it is, never posted.
  bool get typeLocked => _types?['locked'] == 1;

  /// The type of thread the form is for (`special.current`): 0 an ordinary thread, 1 a poll, 2 a trade, 3 a reward,
  /// 4 an activity, 5 a debate, 127 a thread plugin's.
  int get special => tsdmAppInt(tsdmAppMap(json['special'])['current']);

  /// The thread plugin the form is for (`special.specialextra`, `hongbao`…), empty for none.
  String get specialExtra => tsdmAppText(tsdmAppMap(json['special'])['specialextra']);

  /// The thread types the member may post in this forum, as the new thread page lists them (`special.allowed`: 0
  /// an ordinary thread, 1 a poll, 3 a reward…); empty when the form is not of a new thread, or the plugin is older.
  List<int> get specialAllowed => [
    for (final value in tsdmAppMap(json['special'])['allowed'] as List? ?? const [])
      if (value is num) value.toInt(),
  ];

  /// The thread plugins the member may post with in this forum (`special.threadplugins`): the identifier and the
  /// name of each; empty when the form is not of a new thread, or the plugin is older.
  List<(String, String)> get threadPlugins => [
    for (final plugin in tsdmAppList(tsdmAppMap(json['special'])['threadplugins']))
      if (tsdmAppText(plugin['id']) case final String id when id.isNotEmpty) (id, tsdmAppText(plugin['name'])),
  ];

  /// The reward settings of a new reward thread or of the edit of its first post (`reward`, [special] 3), null for any
  /// other form.
  RewardFormInfo? get reward => special == 3 && (action == 'newthread' || (action == 'edit' && first))
      ? RewardFormInfo.fromJson(json['reward'])
      : null;

  /// The activity settings of a new activity thread, or of the edit of its first post with the image of the activity
  /// read from the web page ([withActivityImage]) (`activity`, [special] 4); null for any other form.
  ActivityFormInfo? get activity => switch (action) {
    'newthread' when special == 4 => ActivityFormInfo.fromJson(json['activity']),
    'edit' when editsActivity && json.containsKey(activityImageKey) => ActivityFormInfo.fromJson(
      json['activity'],
      edit: true,
    ),
    _ => null,
  };

  /// Whether the form is the edit of the first post of an activity thread: the image of the activity is only on the
  /// web page of the form ([withActivityImage]).
  bool get editsActivity => action == 'edit' && first && special == 4;

  /// This form with the image of the activity as the web page of the form posts it (`activityaid`, the attachment of
  /// the activity; null when the page has no such field).
  ///
  /// The forum deletes the image of an activity whose edit posts another `activityaid`
  /// (`extend_thread_activity::before_editpost`), and the plugin serves the field empty; the editor posts the page's.
  PostForm withActivityImage(String? aid) => PostForm._({...json, activityImageKey: aid});

  /// The key of the `activityaid` read for [withActivityImage] in [json]: the app's, never one of the plugin's.
  static const activityImageKey = 'app_activity_aid';

  /// The debate settings of a new debate thread or of the edit of its first post (`debate`, [special] 5), null for
  /// any other form.
  DebateFormInfo? get debate => switch (action) {
    'newthread' when special == 5 => DebateFormInfo.fromJson(json['debate']),
    'edit' when first && special == 5 => DebateFormInfo.fromJson(json['debate'], edit: true),
    _ => null,
  };

  /// The red packet form of a new red packet thread ([special] 127 of the `hongbao` plugin), read from the web page
  /// and kept under the app's own key [hongbaoKey] ([withHongbao]); null when not read, or for any other form.
  HongbaoFormInfo? get hongbao => isHongbao ? HongbaoFormInfo.fromJson(json[hongbaoKey]) : null;

  /// Whether the form is for a new thread of the `hongbao` thread plugin (the forum stores it as [special] 127).
  bool get isHongbao => action == 'newthread' && specialExtra == ThreadKind.hongbaoPlugin;

  /// This form with the red packet form [info] read from its web page ([HongbaoFormInfo.parse]).
  PostForm withHongbao(HongbaoFormInfo info) => PostForm._({...json, hongbaoKey: info.toJson()});

  /// The key of [hongbao] in [json]: the app's, never one of the plugin's.
  static const hongbaoKey = 'app_hongbao';

  /// The checkbox options and the other controls of the form's options (`options`).
  List<PostFormInput> get options => _inputs(json['options']);

  /// The read permission selector, null when the member may not set one.
  PostFormInput? get readPerm => PostFormInput.fromJson(json['readperm']);

  /// The price field, null when the member may not sell the thread.
  PostFormInput? get priceInput => PostFormInput.fromJson(_block('price')?['input']);

  /// The highest price the member may ask, null without [priceInput].
  int? get priceMax {
    final max = _block('price')?['max'];
    return max is num ? max.toInt() : null;
  }

  /// The tags field, null when the member may not tag the thread.
  PostFormInput? get tagsInput => PostFormInput.fromJson(_block('tags')?['input']);

  /// The side selector of a reply to a debate, null otherwise.
  PostFormInput? get stand => PostFormInput.fromJson(json['stand']);

  /// The inputs of the block [key] (`poll`, `rushreply`…), empty without the block.
  List<PostFormInput> blockInputs(String key) => _inputs(_block(key)?['inputs']);

  /// Whether the member may save the post as a draft (`draft.can_save`).
  bool get canSaveDraft => _block('draft')?['can_save'] == 1;

  /// Whether the thread of the form is a draft (`thread.draft`).
  bool get isDraftThread => tsdmAppMap(json['thread'])['draft'] == 1;

  /// Whether the post is set to be published later (the `cronpublish` checkbox checked: a scheduled draft). The forum
  /// keeps such a post a draft whenever it is posted back with its date (`save` forced to 1), so a "publish" from the
  /// app would not publish it: the form is left to the website, as the web page parser leaves it.
  bool get schedulesPublication =>
      blockInputs('cronpublish').any((e) => e.name == 'cronpublish' && e.isCheckbox && e.checked);

  /// Whether the member may set when a new thread is published (`cronpublish` with its date, the group's
  /// `allowsetpublishdate`): the forum (newthread.php) keeps a thread whose time is ahead a draft (`save` forced to 1)
  /// and publishes it at that time (`cron_publish_halfhourly`, every half hour); a time already passed publishes it
  /// now. Not for a red packet thread: the plugin makes the packet with the thread, draft or not.
  bool get offersCronPublish {
    // `cronpublish` counted only as the checkbox it is on the website.
    final names = {
      for (final input in blockInputs('cronpublish'))
        if (input.name != 'cronpublish' || input.isCheckbox) input.name,
    };
    return action == 'newthread' && !isHongbao && names.containsAll(const ['cronpublish', 'cronpublishdate']);
  }

  /// The time [at] as the forum reads `cronpublishdate`: `strtotime()` in the member's time zone, the wall clock of
  /// the offset the answer gives ([tsdmAppTimeOffset], the forum's +8 when it names none).
  String cronPublishDate(DateTime at) =>
      discuzDateTime(tsdmAppWallClockTime(at.millisecondsSinceEpoch ~/ 1000, tsdmAppTimeOffset(json))!);

  /// Whether the form is the edit of the first post of a poll whose options it serves (`poll.options`, each with its
  /// `polloptionid[ID]`, `displayorder[ID]` and `polloption[ID]` fields; `pollimage[ID]` sent when served), posted
  /// back as served ([body]): the forum (`extend_thread_poll::before_editpost`) keeps every option by its id, its
  /// votes with it, and the settings as the page prints them, as the website's form does when the member changes none
  /// of them.
  ///
  /// False without options: the form of a member who may not edit the poll, or one the forum would read as no poll
  /// at all (`polls` with no option drops the poll from the thread).
  bool get editsPollAsServed {
    final poll = _block('poll');
    if (action != 'edit' || !first || special != 1 || poll == null || poll['option_field'] != 'polloption[ID]') {
      return false;
    }
    final ids = [
      for (final option in tsdmAppList(poll['options']))
        if (option['id'] case final num id when id > 0) id.toInt(),
    ];
    final names = blockInputs('poll').map((e) => e.name).toSet();
    return ids.isNotEmpty &&
        ids.every((id) => names.containsAll(['polloptionid[$id]', 'displayorder[$id]', 'polloption[$id]'])) &&
        names.contains('polls');
  }

  /// The poll settings of the edit of the first post of a poll whose options the form serves ([editsPollAsServed]),
  /// which the member may change; null for any other form.
  late final PollEditFormInfo? pollEdit = editsPollAsServed ? PollEditFormInfo.fromJson(_block('poll')) : null;

  /// The highest number of choices of a poll (`poll.max_options`, the site's `maxpolloptions`), null without a poll.
  int? get pollMaxOptions {
    final max = _block('poll')?['max_options'];
    return max is num ? max.toInt() : null;
  }

  /// Whether the forum asks this account for a captcha or a security question to post the form (`seccheck`); the plugin
  /// lists it in [unsupported] too. The app answers them itself when the form names their ids ([secCheck]).
  bool get asksVerification => json['seccheck'] is Map || unsupported.contains('seccheck');

  /// What the form asks for (`seccheck`), with the ids the answers go with; null when it asks nothing, or does not say
  /// what (an answer without the `seccheck` block).
  SecCheck? get secCheck => SecCheck.fromJson(json['seccheck']);

  /// Why the plugin says the app should leave the form to the website (`jsoneditor`, `threadplugin`, `threadsort`,
  /// `seccheck`, `editorhook`); empty when there is no reason.
  List<String> get unsupported {
    final value = json['unsupported'];
    return value is List ? value.whereType<String>().toList() : const [];
  }

  /// Field names other plugins printed into the form through its hooks (`hook_fields`): their values are not given
  /// and their meaning is unknown, some are required, so they are posted back as the web page serves them
  /// ([hookValues]); a form whose web page could not give them is left to the website.
  List<String> get hookFields => [
    for (final hook in tsdmAppList(json['hook_fields']))
      if (hook['names'] is List) ...(hook['names'] as List).whereType<String>(),
  ];

  /// The fields of [hookFields] as the browser posts them from the web page of this form when the member changes
  /// nothing ([hookValuesOf], [withHookValues]); null when they were not read. Kept in [json] under the app's own key
  /// [hookValuesKey], so the form rebuilt from its answer still carries them.
  List<(String, String)>? get hookValues => switch (json[hookValuesKey]) {
    final List<dynamic> pairs => [
      for (final pair in pairs)
        if (pair case [final String name, final String value]) (name, value),
    ],
    _ => null,
  };

  /// This form with [values] read for its [hookFields] from the web page ([hookValuesOf]).
  PostForm withHookValues(List<(String, String)> values) => PostForm._({
    ...json,
    hookValuesKey: [
      for (final (name, value) in values) [name, value],
    ],
  });

  /// The key of [hookValues] in [json]: the app's, never one of the plugin's.
  static const hookValuesKey = 'app_hook_values';

  /// The body the browser posts for this form as served, in the order of the plugin's rule (its README, «App 怎麼送出»):
  /// `submit.fields`, the title and the post, the type selector (none when `locked`), the debate side, the read
  /// permission, the price, the tags, the group selector, the options, the inputs of every block (`replycredit`,
  /// `rushreply`, `cronpublish`, `poll`, `trade`, `reward`, `activity`, `debate`) — a checkbox only when checked and
  /// not disabled — the fields of the attachments (`attach.fields`) and the fields other plugins printed, as the web
  /// page serves them ([hookValues]). Blocks the app does not edit go back as served: the rush settings, the reply
  /// rewards, the scheduled publication, the descriptions of the attachments and another plugin's values (the tags of
  /// a thread a forms plugin keeps, cleared when its fields are missing) would otherwise be changed or cleared.
  PostFormBody body() {
    final body = PostFormBody(submitFields.entries.map((e) => (e.key, e.value)));
    if (subject case final String subject) {
      body.add('subject', subject);
    }
    if (message case final String message) {
      body.add('message', message);
    }
    for (final input in [typeInput, readPerm, priceInput, tagsInput, stand, PostFormInput.fromJson(json['mygroup'])]) {
      if (input != null) {
        body.addAll(input.submitted);
      }
    }
    for (final input in options) {
      body.addAll(input.submitted);
    }
    for (final block in const [
      'replycredit',
      'rushreply',
      'cronpublish',
      'poll',
      'trade',
      'reward',
      'activity',
      'debate',
    ]) {
      for (final input in blockInputs(block)) {
        body.addAll(input.submitted);
      }
    }
    // The member data asked of an applicant, checkboxes the website posts as a list (`userfield[]`): by index, which
    // PHP reads as the same list (a map carries no name twice, PostFormBody.toMap).
    final userFields = [
      for (final (name, value) in body.pairs)
        if (name == 'userfield[]') value,
    ];
    if (userFields.isNotEmpty) {
      body.removeWhere((name) => name == 'userfield[]');
      for (final (i, value) in userFields.indexed) {
        body.add('userfield[$i]', value);
      }
    }
    if (editsActivity && json.containsKey(activityImageKey)) {
      body.set('activityaid', json[activityImageKey] is String ? json[activityImageKey] as String : null);
    }
    for (final MapEntry(:key, :value) in tsdmAppMap(_block('attach')?['fields']).entries) {
      if (_text(value) case final String v) {
        body.add(key, v);
      }
    }
    body.addAll(hookValues ?? const []);
    return body;
  }

  /// [body] with the member's [edits] put over the served values.
  PostFormBody bodyWith(PostFormEdits edits) {
    final body = this.body();
    if (subject != null && edits.subject != null) {
      body.set('subject', edits.subject);
    }
    body.set('message', edits.message);
    final types = typeInput;
    if (types != null && edits.typeId != null && types.choices.any((c) => c.value == edits.typeId)) {
      body.set(types.name, edits.typeId);
    }
    final perm = readPerm;
    if (perm != null && edits.perm != null) {
      body.set(perm.name, edits.perm);
    }
    final price = priceInput;
    if (price != null && edits.price != null) {
      body.set(price.name, '${edits.price}');
    }
    final reward = this.reward;
    if (reward != null && reward.editable && edits.rewardPrice != null) {
      body.set(reward.inputName, '${edits.rewardPrice}');
    }
    if ((activity, edits.activity) case (final info?, final set?)) {
      for (final MapEntry(:key, :value) in set.toFields(info).entries) {
        body.set(key, value);
      }
      // The list of the website's checkboxes, by index: a map carries no name twice (PostFormBody.toMap).
      body.removeWhere((name) => name.startsWith('userfield['));
      for (final (i, value) in set.userFieldValues(info).indexed) {
        body.add('userfield[$i]', value);
      }
    }
    if ((debate, edits.debate) case (final info?, final set?)) {
      for (final MapEntry(:key, :value) in set.toFields(info).entries) {
        body.set(key, value);
      }
    }
    // The plugin's fields are not in the served form: added as the website's form posts them. Never for a draft: the
    // plugin makes the packet (and charges it) as soon as the thread exists (`newthread_submit_end`), draft or not.
    if (isHongbao && hongbao != null && edits.hongbao != null && edits.save != '1') {
      for (final MapEntry(:key, :value) in edits.hongbao!.toFields().entries) {
        body.set(key, value);
      }
    }
    for (final option in options.where((e) => e.isCheckbox && !e.disabled)) {
      if (edits.options[option.name] case final bool checked) {
        body.set(option.name, checked ? option.value ?? 'on' : null);
      }
    }
    // The poll settings the member changed: the text of the options, the options added, the most choices, the days, the
    // two checkboxes (PollEdits.toFields).
    if ((pollEdit, edits.poll) case (final info?, final set?)) {
      for (final MapEntry(:key, :value) in set.toFields(info).entries) {
        body.set(key, value);
      }
    }
    // A poll that has ended or was closed prints its days left as words (`poll_finish`, `poll_close`), which the forum
    // stores as no expiry at all (`intval()` 0: the poll reopened for good, as the website's form does); a day before
    // today keeps it ended (`TIMESTAMP + 86400 * -1`), its votes and options as they are. Not its exact state: a poll
    // closed with its thread no longer reopens with it, which the website's form does not keep either. The days are
    // rounded: a poll with less than half a day left prints `0`, the same as one without expiry, and is stored without
    // one as the website's form does; the form does not tell them apart. Days the member typed are posted as typed.
    if (editsPollAsServed) {
      final expiration = body.valueOf('expiration');
      if (expiration != null && expiration.trim().isNotEmpty && int.tryParse(expiration.trim()) == null) {
        body.set('expiration', '-1');
      }
    }
    // A new thread published later: posted with its time, the forum keeps it a draft until then.
    if (edits.cronPublish case final at? when offersCronPublish) {
      final checkbox = blockInputs('cronpublish').firstWhere((e) => e.name == 'cronpublish');
      body
        ..set('cronpublish', checkbox.value ?? 'true')
        ..set('cronpublishdate', cronPublishDate(at));
    }
    // The website's 保存草稿 button sets `save` to 1; publishing posts the served value.
    if (edits.save == '1' && canSaveDraft) {
      body.set('save', '1');
    }
    for (final aid in edits.attachNew) {
      body.set('attachnew[$aid][description]', '');
    }
    return body;
  }

  /// The upload the forum offers for this form (`attach.upload`), null when the member may not upload here (no
  /// permission, the day's quota used up, a plugin replacing the upload) or the answer is of a plugin before it.
  AttachmentUpload? get attachmentUpload => AttachmentUpload.fromJson(_block('attach')?['upload']);

  /// The images the member uploaded and the forum keeps unused (`attach.unused`, by aid): bound to the post when it is
  /// published with them, deleted by the forum a day after the upload otherwise.
  Set<int> get unusedAttachmentImages => _attachAids('unused', imagesOnly: true);

  /// The attachments of the edited post (`attach.used`, by aid), empty for a new thread or a reply.
  Set<int> get usedAttachments => _attachAids('used', imagesOnly: false);

  Set<int> _attachAids(String key, {required bool imagesOnly}) {
    final list = _block('attach')?[key];
    return {
      for (final e in list is List ? list : const [])
        if (e is Map && e['aid'] is num && (e['aid'] as num) > 0 && (!imagesOnly || '${e['isimage']}' == '1'))
          (e['aid'] as num).toInt(),
    };
  }

  /// What the app's editor of [expectedAction] (`newthread` for a new ordinary thread, `edit`, `reply`) can do with
  /// this form: [PostFormSupport.verification] when the forum asks for a captcha or a security question without telling
  /// what ([secCheck] null; with it the editor asks the user, `seccheck` is no reason to leave the form then);
  /// [PostFormSupport.unsupported] for a form the plugin says to leave to the website ([unsupported]: another editor,
  /// a thread plugin's or a thread sort's fields, a replaced editor), one with other plugins' fields ([hookFields])
  /// the web page did not give ([hookValues] null), a scheduled draft ([schedulesPublication]), one posted elsewhere than a same-site post url ([submitUrl]), one
  /// whose body a map cannot carry ([PostFormBody.toMap]), and the thread types the editor does not show: a new thread of a special type (a forum
  /// allowing special threads only), the first post of a special thread (but a reward, a poll, an activity with its
  /// image read or a debate), a post of a trade thread (its goods), as
  /// the web page parser decides.
  PostFormSupport editorSupport(String expectedAction) {
    final check = secCheck;
    if (asksVerification && check == null) {
      return PostFormSupport.verification;
    }
    // A new thread: an ordinary one, a reward, an activity or a debate with its settings, or a red packet thread with
    // its form read. The first
    // post of a reward thread: its price as the form lets the member set it, else posted back as served; of a poll:
    // its options and settings posted back as served.
    final ordinary = switch (expectedAction) {
      'newthread' =>
        special == 0 || reward != null || activity != null || debate != null || (isHongbao && hongbao != null),
      'edit' =>
        first
            ? special == 0 || reward != null || editsPollAsServed || activity != null || debate != null
            : special != 2,
      'reply' => true,
      _ => false,
    };
    // The forum prints a thread plugin's fields only on a new thread and on the edit of its first post (newthread.php,
    // editpost.php `$isfirstpost && $specialextra`): a reply to such a thread or the edit of another of its posts has
    // none, though plugins before 3.2.0 list `threadplugin` for them too (#239). The red packet plugin's fields the
    // app knows ([hongbao]).
    final threadPluginFields =
        (expectedAction == 'newthread' || (expectedAction == 'edit' && first)) && !(isHongbao && hongbao != null);
    if (!ordinary ||
        action != expectedAction ||
        unsupported.any(
          (e) => switch (e) {
            'seccheck' => check == null,
            'threadplugin' => threadPluginFields,
            _ => true,
          },
        ) ||
        (hookFields.isNotEmpty && hookValues == null) ||
        schedulesPublication ||
        message == null ||
        submitUrl == null ||
        body().toMap() == null) {
      return PostFormSupport.unsupported;
    }
    return PostFormSupport.supported;
  }
}

/// The fields named [names] (a post form's [PostForm.hookFields]: other plugins' fields the app's API does not give
/// the values of) as the browser posts them from [document], the web page of the same form, when the member presses
/// the button right away: the controls of `form#postform` (those inside it not given to another form by a `form`
/// attribute, and those outside it given to it) in page order; a disabled one never, nor one inside a disabled
/// fieldset; a checkbox or a radio button only when checked (`on` without a value); a select's last selected option,
/// nothing when that option is disabled, else its first option not disabled — a list box (`multiple`, or a size above
/// one) only its selected options not disabled; a textarea's text with its line breaks as CRLF; buttons and files are
/// not posted.
///
/// Null when a name is no control of that form (a field a script builds, or one outside the form): the app cannot
/// post the form as the website would.
List<(String, String)>? hookValuesOf(uh.Document document, List<String> names) {
  final form = document.querySelector('form#postform');
  if (form == null) {
    return null;
  }
  final wanted = names.toSet();
  bool ofForm(uh.Element e) {
    final owner = e.attributes['form'];
    return owner == null ? form.contains(e) : owner == 'postform';
  }

  final controls = document
      .querySelectorAll('input[name], select[name], textarea[name]')
      .where((e) => wanted.contains(e.attributes['name']) && ofForm(e))
      .toList();
  if (!wanted.every((name) => controls.any((e) => e.attributes['name'] == name))) {
    return null;
  }
  bool disabled(uh.Element e) {
    if (e.attributes.containsKey('disabled')) {
      return true;
    }
    for (var p = e.parent; p != null; p = p.parent) {
      if (p.localName == 'fieldset' && p.attributes.containsKey('disabled')) {
        return true;
      }
    }
    return false;
  }

  final values = <(String, String)>[];
  for (final control in controls) {
    final name = control.attributes['name']!;
    if (disabled(control)) {
      continue;
    }
    switch (control.localName) {
      case 'input':
        final type = (control.attributes['type'] ?? 'text').toLowerCase();
        if (const ['submit', 'button', 'image', 'reset', 'file'].contains(type)) {
          continue;
        }
        if (type == 'checkbox' || type == 'radio') {
          if (control.attributes.containsKey('checked')) {
            values.add((name, control.attributes['value'] ?? 'on'));
          }
        } else {
          values.add((name, control.attributes['value'] ?? ''));
        }
      case 'select':
        final options = control.querySelectorAll('option');
        bool off(uh.Element o) => o.attributes.containsKey('disabled');
        bool selected(uh.Element o) => o.attributes.containsKey('selected');
        String valueOf(uh.Element o) => o.attributes['value'] ?? (o.text ?? '').trim();
        final listBox =
            control.attributes.containsKey('multiple') || (int.tryParse(control.attributes['size'] ?? '') ?? 0) > 1;
        if (listBox) {
          values.addAll(options.where((o) => selected(o) && !off(o)).map((o) => (name, valueOf(o))));
        } else if (options.lastWhereOrNull(selected) case final chosen?) {
          if (!off(chosen)) {
            values.add((name, valueOf(chosen)));
          }
        } else if (options.firstWhereOrNull((o) => !off(o)) case final first?) {
          values.add((name, valueOf(first)));
        }
      case 'textarea':
        values.add((name, (control.text ?? '').replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')));
    }
  }
  return values;
}

String? _text(Object? value) => switch (value) {
  final String s => s,
  final num n => '$n',
  _ => null,
};

bool _flag(Object? value) => value == 1 || value == true;

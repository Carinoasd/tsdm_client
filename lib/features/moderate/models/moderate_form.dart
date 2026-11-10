import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// A thread management operation the app offers a moderator, one thread at a time.
///
/// Most are an operation of the forum's `forum.php?mod=topicadmin&action=moderate` (`operations[]`), opened in the
/// window group ([group], `optgroup`) the website opens it in from the thread page; the others ([group] 0) are an
/// action of their own (`forum.php?mod=topicadmin&action=stamp`…, [action]) on one thread, with a window
/// `form#topicadminform`.
enum ModerateOperation {
  /// Stick or unstick (`stick`, `sticklevel` 0 to 3 as the account's group allows, `expirationstick`).
  stick(1),

  /// Digest or undigest (`digest`, `digestlevel` 0 to 3, `expirationdigest`).
  digest(1),

  /// Highlight the title or take it off (`highlight`, `highlight_color` 0 to 8, `highlight_style[1..3]` bold, italic,
  /// underline, `highlight_bgcolor`, `expirationhighlight`): no color and no style is no highlight.
  highlight(1),

  /// Recommend the thread in its forum or take it off (`recommend`, `isrecommend` 1 or 0, `expirationrecommend`, the
  /// title shown `reducetitle`); the window holds it only where the forum turned recommendation on.
  recommend(1),

  /// Set the thread's stamp or take it off (`action=stamp`, `stamp` one of the window's, empty for none).
  stamp(0),

  /// Set the icon beside the thread's title in the forum or take it off (`action=stamplist`, `stamplist` one of the
  /// window's, empty for none).
  stamplist(0),

  /// Close the thread (`close`).
  close(4),

  /// Open the thread again (`open`).
  open(4),

  /// Move the thread to another forum (`move`, `moveto`, `type` normal or redirect).
  move(2),

  /// Put the thread in another category of its forum, or in none (`type`, `typeid`, 0 for none); the window holds it
  /// only where the forum has categories.
  type(2),

  /// Copy the thread's first post as a new thread of a forum (`action=copy`, `copyto`, the category `threadtypeid`).
  copy(0),

  /// Count the thread's replies, last post and first post again (`action=repair`): done as soon as asked, the forum
  /// has no window of it.
  repair(0),

  /// Delete the thread (`delete`): to the forum's recycle bin when the forum keeps one, gone otherwise.
  delete(3),

  /// Bump the thread: its last reply time set to now (`bump`, `expirationbump`).
  bump(3),

  /// Sink the thread: its last reply time set two years back (`down`, `expirationdown`).
  down(3)
  ;

  const ModerateOperation(this.group);

  /// The `optgroup` of the window the operation is in; 0 for an action of its own.
  final int group;

  /// The `action` of `forum.php?mod=topicadmin` the operation is: `moderate`, or its own.
  String get action => group == 0 ? name : 'moderate';

  /// The `operations[]` value the forum knows the operation by.
  String get value => name;

  /// The `operation` parameter asking the window of the operation when its group holds others; null when the group is
  /// asked as it is.
  ///
  /// Group 3 is bump and down unless asked for `delete`. Group 1 asked for `recommend` holds the recommendation alone,
  /// with the title and the image of one thread; asked for `highlight` it checks the highlight, as the thread page
  /// asks it. Group 2 asked for `type` holds the category alone.
  String? get windowOperation => switch (this) {
    ModerateOperation.delete ||
    ModerateOperation.highlight ||
    ModerateOperation.recommend ||
    ModerateOperation.type => name,
    _ => null,
  };
}

/// The text colors of a highlight by `highlight_color` (the forum's `forum_colorarray`, 0 the default color).
const List<int> moderateHighlightColors = [
  0xFF000000,
  0xFFEE1B2E,
  0xFFEE5023,
  0xFF996600,
  0xFF3C9D40,
  0xFF2897C5,
  0xFF2B65B7,
  0xFF8F2A90,
  0xFFEC1282,
];

/// How a thread's title is highlighted: the text color, the styles and the background color.
@immutable
final class ModerateHighlight {
  /// Constructor.
  const ModerateHighlight({
    this.color = 0,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.background = '',
  });

  /// The text color, an index of [moderateHighlightColors]; 0 the default color.
  final int color;

  /// Bold (`highlight_style[1]`).
  final bool bold;

  /// Italic (`highlight_style[2]`).
  final bool italic;

  /// Underlined (`highlight_style[3]`).
  final bool underline;

  /// The background color (`highlight_bgcolor`, `#RRGGBB` as the app sets it, any color the forum kept otherwise),
  /// empty for none.
  final String background;

  /// The forum counts the title highlighted: a color or a style. The background alone is kept but logged as no
  /// highlight, its end day dropped.
  bool get marksTitle => color != 0 || bold || italic || underline;

  /// Copy with some values changed.
  ModerateHighlight copyWith({int? color, bool? bold, bool? italic, bool? underline, String? background}) =>
      ModerateHighlight(
        color: color ?? this.color,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        underline: underline ?? this.underline,
        background: background ?? this.background,
      );

  @override
  bool operator ==(Object other) =>
      other is ModerateHighlight &&
      other.color == color &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.background == background;

  @override
  int get hashCode => Object.hash(color, bold, italic, underline, background);

  @override
  String toString() =>
      'ModerateHighlight($color${bold ? ', bold' : ''}${italic ? ', italic' : ''}${underline ? ', underline' : ''}'
      '${background.isEmpty ? '' : ', $background'})';
}

/// One choice of a select of the window: a level, a forum to move to, a stamp, an icon or a category.
@immutable
final class ModerateChoice {
  /// Constructor.
  const ModerateChoice({
    required this.value,
    required this.label,
    this.selected = false,
    this.depth = 0,
    this.group,
    this.image,
  });

  /// The value sent.
  final String value;

  /// The text the forum printed for it.
  final String label;

  /// The forum served it selected (the thread's current level, the thread's own forum).
  final bool selected;

  /// A forum's depth below its category (a sub forum is printed after `&nbsp;`).
  final int depth;

  /// The category (`<optgroup label>`) a forum is listed under, without the forum's leading dashes; null outside one.
  final String? group;

  /// The url of a stamp's or an icon's picture, as the window shows it; null when it has none.
  final String? image;

  @override
  bool operator ==(Object other) =>
      other is ModerateChoice &&
      other.value == value &&
      other.label == label &&
      other.selected == selected &&
      other.depth == depth &&
      other.group == group &&
      other.image == image;

  @override
  int get hashCode => Object.hash(value, label, selected, depth, group, image);

  @override
  String toString() => 'ModerateChoice($value, $label${selected ? ', selected' : ''})';
}

/// The hidden fields of the management window the app sends back as they were served; any other hidden field is
/// never sent as served (the highlight of group 1 is sent as chosen, [ModerateRequest.highlight]; the recommendation's
/// place as [ModerateForm.recommendFields]; the `operations[]` a window fixes as [ModerateRequest.operation]).
const moderateServedFields = {'frommodcp', 'formhash', 'fid', 'redirect', 'handlekey', 'moderate[]'};

/// The hidden fields of the window of an action of its own (`form#topicadminform`: stamp, icon, copy) the app sends
/// back as they were served.
const moderateActionServedFields = {'formhash', 'fid', 'tid', 'handlekey'};

/// The management window of the forum (`form#moderateform`) for one thread, as served to the account that asked.
///
/// Read from the window `forum.php?mod=topicadmin&action=moderate&optgroup=N` ([ModerateForm.parse]); the forum's
/// app API has no structured form for it (plugin 3.x `forms` lists rate, report, buy, usergroup and profile only).
/// An operation of [ModerateOperation.group] 0 has a window `form#topicadminform` of its own action instead, but
/// [ModerateOperation.repair], which has none ([ModerateForm.repair]).
final class ModerateForm {
  /// Constructor.
  const ModerateForm({
    required this.operation,
    required this.tid,
    required this.fid,
    required this.fields,
    this.uid = 0,
    this.levels = const [],
    this.forums = const [],
    this.canRedirect = false,
    this.reasons = const [],
    this.canNotify = false,
    this.notifyForced = false,
    this.expiration,
    this.highlight,
    this.recommendTitle,
    this.recommendFields = const {},
    this.choices = const [],
  });

  /// The repair of thread [tid] in forum [fid] by account [uid]: the forum has no window of it (asking one repairs
  /// the thread), nothing is served, nothing but the request is sent.
  const ModerateForm.repair({required this.tid, required this.fid, required this.uid})
    : operation = ModerateOperation.repair,
      fields = const {},
      levels = const [],
      forums = const [],
      canRedirect = false,
      reasons = const [],
      canNotify = false,
      notifyForced = false,
      expiration = null,
      highlight = null,
      recommendTitle = null,
      recommendFields = const {},
      choices = const [];

  /// The operation the window is for: the one asked, but close and open as the window checks it (the one that
  /// changes the thread as the forum sees it now).
  final ModerateOperation operation;

  /// The thread.
  final String tid;

  /// The forum the thread is in, as the window names it.
  final int fid;

  /// The hidden fields served ([moderateServedFields]): the form hash, the forum, the thread, the handle key.
  final Map<String, String> fields;

  /// The account the window was served to (the forum's app API tells it); 0 when the answer does not tell.
  final int uid;

  /// The stick or digest levels the account may set, as the forum listed them (0 first: none), the thread's current
  /// level selected. Empty for the other operations.
  final List<ModerateChoice> levels;

  /// The forums the thread may be moved to, in the forum's order, without the forum it is in; the forums it may be
  /// copied to, the forum it is in among them. Empty for the other operations.
  final List<ModerateChoice> forums;

  /// The move window offers to leave a redirect behind (`type` redirect).
  final bool canRedirect;

  /// The reasons the site set for management (`ul#reasonselect`), separators left out.
  final List<String> reasons;

  /// The window offers to notify the author (`sendreasonpm`).
  final bool canNotify;

  /// The forum notifies the author whatever is sent (the checkbox served checked and disabled).
  final bool notifyForced;

  /// The day the stick, digest, highlight or recommendation of the thread ends, as the window shows it; null when it
  /// does not end, or ends today or before (the forum takes a day after today only).
  final DateTime? expiration;

  /// The highlight of the thread now (the window of one thread), none for several threads; null for the other
  /// operations.
  final ModerateHighlight? highlight;

  /// The title the recommendation shows (`reducetitle`: the thread's, or the one recommended before); null when the
  /// window does not offer it (several threads, a window not asked for the recommendation).
  final String? recommendTitle;

  /// The fields of the recommendation sent as served: the place (`position`) and the image chosen
  /// (`selectattach`, the one recommended before or the thread's first image), which the forum would otherwise
  /// clear. Empty for the other operations.
  final Map<String, String> recommendFields;

  /// The stamps, the icons or the categories the window offers, none among them (an empty value for a stamp or an
  /// icon, `0` for a category), in the forum's order, the thread's own selected. Empty for the other operations.
  final List<ModerateChoice> choices;

  /// The stamp, icon or category the thread has now (the selected one); null when none is selected.
  ModerateChoice? get currentChoice => choices.firstWhereOrNull((e) => e.selected);

  /// The level the thread is at now (the selected one); null when none is selected: a level the account may not set,
  /// such as a global stick seen by a forum moderator, is not listed, and no level is chosen for the moderator.
  ModerateChoice? get currentLevel => levels.firstWhereOrNull((e) => e.selected);

  /// The url the window is posted to: the forum's own target of [operation]'s group, as an AJAX request; the target
  /// of the window of an action of its own; the url the repair is asked at.
  String get submitUrl => switch (operation) {
    ModerateOperation.repair => _actionUrl(operation, tid: tid, fid: fid),
    _ when operation.group == 0 =>
      '$baseUrl/forum.php?mod=topicadmin&action=${operation.action}&modsubmit=yes&infloat=yes&modclick=yes&inajax=1',
    _ =>
      '$baseUrl/forum.php?mod=topicadmin&action=moderate&optgroup=${operation.group}&modsubmit=yes&infloat=yes'
          '&inajax=1',
  };

  /// The url the window of [operation] for thread [tid] in forum [fid] is asked at, as the website asks it from the
  /// thread page (`modthreads`, or `modaction` for an action of its own).
  ///
  /// Never asked for [ModerateOperation.repair]: the forum repairs the thread there.
  static String windowUrl(ModerateOperation operation, {required String tid, required int fid}) => operation.group == 0
      ? _actionUrl(operation, tid: tid, fid: fid)
      : batchWindowUrl(operation, tids: [tid], fid: fid);

  static String _actionUrl(ModerateOperation operation, {required String tid, required int fid}) =>
      '$baseUrl/forum.php?mod=topicadmin&action=${operation.action}&fid=$fid&tid=$tid&handlekey=mods&infloat=yes'
      '&nopost=yes&inajax=1';

  /// The url the window of [operation] for threads [tids] of forum [fid] is asked at, as the website asks it from the
  /// forum page (`modthreads` with the threads checked). Only an operation of `action=moderate`: the others act on
  /// one thread.
  static String batchWindowUrl(ModerateOperation operation, {required List<String> tids, required int fid}) {
    assert(operation.group != 0, 'not an operation of several threads');
    return '$baseUrl/forum.php?mod=topicadmin&action=moderate&fid=$fid${tids.map((e) => '&moderate%5B%5D=$e').join()}'
        '&handlekey=mods&infloat=yes&nopost=yes&optgroup=${operation.group}'
        '${operation.windowOperation == null ? '' : '&operation=${operation.windowOperation}'}&inajax=1';
  }

  /// The window of operation [asked] for thread [tid] in forum [fid] read from [doc], served to [uid]; null when [doc] has no
  /// such window: no `form#moderateform` posting to the topicadmin target of the operation's group, a form hash
  /// missing, another thread or another forum, or none of what the operation needs (the levels of a stick or digest,
  /// the open and close choices, a forum to move to, the categories, the delete operation). The window of an action
  /// of its own is a `form#topicadminform` ([_parseAction]); a repair has none.
  static ModerateForm? parse(
    uh.Document doc,
    ModerateOperation asked, {
    required String tid,
    required int fid,
    int uid = 0,
  }) {
    if (asked == ModerateOperation.repair) {
      return null;
    }
    if (asked.group == 0) {
      return _parseAction(doc, asked, tid: tid, fid: fid, uid: uid);
    }
    final form = doc.querySelector('form#moderateform');
    if (form == null) {
      return null;
    }
    final served = form
        .querySelectorAll('input[type="hidden"][name="moderate[]"]')
        .map((e) => e.attributes['value'] ?? '')
        .toList();
    // Two threads: not the window of one thread.
    if (served.length != 1 || served.single != tid) {
      return null;
    }
    return _parse(form, asked, tid: tid, fid: fid, uid: uid, keepThread: true);
  }

  /// The window of [operation] read from [form], the threads it holds left out of [fields] when not [keepThread].
  static ModerateForm? _parse(
    uh.Element form,
    ModerateOperation asked, {
    required String tid,
    required int fid,
    required int uid,
    required bool keepThread,
    bool followChecked = true,
  }) {
    var operation = asked;
    if (!_isTarget(form.attributes['action'] ?? '', operation.group)) {
      return null;
    }
    final fields = <String, String>{};
    for (final input in form.querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? '';
      if (name == 'moderate[]' && !keepThread) {
        continue;
      }
      if (moderateServedFields.contains(name)) {
        if (fields.containsKey(name)) {
          // A field served twice: not a window the app knows.
          return null;
        }
        fields[name] = input.attributes['value'] ?? '';
      }
    }
    if ((fields['formhash'] ?? '').isEmpty || (keepThread && fields['moderate[]'] != tid) || fields['fid'] != '$fid') {
      return null;
    }

    var levels = const <ModerateChoice>[];
    var forums = const <ModerateChoice>[];
    var canRedirect = false;
    ModerateHighlight? highlight;
    String? recommendTitle;
    var recommendFields = const <String, String>{};
    var choices = const <ModerateChoice>[];
    switch (operation) {
      case ModerateOperation.stick || ModerateOperation.digest:
        final name = operation == ModerateOperation.stick ? 'sticklevel' : 'digestlevel';
        levels = form
            .querySelectorAll('select[name="$name"] option')
            .map(
              (e) => ModerateChoice(
                value: e.attributes['value'] ?? '',
                label: e.text?.trim() ?? '',
                selected: e.attributes.containsKey('selected'),
              ),
            )
            .where((e) => int.tryParse(e.value) != null)
            .toList();
        if (levels.isEmpty) {
          return null;
        }
      case ModerateOperation.highlight:
        String? value(String name) => form.querySelector('input[name="$name"]')?.attributes['value']?.trim();
        final color = value('highlight_color');
        if (!_offers(form, operation) || color == null) {
          return null;
        }
        // The window of several threads serves them empty: none.
        final index = int.tryParse(color) ?? 0;
        final background = value('highlight_bgcolor') ?? '';
        highlight = ModerateHighlight(
          color: index >= 0 && index < moderateHighlightColors.length ? index : 0,
          bold: value('highlight_style[1]') == '1',
          italic: value('highlight_style[2]') == '1',
          underline: value('highlight_style[3]') == '1',
          // Kept as served (the forum keeps letters, digits and `#` of any color it is given), sent back unchanged.
          background: background.replaceAll(RegExp('[^A-Za-z0-9#]'), ''),
        );
      case ModerateOperation.recommend:
        final choices = form
            .querySelectorAll('input[type="radio"][name="isrecommend"]')
            .map((e) => e.attributes['value'])
            .toSet();
        if (!_offers(form, operation) || !choices.containsAll(['1', '0'])) {
          return null;
        }
        recommendTitle = form.querySelector('input[name="reducetitle"]')?.attributes['value'];
        final position = form.querySelector('input[name="position"]')?.attributes['value'];
        final image = form.querySelector('select[name="selectattach"]');
        recommendFields = {
          'position': ?position,
          if (image != null)
            'selectattach':
                image.querySelector('option[selected]')?.attributes['value'] ??
                image.querySelector('option')?.attributes['value'] ??
                '',
        };
      case ModerateOperation.close || ModerateOperation.open:
        final radios = form.querySelectorAll('input[type="radio"][name="operations[]"]');
        final choices = radios.map((e) => e.attributes['value']).toSet();
        if (!choices.contains(ModerateOperation.close.value) || !choices.contains(ModerateOperation.open.value)) {
          return null;
        }
        // The forum checks the one that changes the thread as it is now (open for a closed thread): that one is done,
        // whatever the lock beside the title said when the operation was picked.
        final checked = radios.where((e) => e.attributes.containsKey('checked')).map((e) => e.attributes['value']);
        if (followChecked && checked.length == 1) {
          operation = checked.single == ModerateOperation.open.value ? ModerateOperation.open : ModerateOperation.close;
        }
      case ModerateOperation.move:
        forums = _forums(form.querySelector('select[name="moveto"]'), fid);
        if (forums.isEmpty) {
          return null;
        }
        canRedirect = form.querySelector('input[type="radio"][name="type"][value="redirect"]') != null;
      case ModerateOperation.type:
        // A forum without categories serves the window without the operation, its words in place of the select.
        choices = _choices(form.querySelector('select[name="typeid"]'));
        if (!_offers(form, operation) || choices.isEmpty) {
          return null;
        }
      case ModerateOperation.stamp || ModerateOperation.stamplist || ModerateOperation.copy || ModerateOperation.repair:
        return null;
      case ModerateOperation.delete:
        if (form.querySelector('input[name="operations[]"][value="delete"]') == null) {
          return null;
        }
      case ModerateOperation.bump || ModerateOperation.down:
        final choices = form
            .querySelectorAll('input[type="radio"][name="operations[]"]')
            .map((e) => e.attributes['value'])
            .toSet();
        if (!choices.contains(ModerateOperation.bump.value) || !choices.contains(ModerateOperation.down.value)) {
          return null;
        }
    }

    final notify = form.querySelector('input[name="sendreasonpm"]');
    return ModerateForm(
      operation: operation,
      tid: tid,
      fid: fid,
      fields: fields,
      uid: uid,
      levels: levels,
      forums: forums,
      canRedirect: canRedirect,
      reasons: _reasons(form),
      canNotify: notify != null,
      notifyForced: _notifyForced(notify),
      expiration: _expiration(form, operation),
      highlight: highlight,
      recommendTitle: recommendTitle,
      recommendFields: recommendFields,
      choices: choices,
    );
  }

  /// The window of [asked], an action of its own, for thread [tid] in forum [fid] read from [doc], served to [uid];
  /// null when [doc] has no such window: no `form#topicadminform` posting to the action, a form hash missing, another
  /// thread or forum, or none of the choices the action needs (the stamps, the icons, a forum to copy to).
  static ModerateForm? _parseAction(
    uh.Document doc,
    ModerateOperation asked, {
    required String tid,
    required int fid,
    required int uid,
  }) {
    final form = doc.querySelector('form#topicadminform');
    if (form == null || !_isActionTarget(form.attributes['action'] ?? '', asked)) {
      return null;
    }
    final fields = <String, String>{};
    for (final input in form.querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? '';
      if (moderateActionServedFields.contains(name)) {
        if (fields.containsKey(name)) {
          return null;
        }
        fields[name] = input.attributes['value'] ?? '';
      }
    }
    if ((fields['formhash'] ?? '').isEmpty || fields['tid'] != tid || fields['fid'] != '$fid') {
      return null;
    }

    var choices = const <ModerateChoice>[];
    var forums = const <ModerateChoice>[];
    switch (asked) {
      case ModerateOperation.stamp || ModerateOperation.stamplist:
        choices = _choices(form.querySelector('select[name="${asked.name}"]'), images: _stampImages(doc));
        // The window always offers none (an empty value).
        if (!choices.any((e) => e.value.isEmpty)) {
          return null;
        }
      case ModerateOperation.copy:
        // Copying to the forum the thread is in is a copy as any other.
        forums = _forums(form.querySelector('select[name="copyto"]'), 0);
        if (forums.isEmpty) {
          return null;
        }
      case ModerateOperation.stick ||
          ModerateOperation.digest ||
          ModerateOperation.highlight ||
          ModerateOperation.recommend ||
          ModerateOperation.close ||
          ModerateOperation.open ||
          ModerateOperation.move ||
          ModerateOperation.type ||
          ModerateOperation.repair ||
          ModerateOperation.delete ||
          ModerateOperation.bump ||
          ModerateOperation.down:
        return null;
    }

    final notify = form.querySelector('input[name="sendreasonpm"]');
    return ModerateForm(
      operation: asked,
      tid: tid,
      fid: fid,
      fields: fields,
      uid: uid,
      forums: forums,
      reasons: _reasons(form),
      canNotify: notify != null,
      notifyForced: _notifyForced(notify),
      choices: choices,
    );
  }

  static bool _isActionTarget(String action, ModerateOperation asked) {
    final Uri uri;
    try {
      uri = Uri.parse(action.replaceAll('&amp;', '&'));
    } on FormatException {
      return false;
    }
    if (!isForumScriptUri(uri, 'forum.php')) {
      return false;
    }
    final query = uniqueQueryParameters(uri);
    return query != null &&
        query['mod'] == 'topicadmin' &&
        query['action'] == asked.action &&
        query['modsubmit'] == 'yes';
  }

  /// The reasons the site set for management in window [form] (`ul#reasonselect`), separators left out.
  static List<String> _reasons(uh.Element form) => form
      .querySelectorAll('ul#reasonselect > li')
      .map((e) => e.text?.trim() ?? '')
      .where((e) => e.isNotEmpty && !RegExp(r'^-+$').hasMatch(e))
      .toList();

  /// The forum notifies the author whatever is sent: the checkbox [notify] served checked and disabled.
  static bool _notifyForced(uh.Element? notify) =>
      notify != null && notify.attributes.containsKey('disabled') && notify.attributes.containsKey('checked');

  /// The choices of [select], in the forum's order, the label trimmed (the empty category is `&nbsp;`); a value listed
  /// twice is kept once, where it is listed last (the icon window lists the thread's icon first as `当前图标`, then
  /// among the others with its name). [images] gives a choice's picture by value.
  static List<ModerateChoice> _choices(uh.Element? select, {Map<String, String> images = const {}}) {
    if (select == null) {
      return const [];
    }
    final choices = <ModerateChoice>[];
    for (final option in select.querySelectorAll('option')) {
      final value = option.attributes['value'];
      if (value == null) {
        continue;
      }
      // Selected in either place: the thread's own.
      final selected = option.attributes.containsKey('selected') || choices.any((e) => e.value == value && e.selected);
      choices
        ..removeWhere((e) => e.value == value)
        ..add(
          ModerateChoice(
            value: value,
            label: option.text?.trim() ?? '',
            selected: selected,
            image: images[value],
          ),
        );
    }
    return choices;
  }

  /// The picture of each stamp and icon by id, as the script of a stamp or icon window shows it: the file of
  /// `stampurls[ID] = 'FILE'` in the folder of `<img src="…image/stamp/' + stampurls`, resolved against the forum.
  static Map<String, String> _stampImages(uh.Document doc) {
    final script = doc.querySelectorAll('script').map((e) => e.text ?? '').join('\n');
    final folder = RegExp(r'''src="([^"'<>]*image/stamp/)'\s*\+\s*stampurls''').firstMatch(script)?.group(1);
    if (folder == null) {
      return const {};
    }
    final Uri base;
    try {
      base = Uri.parse('$baseUrl/').resolve(folder);
    } on FormatException {
      return const {};
    }
    if (base.scheme != 'https' && base.scheme != 'http') {
      return const {};
    }
    return {
      for (final m in RegExp(r"stampurls\[(\d+)\]\s*=\s*'([\w.-]+)'").allMatches(script))
        m.group(1)!: base.resolve(m.group(2)!).toString(),
    };
  }

  /// The window [form] offers [operation]: an `operations[]` of it (a checkbox, a radio, or the hidden one of a window
  /// of that operation alone).
  static bool _offers(uh.Element form, ModerateOperation operation) =>
      form.querySelector('input[name="operations[]"][value="${operation.value}"]') != null;

  /// The end day of [operation] the window shows (`Y-m-d H:i`), when after today.
  static DateTime? _expiration(uh.Element form, ModerateOperation operation) {
    final name = switch (operation) {
      ModerateOperation.stick ||
      ModerateOperation.digest ||
      ModerateOperation.highlight ||
      ModerateOperation.recommend => 'expiration${operation.value}',
      _ => null,
    };
    final value = name == null ? null : form.querySelector('input[name="$name"]')?.attributes['value']?.trim();
    final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(value ?? '');
    if (match == null) {
      return null;
    }
    final day = DateTime(int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!));
    final now = DateTime.now();
    return day.isAfter(DateTime(now.year, now.month, now.day)) ? day : null;
  }

  /// [doc] is the forum's window of [operation]'s group for thread [tid] (or for threads [tids] of a management of
  /// several) of forum [fid], served without [operation]: the account may not do it (no permission to highlight), or
  /// the forum does not offer it there (recommendation turned off in the forum).
  static bool lacksOperation(
    uh.Document doc,
    ModerateOperation operation, {
    required int fid,
    String? tid,
    List<String>? tids,
  }) {
    final form = doc.querySelector('form#moderateform');
    // An action of its own is refused in the forum's words, never served without the operation.
    if (operation.group == 0 || form == null || !_isTarget(form.attributes['action'] ?? '', operation.group)) {
      return false;
    }
    String? hidden(String name) => form.querySelector('input[type="hidden"][name="$name"]')?.attributes['value'];
    final served = form
        .querySelectorAll('input[type="hidden"][name="moderate[]"]')
        .map((e) => e.attributes['value'] ?? '')
        .toList();
    final asked = tids?.toSet() ?? {?tid};
    return (hidden('formhash') ?? '').isNotEmpty &&
        hidden('fid') == '$fid' &&
        served.isNotEmpty &&
        served.every(asked.contains) &&
        (tids != null || served.length == 1) &&
        !_offers(form, operation);
  }

  /// The window of operation [asked] for some of threads [tids] of forum [fid] read from [doc], served to [uid]; null
  /// when [doc] has no such window (as [parse]), or holds none of [tids] or a thread not asked.
  ///
  /// The forum serves the threads it takes, in its own order: it leaves out a thread not in the forum (moved,
  /// deleted, a thread of another forum stuck here), one waiting for approval, and those past the account's threads
  /// per page.
  static ModerateBatchForm? parseBatch(
    uh.Document doc,
    ModerateOperation asked, {
    required List<String> tids,
    required int fid,
    int uid = 0,
  }) {
    final form = doc.querySelector('form#moderateform');
    if (asked.group == 0 || form == null) {
      return null;
    }
    final asks = tids.toSet();
    final served = <String>{};
    for (final input in form.querySelectorAll('input[type="hidden"][name="moderate[]"]')) {
      final tid = input.attributes['value'] ?? '';
      if (!asks.contains(tid) || !served.add(tid)) {
        return null;
      }
    }
    if (served.isEmpty) {
      return null;
    }
    // The moderator picked close or open for threads that may be either: done as picked, whatever the window of one
    // thread checks.
    final window = _parse(
      form,
      asked,
      tid: served.first,
      fid: fid,
      uid: uid,
      keepThread: false,
      followChecked: false,
    );
    return window == null ? null : ModerateBatchForm(window: window, tids: served.toList());
  }

  static bool _isTarget(String action, int group) {
    final Uri uri;
    try {
      uri = Uri.parse(action.replaceAll('&amp;', '&'));
    } on FormatException {
      return false;
    }
    if (!isForumScriptUri(uri, 'forum.php')) {
      return false;
    }
    final query = uniqueQueryParameters(uri);
    return query != null &&
        query['mod'] == 'topicadmin' &&
        query['action'] == 'moderate' &&
        query['modsubmit'] == 'yes' &&
        query['optgroup'] == '$group';
  }

  /// The forums of the move select, the thread's own forum [fid] left out (moving there the forum does nothing and
  /// still says it succeeded).
  static List<ModerateChoice> _forums(uh.Element? select, int fid) {
    if (select == null) {
      return const [];
    }
    final forums = <ModerateChoice>[];
    for (final option in select.querySelectorAll('option')) {
      final value = option.attributes['value'] ?? '';
      final id = int.tryParse(value);
      if (id == null || id <= 0 || id == fid) {
        continue;
      }
      final raw = option.text ?? '';
      final label = raw.trim();
      if (label.isEmpty) {
        continue;
      }
      // The forum indents a sub forum with `&nbsp; &nbsp; &nbsp; ` per level.
      final lead = raw.length - raw.trimLeft().length;
      final parent = option.parent;
      final groupLabel = parent?.localName == 'optgroup' ? parent?.attributes['label'] : null;
      forums.add(
        ModerateChoice(
          value: value,
          label: label,
          depth: lead == 0 ? 0 : (lead / 6).ceil(),
          group: groupLabel?.replaceFirst(RegExp('^-+'), '').trim(),
        ),
      );
    }
    return forums;
  }
}

/// What the moderator chose in a window, sent with [ModerateForm.fields].
final class ModerateRequest {
  /// Constructor.
  const ModerateRequest({
    required this.operation,
    this.level,
    this.expiration,
    this.moveTo,
    this.redirect = false,
    this.reason = '',
    this.notify = false,
    this.highlight,
    this.recommend = true,
    this.recommendTitle,
    this.choice,
    this.threadType,
  });

  /// The operation.
  final ModerateOperation operation;

  /// The stick or digest level ([ModerateChoice.value]).
  final String? level;

  /// The day a stick, digest, highlight or recommendation ends, none for no end.
  final DateTime? expiration;

  /// The forum to move or copy to ([ModerateChoice.value]).
  final String? moveTo;

  /// Leave a redirect behind in the forum the thread leaves.
  final bool redirect;

  /// The reason, as typed.
  final String reason;

  /// Notify the author.
  final bool notify;

  /// The highlight to set; none takes it off.
  final ModerateHighlight? highlight;

  /// Recommend the thread (`isrecommend` 1), or take its recommendation off (0).
  final bool recommend;

  /// The title the recommendation shows, as typed; the window's [ModerateForm.recommendTitle] when null, the
  /// thread's title when empty.
  final String? recommendTitle;

  /// The stamp, icon or category chosen ([ModerateForm.choices]); none (an empty stamp or icon) when null.
  final String? choice;

  /// The category of the copy in the forum copied to (the forum's `getthreadtypes`); `0` when null.
  final String? threadType;

  /// The form body of this request for [form]: the served hidden fields, the operation and its own fields, the reason
  /// and the notice, as the website's window posts them. Nothing else (no ban of the author, no deletion of all his
  /// posts, no violation record). Nothing at all for a repair, which takes nothing.
  Map<String, String> body(ModerateForm form) {
    if (operation.group == 0) {
      if (operation == ModerateOperation.repair) {
        return const {};
      }
      return {
        ...form.fields,
        ...switch (operation) {
          // The forum takes a stamp or an icon that is not sent for one: none is sent empty.
          ModerateOperation.stamp => {'stamp': choice ?? ''},
          ModerateOperation.stamplist => {'stamplist': choice ?? ''},
          ModerateOperation.copy => {'copyto': moveTo ?? '', 'threadtypeid': threadType ?? '0'},
          _ => const <String, String>{},
        },
        'reason': reason.trim(),
        if (form.canNotify && (notify || form.notifyForced)) 'sendreasonpm': 'on',
      };
    }
    String day(DateTime? d) => d == null
        ? ''
        : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';
    final hasLevel = (int.tryParse(level ?? '') ?? 0) > 0;
    return {
      ...form.fields,
      'operations[]': operation.value,
      ...switch (operation) {
        ModerateOperation.stick => {'sticklevel': level ?? '0', 'expirationstick': hasLevel ? day(expiration) : ''},
        ModerateOperation.digest => {'digestlevel': level ?? '0', 'expirationdigest': hasLevel ? day(expiration) : ''},
        ModerateOperation.highlight => _highlightBody(highlight ?? const ModerateHighlight(), day(expiration)),
        ModerateOperation.recommend => {
          'isrecommend': recommend ? '1' : '0',
          'expirationrecommend': recommend ? day(expiration) : '',
          ...form.recommendFields,
          if (form.recommendTitle case final served? when recommend) 'reducetitle': (recommendTitle ?? served).trim(),
        },
        ModerateOperation.close || ModerateOperation.open => {'expirationclose': ''},
        ModerateOperation.move => {
          'moveto': moveTo ?? '',
          'threadtypeid': '0',
          'type': redirect && form.canRedirect ? 'redirect' : 'normal',
        },
        ModerateOperation.type => {'typeid': choice ?? ''},
        ModerateOperation.stamp ||
        ModerateOperation.stamplist ||
        ModerateOperation.copy ||
        ModerateOperation.repair ||
        ModerateOperation.delete => const <String, String>{},
        ModerateOperation.bump => {'expirationbump': ''},
        ModerateOperation.down => {'expirationdown': ''},
      },
      'reason': reason.trim(),
      if (form.canNotify && (notify || form.notifyForced)) 'sendreasonpm': 'on',
    };
  }

  /// The fields of highlight [h] ending on [day] (empty: no end); the end day only for a highlight the forum counts.
  static Map<String, String> _highlightBody(ModerateHighlight h, String day) => {
    'highlight_color': '${h.color}',
    'highlight_style[1]': h.bold ? '1' : '0',
    'highlight_style[2]': h.italic ? '1' : '0',
    'highlight_style[3]': h.underline ? '1' : '0',
    'highlight_bgcolor': h.background,
    'expirationhighlight': h.marksTitle ? day : '',
  };
}

/// The management window of the forum for several threads of a forum ([ModerateForm.parseBatch]).
///
/// The forum takes one verdict for all of them: it says nothing of the threads it leaves out, so the threads the
/// window holds ([tids]) are the ones a request acts on.
final class ModerateBatchForm {
  /// Constructor.
  const ModerateBatchForm({required this.window, required this.tids});

  /// The window, as for one thread: its [ModerateForm.fields] hold no thread, its [ModerateForm.tid] is the first of
  /// [tids].
  final ModerateForm window;

  /// The threads the window holds, in the forum's order.
  final List<String> tids;

  /// The form body of [request] for these threads: [ModerateRequest.body] of the window with every thread.
  ///
  /// The website's form repeats `moderate[]`; the threads are numbered instead (`moderate[0]`, `moderate[1]`…), which
  /// the forum reads as the same list, so the body stays a map of one value per field (the Android client posts
  /// nothing else).
  Map<String, String> body(ModerateRequest request) => {
    ...request.body(window),
    for (final (i, tid) in tids.indexed) 'moderate[$i]': tid,
  };
}

/// How the forum answered a management request.
sealed class ModerateOutcome {
  const ModerateOutcome();
}

/// The forum carried it out (`admin_succeed`); [message] is its words ("管理操作成功"), empty when it gave none.
final class ModerateSucceeded extends ModerateOutcome {
  /// Constructor.
  const ModerateSucceeded(this.message);

  /// The forum's message.
  final String message;
}

/// The forum refused it, in its own words [message] (no permission to stick so high, the end day out of range, the
/// thread not in this forum any more…); empty when the answer said nothing the app can show.
final class ModerateRefused extends ModerateOutcome {
  /// Constructor.
  const ModerateRefused(this.message);

  /// The forum's message.
  final String message;
}

/// What the forum answered when asked for a management window: the window, or its refusal to open it.
sealed class ModerateWindow {
  const ModerateWindow();
}

/// The window, ready to fill in.
final class ModerateWindowReady extends ModerateWindow {
  /// Constructor.
  const ModerateWindowReady(this.form);

  /// The window.
  final ModerateForm form;
}

/// The forum refused to open the window, in its own words [message] (not a moderator of this forum, no such thread).
final class ModerateWindowRefused extends ModerateWindow {
  /// Constructor.
  const ModerateWindowRefused(this.message, {this.unavailable = false});

  /// The forum's message, empty when it gave none.
  final String message;

  /// The forum served the window without the operation ([ModerateForm.lacksOperation]): asking again changes nothing.
  final bool unavailable;
}

/// What the forum answered when asked for the management window of several threads.
sealed class ModerateBatchWindow {
  const ModerateBatchWindow();
}

/// The window of the threads the forum takes.
final class ModerateBatchWindowReady extends ModerateBatchWindow {
  /// Constructor.
  const ModerateBatchWindowReady(this.form);

  /// The window.
  final ModerateBatchForm form;
}

/// The forum refused to open the window, in its own words [message] (none of the threads can be managed here, not a
/// moderator of this forum).
final class ModerateBatchWindowRefused extends ModerateBatchWindow {
  /// Constructor.
  const ModerateBatchWindowRefused(this.message, {this.unavailable = false});

  /// The forum's message, empty when it gave none.
  final String message;

  /// The forum served the window without the operation ([ModerateForm.lacksOperation]).
  final bool unavailable;
}

/// What became of one thread of a management of several threads.
sealed class ModerateBatchResult {
  const ModerateBatchResult();
}

/// The forum carried it out on the thread.
final class ModerateBatchDone extends ModerateBatchResult {
  /// Constructor.
  const ModerateBatchDone();
}

/// Why a thread of a management of several threads was not done.
enum ModerateBatchFailure {
  /// The forum refused it or left the thread out, in its words.
  refused,

  /// The account changed: nothing more was sent.
  accountChanged,

  /// The request failed before it was sent, or was never sent (the network, an answer the app can not read).
  failed,

  /// The request of the thread was sent, and its answer lost (the network, an answer the app can not read): the
  /// forum may have carried it out.
  unknown,
}

/// The thread was not done.
final class ModerateBatchFailed extends ModerateBatchResult {
  /// Constructor.
  const ModerateBatchFailed(this.kind, [this.message = '']);

  /// Why.
  final ModerateBatchFailure kind;

  /// The forum's words for a [ModerateBatchFailure.refused], empty when it gave none.
  final String message;
}

/// What became of each thread of a management of several threads, in the order they were picked.
final class ModerateBatchReport {
  /// Constructor.
  const ModerateBatchReport(this.results);

  /// Each thread's result, by tid.
  final Map<String, ModerateBatchResult> results;

  /// The threads done.
  int get doneCount => results.values.whereType<ModerateBatchDone>().length;

  /// The threads not done, with why.
  List<(String, ModerateBatchFailed)> get failed => [
    for (final MapEntry(:key, :value) in results.entries)
      if (value case final ModerateBatchFailed failed) (key, failed),
  ];
}

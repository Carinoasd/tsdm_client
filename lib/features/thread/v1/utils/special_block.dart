import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// The content [bodyHtml] of the first floor [pid] without what the forum's template of the thread's [special] block
/// printed there, which the app shows as its own card instead (plugin 2.8.0, see `threadPageFromApi`).
///
/// On the web page the special template sits in the floor's `div.pcbs` beside everything else the floor carries
/// there (the content table `td.t_f#postmessage_PID`, the attachments, the tags, the latest moderation, other plugins'
/// header and footer, the fast reply of the first floor), so only the template's own top level elements are cut,
/// by type, as the forum's default templates (`viewthread_poll`, `_trade`, `_reward`, `_activity`, `_debate`) print
/// them:
///
/// * poll: `form#poll`, keeping what other plugins print at its top (the `viewthread_poll_top` hook, such as
///   pollplus's notice: a direct child of the form the template does not print), and the template's own script just
///   before the form (empty, or the limit of a multiple choice poll);
/// * goods: the counter line `div.trdc`, the goods list (`div.xs1.cl` around `div.trdb`), the empty counter
///   description `div#postmessage_PID` (kept when it has text) and the "本柜台无商品" `div.locked` of a thread without
///   goods;
/// * bounty: `div.rwd` is replaced by the content table inside it (the bounty line and the answer button go), the
///   accepted answer `div.rwdbst` goes; the attachments the template prints after it stay;
/// * activity: the template's `checkform` script just before the details, the details `div.act`, the hidden forms
///   `div#activityjoin` and `div#activityjoincancel`, the applicant lists (`div.ptm.pbm.xs1` with their `table.dt`);
/// * debate: the verdict `div#umpirepoint`, the end time and umpire lines `p.dtm`, the points `div.ds` and the
///   votes `div.dr`;
/// * red packet (plugin 3.5.0): the card `div.hb-entry`, its `<style>`, the envelope `div.mask#hb_mask` and its
///   script ([_hongbaoBlock]).
///
/// Other plugins' top level scripts and blocks, and any other `div.locked`, stay. The rest is kept exactly as the
/// forum printed it (the cut is made on the source, not re-serialized).
///
/// Fails closed, [bodyHtml] coming back unchanged (the card then shows beside the forum's own block rather than
/// losing any of the content), when: the floor has no `div.pcbs`; an element to cut has no end the parser can place;
/// an element to cut holds the floor's content cell (`td.t_f`, an `id="postmessage_…"`), the attachments, the tags,
/// another block of the template or anything else the floor keeps: html left unclosed inside a block (an
/// `[align=center]` of the umpire's point is a `<div align>`, a plugin hook inside the activity's details) makes the
/// parser take the following siblings into it; or the content cell is not intact afterwards.
String bodyHtmlWithoutSpecialBlock(String bodyHtml, ThreadSpecial special, {required String pid}) {
  if (bodyHtml.isEmpty) {
    return bodyHtml;
  }
  final fragment = parseFragment(bodyHtml, generateSpans: true);
  final pcbs = fragment.children.where((e) => e.localName == 'div' && e.classes.contains('pcbs')).firstOrNull;
  if (pcbs == null) {
    return bodyHtml;
  }
  final message = _messageCell(fragment, pid);
  if (message == null) {
    return bodyHtml;
  }

  // The parser reads `\r\n` as one `\n` (the forum's templates print `\r\n`): its offsets are mapped back.
  final offsets = _sourceOffsets(bodyHtml);
  (int, int)? rangeOf(Element e) {
    final start = e.sourceSpan?.start.offset;
    final startTagEnd = e.sourceSpan?.end.offset;
    if (start == null || startTagEnd == null || startTagEnd >= offsets.length) {
      return null;
    }
    final end = e.endSourceSpan?.end.offset;
    if (end != null) {
      return end < offsets.length && end >= start ? (offsets[start], offsets[end]) : null;
    }
    // The parser gives a raw text element (a script) no end span: its end tag is the first one after its text.
    if (!_rawTextElements.contains(e.localName)) {
      return null;
    }
    final close = RegExp(
      '</${e.localName}',
      caseSensitive: false,
    ).allMatches(bodyHtml, offsets[startTagEnd]).firstOrNull;
    final closeEnd = close == null ? -1 : bodyHtml.indexOf('>', close.end);
    return closeEnd < 0 ? null : (offsets[start], closeEnd + 1);
  }

  // (start, end, replacement) of each cut, in document order.
  final cuts = <(int, int, String)>[];
  for (final child in pcbs.children) {
    final cut = _cutOf(child, special, pid);
    if (cut == _Cut.keep) {
      continue;
    }
    final range = rangeOf(child);
    if (range == null || !_ownsOnlyItsBlock(child, special, pid)) {
      return bodyHtml;
    }
    switch (cut) {
      case _Cut.keep:
        break;
      case _Cut.remove:
        cuts.add((range.$1, range.$2, ''));
      case _Cut.keepHookOutput:
        // What other plugins print among the form's direct children, as the forum printed it.
        final kept = StringBuffer();
        for (final hook in child.children.where((e) => !_pollTemplateChild(e))) {
          final hookRange = rangeOf(hook);
          if (hookRange == null) {
            return bodyHtml;
          }
          kept.write(bodyHtml.substring(hookRange.$1, hookRange.$2));
        }
        cuts.add((range.$1, range.$2, '$kept'));
      case _Cut.unwrapMessage:
        final tables = child.querySelectorAll('table').where((e) => e.querySelector('td.t_f') != null).toList();
        final tableRange = tables.length == 1 ? rangeOf(tables.single) : null;
        if (tableRange == null) {
          return bodyHtml;
        }
        cuts.add((range.$1, range.$2, bodyHtml.substring(tableRange.$1, tableRange.$2)));
    }
  }
  if (cuts.isEmpty) {
    return bodyHtml;
  }
  final out = StringBuffer();
  var last = 0;
  for (final (start, end, replacement) in cuts) {
    if (start < last || end > bodyHtml.length || end < start) {
      return bodyHtml;
    }
    out
      ..write(bodyHtml.substring(last, start))
      ..write(replacement);
    last = end;
  }
  out.write(bodyHtml.substring(last));
  final result = out.toString();

  // The content cell is still there, whole, and still the only one.
  final after = _messageCell(parseFragment(result), pid);
  if (after == null || after.outerHtml != message.outerHtml) {
    return bodyHtml;
  }
  return result;
}

enum _Cut { keep, remove, keepHookOutput, unwrapMessage }

/// The elements whose text the parser reads raw, ending at their own end tag.
const _rawTextElements = {'script', 'style', 'textarea', 'title', 'xmp', 'noscript', 'noembed', 'noframes', 'iframe'};

/// The content cell of floor [pid] in [root]: the one `td.t_f#postmessage_PID`; null when there is none, or more.
Element? _messageCell(Node root, String pid) {
  final cells = (root is DocumentFragment ? root.querySelectorAll('td') : (root as Element).querySelectorAll('td'))
      .where((e) => e.id == 'postmessage_$pid')
      .toList();
  return cells.length == 1 ? cells.single : null;
}

/// The script the poll template prints just before its form: empty, or the limit of a multiple choice poll.
final _pollScript = RegExp(r'^\s*(?:var\s+max_obj\s*=\s*\d+\s*;\s*var\s+p\s*=\s*0\s*;\s*)?$');

/// The "本柜台无商品" of a trade thread without goods (`trade_nogoods`), in either script.
final _noGoods = RegExp('本[柜櫃]台[无無]商品');

/// The direct children of `form#poll` the poll template prints; the others are other plugins' hook output.
bool _pollTemplateChild(Element e) =>
    e.localName == 'input' ||
    e.localName == 'script' ||
    (e.localName == 'div' && (e.classes.contains('pinf') || e.classes.contains('pcht'))) ||
    (e.localName == 'p' && e.classes.contains('ptmr'));

/// The top level element [e] of `div.pcbs` the template of [special] printed, and how it goes.
_Cut _cutOf(Element e, ThreadSpecial special, String pid) {
  final tag = e.localName;
  final classes = e.classes;
  final next = e.nextElementSibling;
  return switch (special) {
    PollSpecial() when tag == 'form' && e.id == 'poll' => _Cut.keepHookOutput,
    PollSpecial()
        when tag == 'script' && next?.localName == 'form' && next?.id == 'poll' && _pollScript.hasMatch(e.text) =>
      _Cut.remove,
    TradeSpecial() when tag == 'div' && classes.contains('trdc') => _Cut.remove,
    TradeSpecial() when tag == 'div' && classes.contains('xs1') && e.querySelector('div.trdb') != null => _Cut.remove,
    TradeSpecial() when tag == 'div' && e.id == 'postmessage_$pid' && e.text.trim().isEmpty => _Cut.remove,
    TradeSpecial(:final goods)
        when tag == 'div' && classes.contains('locked') && goods.isEmpty && _noGoods.hasMatch(e.text) =>
      _Cut.remove,
    RewardSpecial() when tag == 'div' && classes.contains('rwd') => _Cut.unwrapMessage,
    RewardSpecial() when tag == 'div' && classes.contains('rwdbst') => _Cut.remove,
    ActivitySpecial()
        when tag == 'script' &&
            next?.localName == 'div' &&
            next!.classes.contains('act') &&
            e.text.contains('function checkform(') =>
      _Cut.remove,
    ActivitySpecial() when tag == 'div' && classes.contains('act') => _Cut.remove,
    ActivitySpecial() when tag == 'div' && (e.id == 'activityjoin' || e.id == 'activityjoincancel') => _Cut.remove,
    ActivitySpecial()
        when tag == 'div' && classes.containsAll(const ['ptm', 'pbm', 'xs1']) && e.querySelector('table.dt') != null =>
      _Cut.remove,
    DebateSpecial() when tag == 'div' && (e.id == 'umpirepoint' || classes.contains('ds') || classes.contains('dr')) =>
      _Cut.remove,
    DebateSpecial() when tag == 'p' && classes.contains('dtm') => _Cut.remove,
    HongbaoSpecial() when _hongbaoBlock(e) => _Cut.remove,
    _ => _Cut.keep,
  };
}

/// The top level elements of `div.pcbs` the hongbao plugin prints for its red packet (plugin 3.5.0,
/// `threadplugin_hongbao::viewthread()`): the card `div.hb-entry`, its style (the `<style>` right after the card that
/// styles it), the envelope dialog `div.mask#hb_mask` and the script opening it (`window.hongbaoOpen`).
bool _hongbaoBlock(Element e) => switch (e.localName) {
  'div' => e.classes.contains('hb-entry') || (e.id == 'hb_mask' && e.classes.contains('mask')),
  'style' => (e.previousElementSibling?.classes.contains('hb-entry') ?? false) && e.text.contains('.hb-entry'),
  'script' => e.text.contains('window.hongbaoOpen'),
  _ => false,
};

/// What a floor keeps around the template's blocks; never inside a block the template printed.
const _keptSelectors = [
  'td.t_f',
  'div.pattl',
  'div.ptg',
  'div.modact',
  'div.attach_nopermission',
  'form#vfastpostform',
  'div.pcbs',
  'div.cm',
];

/// Whether the block [e] of the template of [special] holds only what that block prints: neither the content cell, an
/// element of the floor kept around the blocks ([_keptSelectors], an `id="postmessage_…"` other than the trade's
/// empty counter description itself, a `div.locked` of the trade's other than itself), nor another top level block
/// of the template (all signs that html left unclosed made the parser take the following siblings into it). The
/// bounty's `div.rwd` holds the content table, which stays: it may hold exactly one content cell.
bool _ownsOnlyItsBlock(Element e, ThreadSpecial special, String pid) {
  final descendants = e.querySelectorAll('*');
  final cells = descendants.where((d) => d.localName == 'td' && d.classes.contains('t_f')).length;
  if (cells > (special is RewardSpecial && e.classes.contains('rwd') ? 1 : 0)) {
    return false;
  }
  for (final d in descendants) {
    if (d.localName == 'td' && d.classes.contains('t_f')) {
      continue;
    }
    if (d.id.startsWith('postmessage_') || d.id.startsWith('comment_') || d.id.startsWith('post_rate_div_')) {
      return false;
    }
    if (_keptSelectors.any((s) => _matches(d, s))) {
      return false;
    }
    if (special is TradeSpecial && d.localName == 'div' && d.classes.contains('locked')) {
      return false;
    }
    // Another block of the template, inside this one.
    if (d.localName != 'script' && d.parent != null && _cutOf(d, special, pid) != _Cut.keep) {
      return false;
    }
  }
  return true;
}

/// A tiny matcher for the `tag.class` / `tag#id` selectors of [_keptSelectors].
bool _matches(Element e, String selector) {
  final hash = selector.indexOf('#');
  if (hash > 0) {
    return e.localName == selector.substring(0, hash) && e.id == selector.substring(hash + 1);
  }
  final dot = selector.indexOf('.');
  return e.localName == selector.substring(0, dot) && e.classes.contains(selector.substring(dot + 1));
}

/// The offset in [source] of each character the html parser reads from it, and of its end: the parser reads a
/// `\r\n` as a single `\n` (its offsets count it once), every other character as it is.
List<int> _sourceOffsets(String source) {
  final offsets = <int>[];
  for (var i = 0; i < source.length; i++) {
    if (source.codeUnitAt(i) == 0x0A && i > 0 && source.codeUnitAt(i - 1) == 0x0D) {
      continue;
    }
    offsets.add(i);
  }
  return offsets..add(source.length);
}

part of 'models.dart';

/// Which of the two evaluations of a thread: "支持" (`do=add`) or "踩" (`do=subtract`).
enum ThreadRecommendSide {
  /// Support the thread (`do=add`, the page's `a#recommend_add`).
  add('add'),

  /// Tread on the thread (`do=subtract`, the page's `a#recommend_subtract`).
  subtract('subtract')
  ;

  const ThreadRecommendSide(this.query);

  /// The value of `do` the forum takes.
  final String query;
}

/// One of the two buttons the forum prints: its [label] (the forum's own text, set in its settings: "支持", "踩踩")
/// and the members who pressed it, [count] (the thread's `recommend_add` or `recommend_sub`).
final class ThreadRecommendButton extends Equatable {
  /// Constructor.
  const ThreadRecommendButton({required this.label, required this.count});

  /// The forum's text of the button.
  final String label;

  /// How many members pressed it.
  final int count;

  @override
  List<Object?> get props => [label, count];
}

/// The forum's evaluation of a thread by its members, "支持" and "踩" with their counts (Discuz! 主题评价,
/// `forum.php?mod=misc&action=recommend&do=add|subtract&tid=&hash=`), which the web page prints under the first floor
/// (`div#p_btn`: `a#recommend_add`, `a#recommend_subtract`, the counts in `span#recommendv_add` and
/// `span#recommendv_subtract`).
///
/// The forum prints them when the evaluation is on, to a guest (whose buttons open the login) and to a member whose
/// user group may evaluate; a button whose text the settings leave empty is not printed. Nothing printed is no
/// [ThreadRecommend] at all.
///
/// The request belongs to the account the page was served to ([viewerUid], null for a guest): [hash] is its form hash.
final class ThreadRecommend extends Equatable {
  /// Constructor.
  const ThreadRecommend({
    required this.tid,
    required this.hash,
    required this.viewerUid,
    required this.guest,
    this.add,
    this.subtract,
  });

  /// The evaluation the forum printed in [container] (the first floor, or `div#p_btn` itself), for the page served to
  /// [viewerUid]; null when it printed none, or its links are not the forum's evaluation of a thread.
  static ThreadRecommend? fromNode(uh.Element? container, {required int? viewerUid}) {
    if (container == null) {
      return null;
    }
    final addLink = container.querySelector('a#recommend_add');
    final subtractLink = container.querySelector('a#recommend_subtract');
    final link = addLink ?? subtractLink;
    if (link == null) {
      return null;
    }
    final query = Uri.tryParse(link.attributes['href'] ?? '')?.queryParameters ?? const {};
    final tid = int.tryParse(query['tid'] ?? '') ?? 0;
    if (query['mod'] != 'misc' || query['action'] != 'recommend' || tid <= 0) {
      return null;
    }
    // A guest's buttons open the login window (`showWindow('login', …)`), a member's send the evaluation. A member's
    // page that does not tell its account is none: the request could not be checked against the account in use.
    final guest = (link.attributes['onclick'] ?? '').contains("'login'") || viewerUid == 0;
    if (!guest && (viewerUid == null || viewerUid < 0)) {
      return null;
    }
    final add = _buttonOf(addLink, 'recommendv_add');
    final subtract = _buttonOf(subtractLink, 'recommendv_subtract');
    if (add == null && subtract == null) {
      return null;
    }
    return ThreadRecommend(
      tid: tid,
      hash: query['hash'] ?? '',
      viewerUid: guest ? null : viewerUid,
      guest: guest,
      add: add,
      subtract: subtract,
    );
  }

  /// The evaluation in [html], the two links of it the forum's app API answer carries (see
  /// `threadAnswerWithRecommend`), for the page served to [viewerUid].
  static ThreadRecommend? fromHtml(String html, {required int? viewerUid}) =>
      html.isEmpty ? null : fromNode(parseHtmlDocument('<div id="p_btn">$html</div>').body, viewerUid: viewerUid);

  /// The button [link] with its count in `span#[countId]`; null without the link or its text.
  static ThreadRecommendButton? _buttonOf(uh.Element? link, String countId) {
    if (link == null) {
      return null;
    }
    final count = int.tryParse(link.querySelector('span#$countId')?.innerText.trim() ?? '') ?? 0;
    final copy = link.clone(true) as uh.Element;
    copy.querySelector('span#$countId')?.remove();
    final label = copy.innerText.trim();
    if (label.isEmpty) {
      return null;
    }
    return ThreadRecommendButton(label: label, count: count);
  }

  /// The thread.
  final int tid;

  /// The form hash of the page (the links' `hash`).
  final String hash;

  /// The account the page was served to; null for a guest.
  final int? viewerUid;

  /// The page was served to a guest: the buttons open the login.
  final bool guest;

  /// "支持", when printed.
  final ThreadRecommendButton? add;

  /// "踩", when printed.
  final ThreadRecommendButton? subtract;

  /// The button of [side].
  ThreadRecommendButton? button(ThreadRecommendSide side) => switch (side) {
    ThreadRecommendSide.add => add,
    ThreadRecommendSide.subtract => subtract,
  };

  /// The request evaluating the thread as [side], the forum's AJAX menu (`inajax=1`, a GET that writes).
  String url(ThreadRecommendSide side) =>
      '$baseUrl/forum.php?mod=misc&action=recommend&do=${side.query}&tid=$tid'
      '&hash=${Uri.encodeQueryComponent(hash)}&inajax=1';

  /// The same with the button of [side] pressed once more.
  ThreadRecommend pressed(ThreadRecommendSide side) {
    ThreadRecommendButton? more(ThreadRecommendButton? b) =>
        b == null ? null : ThreadRecommendButton(label: b.label, count: b.count + 1);
    return ThreadRecommend(
      tid: tid,
      hash: hash,
      viewerUid: viewerUid,
      guest: guest,
      add: side == ThreadRecommendSide.add ? more(add) : add,
      subtract: side == ThreadRecommendSide.subtract ? more(subtract) : subtract,
    );
  }

  @override
  List<Object?> get props => [tid, hash, viewerUid, guest, add, subtract];
}

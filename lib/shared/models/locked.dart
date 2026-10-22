part of 'models.dart';

sealed class _LockedInfo extends Equatable {
  const _LockedInfo._();

  const factory _LockedInfo.points({required BigInt requiredPoints, required BigInt? points}) = _LockedWithPoints;

  const factory _LockedInfo.purchase({
    required int price,
    required int? purchasedCount,
    required String tid,
    required String pid,
  }) = _LockedWithPurchase;

  const factory _LockedInfo.reply() = _LockedWithReply;

  const factory _LockedInfo.author() = _LockedWithAuthor;

  const factory _LockedInfo.banned() = _LockedWithBlocked;

  const factory _LockedInfo.unknown({required String text}) = _LockedUnknown;

  const factory _LockedInfo.sale({required int price, required int? salesCount, required String tid}) =
      _LockedWithSale._;

  @override
  List<Object?> get props => [];
}

/// This section is invisible because current user does not have enough points.
final class _LockedWithPoints extends _LockedInfo {
  const _LockedWithPoints({required this.requiredPoints, required this.points}) : super._();

  /// Points required to see this post area.
  ///
  /// Not an [int]: authors put any number there, `9999999999999999999` (more than 64 bits) is a common one.
  final BigInt requiredPoints;

  /// Points current user has, which can be negative.
  final BigInt? points;

  @override
  List<Object?> get props => [requiredPoints, points];
}

/// This section needs purchase to be visible.
final class _LockedWithPurchase extends _LockedInfo {
  const _LockedWithPurchase({required this.price, required this.purchasedCount, required this.tid, required this.pid})
    : super._();

  /// Thread id.
  final String? tid;

  /// Post id.
  final String? pid;

  /// Coins price to unlock.
  final int price;

  /// How many people have purchased.
  ///
  /// May be null.
  final int? purchasedCount;

  @override
  List<Object?> get props => [tid, pid, price, purchasedCount];
}

/// This section is locked with purchase but the current user is the provider of thread so content are different.
///
/// Contains sale status:
///
/// 1. Price
/// 2. Sales counts.
/// 3. Url to sale history.
final class _LockedWithSale extends _LockedInfo {
  /// Constructor.
  const _LockedWithSale._({required this.price, required this.salesCount, required this.tid}) : super._();

  /// Price of the locked contents.
  final int price;

  /// Users count of sales.
  ///
  /// Null if not available: Discuz X5 does not render the sales count for moderators.
  final int? salesCount;

  /// Thread if of current thread, to format log history url.
  final String tid;

  @override
  List<Object?> get props => [price, salesCount, tid];
}

/// This section needs reply to be visible.
final class _LockedWithReply extends _LockedInfo {
  const _LockedWithReply() : super._();
}

/// This section is only visible to the author of current thread.
final class _LockedWithAuthor extends _LockedInfo {
  const _LockedWithAuthor() : super._();
}

/// This section is blocked by admin or moderator.
final class _LockedWithBlocked extends _LockedInfo {
  const _LockedWithBlocked() : super._();
}

/// A hidden section whose notice is none of the known ones: the notice is shown as the forum wrote it, the reader
/// still sees that something is hidden there.
final class _LockedUnknown extends _LockedInfo {
  const _LockedUnknown({required this.text}) : super._();

  /// The text of the notice.
  final String text;

  @override
  List<Object?> get props => [text];
}

/// Describe a locked area in `Post`.
///
/// Different types may be locked with different reasons:
/// * [_LockedWithPoints] : Requires the viewer to have at least xxx points.
/// * [_LockedWithPurchase] : Requires the viewer to purchase.
/// * [_LockedWithReply] : Requires the view to reply.
/// * [_LockedWithAuthor] : Only visible to the author and forum moderator.
/// * [_LockedWithSale] : Thread contains sales action, current user provided it.
/// * [_LockedUnknown] : None of the above, the notice as the forum wrote it.
class Locked extends Equatable {
  /// Build a [Locked] from html node [element] where [element] is:
  /// <div class="locked">
  ///
  /// Currently only support locked by purchasing.
  ///
  /// For better layout, when a section is locked with points and inside
  /// "postmessage", we should only build it inside "postmessage" too,
  /// [allowWithPoints] is the flag caller shall specify.
  ///
  /// With [allowUnknown], a block that is none of the known kinds (or a known kind whose numbers cannot be read) is
  /// kept as its notice text ([lockedWithUnknown]) instead of being dropped: the reader of the post content still sees
  /// that something is hidden there.
  Locked.fromLockDivNode(
    uh.Element element, {
    bool allowWithPoints = true,
    bool allowWithPurchase = true,
    bool allowWithReply = true,
    bool allowWithAuthor = true,
    bool allowWithBlocked = true,
    bool allowWithSales = true,
    bool allowUnknown = false,
  }) : _info = _buildLockedFromNode(
         element,
         allowWithPoints: allowWithPoints,
         allowWithPurchase: allowWithPurchase,
         allowWithReply: allowWithReply,
         allowWithAuthor: allowWithAuthor,
         allowWithBlocked: allowWithBlocked,
         allowWithSale: allowWithSales,
         allowUnknown: allowUnknown,
       );

  /// A purchase lock from the fields of a structured thread page answer of the forum's app API (`thread.pay`, plugin
  /// 2.1.0): the lock [Locked.fromLockDivNode] reads from the `div.locked` of the first floor of a paid thread the
  /// viewer has not bought (its [price], the [purchasedCount] the page prints when somebody bought it, the thread [tid]
  /// and the floor [pid] of the pay link).
  Locked.purchase({required int price, required int? purchasedCount, required String tid, required String pid})
    : _info = _LockedWithPurchase(price: price, purchasedCount: purchasedCount, tid: tid, pid: pid);

  static final _purchareRe = RegExp(r'forum.php\?mod=misc&action=pay&tid=(?<tid>\d+)&pid=(?<pid>\d+)');
  static final _salesCountRe = RegExp(r'已购买人数\s*[:：]\s*(?<count>\d+)');

  final _LockedInfo? _info;

  /// Is locked with view's points.
  bool get lockedWithPoints => _info != null && _info is _LockedWithPoints;

  /// Is locked with purchase.
  bool get lockedWithPurchase => _info != null && _info is _LockedWithPurchase;

  /// Is locked with reply.
  bool get lockedWithReply => _info != null && _info is _LockedWithReply;

  /// Is it only visible to the author and forum moderator.
  bool get lockedWithAuthor => _info != null && _info is _LockedWithAuthor;

  /// Is it blocked by moderator.
  bool get lockedWithBlocked => _info != null && _info is _LockedWithBlocked;

  /// Is it locked with sale action.
  bool get lockedWithSale => _info != null && _info is _LockedWithSale;

  /// Is it a hidden section of no known kind, see [unknownText].
  bool get lockedWithUnknown => _info != null && _info is _LockedUnknown;

  /// The notice of a hidden section of no known kind, as the forum wrote it.
  String? get unknownText => switch (_info) {
    _LockedUnknown(:final text) => text,
    _ => null,
  };

  /// Get the tid of current locked model.
  String? get tid {
    if (_info == null) {
      return null;
    }
    if (_info is _LockedWithPurchase) {
      return _info.tid;
    }
    if (_info is _LockedWithSale) {
      return _info.tid;
    }
    return null;
  }

  /// Get the pid of current locked model.
  String? get pid {
    if (_info == null) {
      return null;
    }
    if (_info is _LockedWithPurchase) {
      return _info.pid;
    }
    return null;
  }

  /// Get the price of current locked model.
  ///
  /// Only not null when locked with purchase.
  int? get price {
    if (_info == null) {
      return null;
    }
    if (_info is _LockedWithPurchase) {
      return _info.price;
    }
    if (_info is _LockedWithSale) {
      return _info.price;
    }
    return null;
  }

  /// Get the purchase times count.
  ///
  /// Only not null when locked with purchase.
  int? get purchasedCount {
    if (_info == null) {
      return null;
    }
    if (_info is _LockedWithPurchase) {
      return _info.purchasedCount;
    }
    if (_info is _LockedWithSale) {
      return _info.salesCount;
    }
    return null;
  }

  /// Get the required points to view this area.
  ///
  /// Only not null when locked with points.
  BigInt? get requiredPoints {
    if (_info == null) {
      return null;
    }
    if (_info is _LockedWithPoints) {
      return _info.requiredPoints;
    }
    return null;
  }

  /// Get the points that the current user has.
  ///
  /// Only not null when locked with points.
  BigInt? get points {
    if (_info == null) {
      return null;
    }
    if (_info is _LockedWithPoints) {
      return _info.points;
    }
    return null;
  }

  /// Build from <div class="locked"> [element].
  static _LockedInfo? _buildLockedFromNode(
    uh.Element element, {
    required bool allowWithPoints,
    required bool allowWithPurchase,
    required bool allowWithReply,
    required bool allowWithAuthor,
    required bool allowWithBlocked,
    required bool allowWithSale,
    required bool allowUnknown,
  }) {
    if (allowWithAuthor && element.childNodes.length == 1 && (element.childNodes[0].text?.contains('仅作者可见') ?? false)) {
      return const _LockedInfo.author();
    }

    // Check if is locked with reply.
    if (allowWithReply && element.innerText.contains('查看本帖隐藏内容请回复')) {
      return const _LockedInfo.reply();
    }

    final price = element.querySelector('strong')?.firstEndDeepText()?.split(' ').firstOrNull?.parseToInt();
    // For other users on purchase side.
    final purchasedCount = element.querySelector('em')?.firstEndDeepText()?.split(' ').elementAtOrNull(1)?.parseToInt();

    // Check for locked with purchase.
    //
    // Discuz! X3 kept the pay url inside `onclick="showWindow('pay', 'forum.php?mod=misc&action=pay&...')"` with
    // `href="javascript:;"`. Discuz! X5 moved the url to `href` and uses `onclick="showWindow('pay', this.href)"`,
    // so try the onclick first and fall back to the href.
    final purchaseAnchor = element.querySelector('a.viewpay') ?? element.querySelector('a');
    final purchaseMatch =
        _purchareRe.firstMatch(purchaseAnchor?.attributes['onclick'] ?? '') ??
        _purchareRe.firstMatch(purchaseAnchor?.attributes['href'] ?? '');
    final purchaseTid = purchaseMatch?.namedGroup('tid');
    final purchasePid = purchaseMatch?.namedGroup('pid');
    if (price != null && purchaseTid != null && purchasePid != null) {
      // Locked with purchase.
      if (!allowWithPurchase) {
        return null;
      }

      return _LockedInfo.purchase(price: price, purchasedCount: purchasedCount, tid: purchaseTid, pid: purchasePid);
    }

    // Check for locked with sale.
    //
    // ```html
    // <div class="locked">
    //   <em class="y"><a href="forum.php?mod=misc&action=viewpayments&tid=${TID}">记录</a></em>
    //   付费主题, 价格: <strong>${PRICE} 天使币 </strong>
    //   <span class="pipe">|</span><span>已购买人数: ${COUNT}</span>   <!-- Optional -->
    // </div>
    // ```
    final salesTid = element
        .querySelector('em > a[href*="action=viewpayments"]')
        ?.attributes['href']
        ?.tryParseAsUri()
        ?.queryParameters['tid'];
    // Only for current user on selling side.
    final salesCount =
        element
            .querySelector('span.pipe')
            ?.nextElementSibling
            ?.firstEndDeepText()
            ?.split(' ')
            .lastOrNull
            ?.parseToInt() ??
        _salesCountRe.firstMatch(element.innerText)?.namedGroup('count')?.parseToInt();
    if (price != null && salesTid != null) {
      if (!allowWithSale) {
        return null;
      }

      return _LockedInfo.sale(price: price, salesCount: salesCount, tid: salesTid);
    }

    if (allowWithBlocked && element.innerText.contains('该帖被管理员或版主屏蔽')) {
      return const _LockedInfo.banned();
    }

    if (!allowWithPoints) {
      // Do not allow locked area that locked with points here.
      return null;
    }

    // Points type. The numbers are read as big integers: an author can ask for any number of points and
    // `9999999999999999999` does not fit an int, which dropped the whole block before. The viewer's points can be
    // negative.
    final match = _pointsRe.firstMatch(element.innerText);
    final requiredPoints = BigInt.tryParse(match?.namedGroup('requiredPoints') ?? '');
    final points = BigInt.tryParse(match?.namedGroup('points') ?? '');
    if (requiredPoints != null) {
      return _LockedInfo.points(requiredPoints: requiredPoints, points: points);
    }

    if (!allowUnknown) {
      return null;
    }
    return _LockedInfo.unknown(text: _noticeText(element));
  }

  /// The text of the notice in [element] as the page shows it, white space collapsed: the labels of its buttons, fields
  /// and choices (the password box of a password post), the purchase button (`a.viewpay`, at the end of the line on the
  /// web page), scripts and what is hidden left out.
  static String _noticeText(uh.Element element) {
    final buffer = StringBuffer();
    void visit(uh.Node node) {
      for (final child in node.nodes) {
        if (child is uh.Element) {
          if (_noticeControls.contains(child.localName) ||
              child.attributes.containsKey('hidden') ||
              child.classes.contains('viewpay') ||
              _hiddenRe.hasMatch(child.attributes['style'] ?? '')) {
            continue;
          }
          if (child.localName == 'br') {
            buffer.write(' ');
            continue;
          }
          visit(child);
        } else if (child.nodeType == uh.Node.TEXT_NODE) {
          buffer.write(child.text ?? '');
        }
      }
    }

    visit(element);
    return buffer.toString().replaceAll(_whiteSpaceRe, ' ').trim();
  }

  /// Elements whose text is not the notice: scripts and what is not shown, the controls of a form and their labels.
  static const _noticeControls = {
    'script',
    'style',
    'noscript',
    'template',
    'button',
    'input',
    'select',
    'option',
    'textarea',
    'label',
  };

  static final _hiddenRe = RegExp(r'(^|;)\s*(display\s*:\s*none|visibility\s*:\s*hidden)\b', caseSensitive: false);

  static final _pointsRe = RegExp(r'高于\s*(?<requiredPoints>\d+)\s*才可浏览(，您当前积分为\s*(?<points>-?\d+))?');
  static final _whiteSpaceRe = RegExp(r'\s+');

  /// Check is valid locked area or not.
  bool isValid() {
    if (_info == null) {
      return false;
    }
    if (_info is _LockedWithReply) {
      return true;
    }

    if (_info is _LockedWithPurchase) {
      return _info.price > 0 && tid != null && pid != null;
    }
    if (_info is _LockedWithSale) {
      return _info.price > 0 && tid != null;
    }
    if (_info is _LockedWithPoints ||
        _info is _LockedWithAuthor ||
        _info is _LockedWithBlocked ||
        _info is _LockedUnknown) {
      return true;
    }
    return false;
  }

  /// Check is invalid locked area or not.
  bool isNotValid() => !isValid();

  @override
  List<Object?> get props => [_info];
}

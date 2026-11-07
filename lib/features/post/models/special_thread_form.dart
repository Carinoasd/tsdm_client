import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;

/// The kind of new thread the editor writes: an ordinary thread, a reward (`special=3`) or a red packet thread (the
/// site's `hongbao` thread plugin, `specialextra=hongbao`, which the forum stores as `special` 127).
///
/// A poll has its own editor.
enum ThreadKind {
  /// An ordinary thread.
  normal,

  /// A reward thread: the author pays credits to the best answer.
  reward,

  /// A red packet thread: the author puts credits in a packet the readers grab.
  hongbao
  ;

  /// The kind of the `kind` query parameter of the editor's route; [normal] for none or an unknown value.
  static ThreadKind fromQuery(String? value) => switch (value) {
    'reward' => reward,
    'hongbao' => hongbao,
    _ => normal,
  };

  /// The value of the `kind` query parameter of the editor's route, null for [normal].
  String? get query => switch (this) {
    normal => null,
    reward => 'reward',
    hongbao => 'hongbao',
  };

  /// The query the forum's new thread form takes for this kind (`post.php` reads `special` and `specialextra`).
  String get formQuery => switch (this) {
    normal => '',
    reward => '&special=3',
    hongbao => '&specialextra=hongbao',
  };

  /// The identifier of the thread plugin of [hongbao].
  static const hongbaoPlugin = 'hongbao';
}

/// Why a reward price is refused, as the forum refuses it (`extend_thread_reward::before_newthread`, and
/// `before_editpost` for a raised one).
enum RewardPriceIssue {
  /// No price, or below 1.
  empty,

  /// Above the forum's absolute limit (32767).
  overflow,

  /// Below the group's minimum.
  belowMin,

  /// Above the group's maximum.
  aboveMax,

  /// The price with its tax is more than the member has: for an edit, what is added to the price with its tax.
  shortage,

  /// Below the price of the thread: an edit may only raise it (`reward_credits_fall`).
  fall,
}

/// What the `reward` block of a post form lets the member do (`state`).
enum RewardFormState {
  /// A new reward thread: the price is set.
  newThread,

  /// The first post of an open reward thread edited by its author: the price may be raised.
  open,

  /// The first post of a reward thread whose best answer is chosen, edited by its author: the price is kept.
  resolved,

  /// The first post of a reward thread edited by someone else (a moderator): the price is kept.
  readonly,
}

/// The reward settings of a post form (`reward` of the forum's app API, plugin 2.9.0, `post_reward.php`): the group's
/// price range, the credit paid, what the member has and the tax; for the edit of the first post of a reward thread,
/// the price of the thread and whether the member may raise it ([state]).
final class RewardFormInfo {
  /// Constructor.
  const RewardFormInfo({
    required this.inputName,
    required this.served,
    required this.min,
    required this.max,
    required this.creditTitle,
    required this.creditUnit,
    required this.have,
    required this.tax,
    required this.expirationDays,
    this.state = RewardFormState.newThread,
    this.current,
  }) : assert(state != RewardFormState.open || current != null, 'an open reward thread has its price');

  /// The `reward` block of a post form; null when it is not one of a reward thread (`state` `none` or unknown), or a
  /// form that lets the member set the price (`new`, `open`) lacks the price field.
  static RewardFormInfo? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final state = switch (json['state']) {
      'new' => RewardFormState.newThread,
      'open' => RewardFormState.open,
      'resolved' => RewardFormState.resolved,
      'readonly' => RewardFormState.readonly,
      _ => null,
    };
    if (state == null) {
      return null;
    }
    final inputs = tsdmAppList(json['inputs']);
    final price = inputs.where((e) => e['name'] == 'rewardprice').firstOrNull;
    final editable = state == RewardFormState.newThread || state == RewardFormState.open;
    if (editable && (price == null || price['type'] != 'text')) {
      return null;
    }
    final current = json['price'];
    if (state == RewardFormState.open && (current is! num || current <= 0)) {
      return null;
    }
    final credit = tsdmAppMap(json['credit']);
    final tax = json['tax'];
    return RewardFormInfo(
      inputName: 'rewardprice',
      served: price == null ? null : int.tryParse(tsdmAppText(price['value']).trim()),
      min: tsdmAppInt(json['min']),
      max: tsdmAppInt(json['max']),
      creditTitle: tsdmAppText(credit['title']),
      creditUnit: tsdmAppText(credit['unit']),
      have: json['have'] is num ? (json['have'] as num).toInt() : null,
      tax: tax is num ? tax.toDouble() : 0,
      expirationDays: tsdmAppInt(json['expiration_days']),
      state: state,
      current: current is num && state != RewardFormState.newThread ? current.toInt() : null,
    );
  }

  /// The absolute limit of the forum (`reward_credits_overflow`).
  static const overflow = 32767;

  /// The name of the price field.
  final String inputName;

  /// The price the form came with (the group's minimum for a new thread, the thread's price for an edit), null when it
  /// is not a number or the form has no price field.
  final int? served;

  /// What the member may do with the price.
  final RewardFormState state;

  /// The price of the thread edited (`price`; negative once the best answer is chosen), null for a new thread.
  final int? current;

  /// Whether the member sets the price: a new thread, or an open one edited by its author.
  bool get editable => state == RewardFormState.newThread || state == RewardFormState.open;

  /// Whether the price is raised from [current]: the edit of an open reward thread.
  bool get raising => state == RewardFormState.open;

  /// The lowest price the forum takes: the group's minimum, for an edit not below [current] either.
  int get floor => raising && current! > min ? current! : min;

  /// The group's minimum price.
  final int min;

  /// The group's maximum price, 0 for none.
  final int max;

  /// The credit paid (`creditstransextra[2]`), its title.
  final String creditTitle;

  /// The unit of the credit, may be empty.
  final String creditUnit;

  /// How much of the credit the member has, null when the form does not tell. The plugin reads it from the member's
  /// counts (`getuserprofile('extcredits'.$cid)`, the database), as the forum does when it checks the price.
  final int? have;

  /// The tax rate (`creditstax`), 0.2 for 20%.
  final double tax;

  /// After how many days a moderator may pick the best answer for the author, 0 when the forum does not tell.
  final int expirationDays;

  /// The credit's title with its unit, as the forum prints it.
  String get creditLabel => '$creditUnit$creditTitle'.trim();

  /// What [price] costs with the tax, as the forum computes it (`$rewardprice + ceil($rewardprice * $creditstax)`).
  int realPrice(int price) => price + (price * tax).ceil();

  /// What the member pays for [price] with the tax: all of it for a new thread, what it adds to [current] for an edit
  /// (`extend_thread_reward::before_editpost`: `ceil(Δ + Δ * $creditstax)`).
  int cost(int price) => realPrice(raising ? price - (current ?? 0) : price);

  /// Why the forum would refuse [price], null when it takes it. An edit keeping the price is not checked
  /// (`extend_thread_reward::before_editpost` checks a changed price only): it neither raises nor charges.
  RewardPriceIssue? check(int? price) {
    if (raising && price == current) {
      return null;
    }
    if (price == null || price < 1) {
      return RewardPriceIssue.empty;
    }
    if (raising && price < current!) {
      return RewardPriceIssue.fall;
    }
    if (price > overflow) {
      return RewardPriceIssue.overflow;
    }
    if (price < min) {
      return RewardPriceIssue.belowMin;
    }
    if (max > 0 && price > max) {
      return RewardPriceIssue.aboveMax;
    }
    if (have case final int have when cost(price) > have) {
      return RewardPriceIssue.shortage;
    }
    return null;
  }
}

/// How a red packet is split (`hb_split`).
enum HongbaoSplit {
  /// Each share a random amount (拼手氣).
  lucky('1'),

  /// Every share the same amount (均分).
  even('2')
  ;

  const HongbaoSplit(this.value);

  /// The value posted.
  final String value;
}

/// Why a red packet is refused, as the plugin refuses it (`hongbao_service::create_packet`) or as the form limits it.
enum HongbaoIssue {
  /// No amount, or not a positive integer.
  totalRequired,

  /// No number of shares, or not a positive integer.
  sharesRequired,

  /// More shares than the plugin allows.
  sharesAboveMax,

  /// The amount does not give every share its minimum.
  totalBelowShares,

  /// An even split needs an amount the shares divide.
  notDivisible,

  /// More than the member has.
  shortage,

  /// The blessing is longer than the form takes.
  blessingTooLong,

  /// The password is longer than the form takes.
  passwordTooLong,
}

/// A red packet as the member set it in the editor; [toFields] is what the form posts for it.
final class HongbaoEdits {
  /// Constructor.
  const HongbaoEdits({
    required this.total,
    required this.shares,
    this.split = HongbaoSplit.lucky,
    this.condReply = false,
    this.password = '',
    this.appoint = '',
    this.expire = '',
    this.blessing = '',
  });

  /// The amount of credits in the packet (`hb_total`), null when not set.
  final int? total;

  /// How many shares (`hb_shares`), null when not set.
  final int? shares;

  /// How the packet is split.
  final HongbaoSplit split;

  /// Whether a reader must reply before grabbing a share (`hb_cond`).
  final bool condReply;

  /// The password of the packet (`hb_password`), empty for none.
  final String password;

  /// The members allowed to grab, by name, separated by commas (`hb_appoint`); empty for everyone.
  final String appoint;

  /// The expiry chosen (`hb_expire`, hours; one of [HongbaoFormInfo.expireChoices]).
  final String expire;

  /// The blessing (`hb_blessing`), empty for the plugin's default.
  final String blessing;

  /// The fields the form posts for this packet, as the website's form would: a checkbox only when checked.
  Map<String, String> toFields() => {
    'hb_total': '${total ?? ''}',
    'hb_shares': '${shares ?? ''}',
    'hb_split': split.value,
    if (condReply) 'hb_cond': '1',
    'hb_password': password,
    'hb_appoint': appoint,
    'hb_expire': expire,
    'hb_blessing': blessing,
  };

  /// Why the plugin would refuse this packet against the limits of [info], null when it takes it.
  HongbaoIssue? check(HongbaoFormInfo info) {
    final total = this.total;
    final shares = this.shares;
    if (total == null || total <= 0) {
      return HongbaoIssue.totalRequired;
    }
    if (shares == null || shares <= 0) {
      return HongbaoIssue.sharesRequired;
    }
    if (info.maxShares > 0 && shares > info.maxShares) {
      return HongbaoIssue.sharesAboveMax;
    }
    if (total < info.minShare * shares) {
      return HongbaoIssue.totalBelowShares;
    }
    if (split == HongbaoSplit.even && total % shares != 0) {
      return HongbaoIssue.notDivisible;
    }
    // The box prints the balance from `$_G['member']`, which may lack the credit (0 printed while the member has
    // some; the plugin charges from the database): a printed 0 proves nothing, a positive balance is checked.
    if (info.balance case final int balance when balance > 0 && total > balance) {
      return HongbaoIssue.shortage;
    }
    if (info.blessingMax case final int max when blessing.runes.length > max) {
      return HongbaoIssue.blessingTooLong;
    }
    if (info.passwordMax case final int max when password.runes.length > max) {
      return HongbaoIssue.passwordTooLong;
    }
    return null;
  }
}

/// The red packet form the site's `hongbao` thread plugin prints into the new thread page (its `newthread` hook: the
/// `div.hb-postbox` with the `hb_*` fields), read from the web page: the member's balance, the limits of the shares,
/// the expiry choices, the default blessing and the length limits.
///
/// The forum's app API does not give a thread plugin's fields (`unsupported: threadplugin`); the app knows this one.
final class HongbaoFormInfo {
  /// Constructor.
  const HongbaoFormInfo({
    required this.balance,
    required this.creditLabel,
    required this.maxShares,
    required this.minShare,
    required this.expireChoices,
    required this.expireDefault,
    required this.blessingMax,
    required this.blessingDefault,
    required this.passwordMax,
  });

  /// The form of [document], null when the page has no red packet form the app understands (the plugin's notice
  /// instead of the form: [noticeOf]; another plugin; a page that is not the form).
  static HongbaoFormInfo? parse(uh.Document document) {
    final form = document.querySelector('form#postform');
    final box = form?.querySelector('.hb-postbox');
    if (form == null || box == null) {
      return null;
    }
    uh.Element? input(String name) => box.querySelector('input[name="$name"]');
    final total = input('hb_total');
    final shares = input('hb_shares');
    final split = box.querySelectorAll('input[name="hb_split"]');
    final expire = box.querySelector('select[name="hb_expire"]');
    final blessing = input('hb_blessing');
    if (total == null || shares == null || split.isEmpty || expire == null || blessing == null) {
      return null;
    }
    final choices = <(String, String)>[];
    String? selected;
    for (final option in expire.querySelectorAll('option')) {
      final value = option.attributes['value'] ?? (option.text ?? '').trim();
      choices.add((value, (option.text ?? '').trim()));
      if (option.attributes.containsKey('selected')) {
        selected = value;
      }
    }
    if (choices.isEmpty) {
      return null;
    }
    final text = box.text ?? '';
    final minShare = int.tryParse(RegExp(r'每份至少\s*(\d+)').firstMatch(text)?.group(1) ?? '');
    final balanceNode = box.querySelector('.hb-bal');
    var creditLabel = '';
    if (balanceNode != null) {
      // `目前餘額 <span class="hb-bal">834</span> 天使币`: the credit's name is the text after the balance.
      final siblings = balanceNode.parent?.childNodes ?? const <uh.Node>[];
      final index = siblings.indexOf(balanceNode);
      if (index >= 0) {
        creditLabel = siblings.skip(index + 1).map((n) => n.text ?? '').join().trim();
      }
    }
    return HongbaoFormInfo(
      balance: int.tryParse((balanceNode?.text ?? '').trim()),
      creditLabel: creditLabel,
      maxShares: int.tryParse(shares.attributes['max'] ?? '') ?? 0,
      minShare: minShare == null || minShare < 1 ? 1 : minShare,
      expireChoices: choices,
      expireDefault: selected ?? choices.first.$1,
      blessingMax: int.tryParse(blessing.attributes['maxlength'] ?? ''),
      blessingDefault: blessing.attributes['value'] ?? '',
      passwordMax: int.tryParse(input('hb_password')?.attributes['maxlength'] ?? ''),
    );
  }

  /// What the plugin printed instead of the form (the feature off, the member's group not allowed), null when the
  /// page has the form, or no red packet box at all.
  static String? noticeOf(uh.Document document) {
    final box = document.querySelector('form#postform .hb-postbox');
    if (box == null || box.querySelector('input[name="hb_total"]') != null) {
      return null;
    }
    final text = (box.text ?? '').trim();
    return text.isEmpty ? null : text;
  }

  /// The form as kept in a [Map] (the app's own key in the post form's answer).
  static HongbaoFormInfo? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final choices = [
      for (final choice in tsdmAppList(json['expire_choices']))
        (tsdmAppText(choice['value']), tsdmAppText(choice['label'])),
    ];
    if (choices.isEmpty) {
      return null;
    }
    return HongbaoFormInfo(
      balance: json['balance'] is num ? (json['balance'] as num).toInt() : null,
      creditLabel: tsdmAppText(json['credit_label']),
      maxShares: tsdmAppInt(json['max_shares']),
      minShare: switch (tsdmAppInt(json['min_share'])) {
        final min when min >= 1 => min,
        _ => 1,
      },
      expireChoices: choices,
      expireDefault: tsdmAppText(json['expire_default']),
      blessingMax: json['blessing_max'] is num ? (json['blessing_max'] as num).toInt() : null,
      blessingDefault: tsdmAppText(json['blessing_default']),
      passwordMax: json['password_max'] is num ? (json['password_max'] as num).toInt() : null,
    );
  }

  /// This form as a [Map] ([fromJson]).
  Map<String, dynamic> toJson() => {
    'balance': balance,
    'credit_label': creditLabel,
    'max_shares': maxShares,
    'min_share': minShare,
    'expire_choices': [
      for (final (value, label) in expireChoices) {'value': value, 'label': label},
    ],
    'expire_default': expireDefault,
    'blessing_max': blessingMax,
    'blessing_default': blessingDefault,
    'password_max': passwordMax,
  };

  /// How much of the credit the member has, null when the box does not tell.
  final int? balance;

  /// The credit's name as the box prints it after the balance, may be empty.
  final String creditLabel;

  /// The most shares a packet may have, 0 for no limit.
  final int maxShares;

  /// The least credits a share may hold.
  final int minShare;

  /// The expiry choices (hours, label) in the order of the form.
  final List<(String, String)> expireChoices;

  /// The expiry the form came with.
  final String expireDefault;

  /// The most characters of the blessing, null when the form sets none.
  final int? blessingMax;

  /// The blessing the form came with.
  final String blessingDefault;

  /// The most characters of the password, null when the form sets none.
  final int? passwordMax;

  /// A packet as the form comes: one share, split by luck, the default expiry and blessing.
  HongbaoEdits get initial => HongbaoEdits(total: null, shares: 1, expire: expireDefault, blessing: blessingDefault);
}

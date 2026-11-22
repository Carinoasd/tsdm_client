import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/medal_title_tools/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// The member's pages of the background shop plugin (`plugin.php?id=background:memcp` and `background:sp`) as the
/// forum's app API answers them (plugin 4.1.0): my backgrounds (`bgmine`, `bg_mine`, `schema` 74), the shop and the
/// event shop (`bgstore`, `bg_store`, 75), the storeroom (`bgslot`, `bg_slot`, 76) and the exchange by medals
/// (`bgexchange`, `bg_exchange`, 77).
///
/// The API only reads. Every write is the background plugin's own form, sent back to the background plugin with
/// `tsdmapp=json&tsdmv=4` ([BackgroundShopWrite]); a form of an answer is taken only when it goes to the background
/// plugin of this forum with plain field names, so a tampered answer can never send a write anywhere else.

String _str(Object? v) => v == null ? '' : '$v'.trim();
List<Map<String, dynamic>> _list(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];
Map<String, String> _strings(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': _str(e.value)} : const {};

final _fieldName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

/// The url of a form [raw] of the answer resolved on the forum, null unless it is `plugin.php` of this forum with `id`
/// [plugin], `ac` one of [acs] (none when [acs] is empty) and no other parameter than `id`, `ac` and [more].
Uri? _formUri(String raw, {required String plugin, Set<String> acs = const {}, Set<String> more = const {}}) {
  if (raw.isEmpty) return null;
  final relative = Uri.tryParse(raw);
  if (relative == null) return null;
  final uri = Uri.parse('$baseUrl/').resolveUri(relative);
  final query = uri.queryParameters;
  final ac = query['ac'];
  if (uri.origin != Uri.parse(baseUrl).origin ||
      uri.path != '/plugin.php' ||
      uri.fragment.isNotEmpty ||
      query['id'] != plugin ||
      (acs.isEmpty ? ac != null : !acs.contains(ac)) ||
      query.keys.any((k) => k != 'id' && k != 'ac' && !more.contains(k)) ||
      query.values.any((v) => !_fieldValue.hasMatch(v))) {
    return null;
  }
  return uri;
}

final _fieldValue = RegExp(r'^[A-Za-z0-9_:.\-]{0,64}$');

/// The fixed fields of a form, null when a name is not a plain field name.
Map<String, String>? _fields(Object? v) {
  if (v is! Map) return null;
  final fields = _strings(v);
  if (fields.keys.any((k) => !_fieldName.hasMatch(k))) return null;
  return Map.unmodifiable(fields);
}

bool _names(List<String> names) => names.every(_fieldName.hasMatch);

/// [url] (which has a query already) with [query] added after it, as the website's links are written.
String _withQuery(String url, Map<String, String> query) =>
    '$url${query.entries.map((e) => '&${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join()}';

/// The answer of one of the four actions, as far as it can be used.
sealed class BackgroundShopAnswer<T> {
  const BackgroundShopAnswer();
}

/// The page.
final class BackgroundShopLoaded<T> extends BackgroundShopAnswer<T> {
  /// Constructor.
  const BackgroundShopLoaded(this.page);

  /// The page.
  final T page;
}

/// The forum can not show it: the background plugin off or too old (`installed 0`, `supported 0`), the event shop
/// closed (`bgshop_special_closed`), the exchange switched off (`enabled 0`).
final class BackgroundShopUnavailable<T> extends BackgroundShopAnswer<T> {
  /// Constructor.
  const BackgroundShopUnavailable();
}

/// Where a background is shown: in the floors' content or by the author's side.
enum BackgroundPosition {
  /// 正文背景 (position 0).
  content,

  /// 边栏背景 (position 1).
  sidebar,
}

/// How a background is drawn now, as the forum stored it (`style` of `bg_mine`).
typedef BackgroundStyle = ({String repeat, String alignX, String alignY, String size});

/// A value of a field of the display form, with the forum's word for it.
typedef BackgroundChoice = ({String value, String label});

/// The fields of the display form, in the order of the website.
abstract final class BackgroundStyleFields {
  /// Shown or not (`1`／`0`): `0` is how the website stops using a background.
  static const display = 'dipbg';

  /// Repeated (`0`) or not (`1`).
  static const repeat = 'background_repeat';

  /// Left, centre, right (`0`, `1`, `2`).
  static const alignX = 'background_positionh';

  /// Top, centre, bottom (`0`, `1`, `2`).
  static const alignY = 'background_positionv';

  /// Stretched to the width (`1`), only sent when checked.
  static const stretch = 'background_size';

  /// The fields sent every time, in that order: one left out is set to the plugin's default.
  static const List<String> always = [display, repeat, alignX, alignY];
}

/// The display form of one position (`form` of `bg_mine`).
final class BackgroundStyleForm {
  const BackgroundStyleForm._({required this.url, required this.fields, required this.values});

  /// The form of [json], null unless it posts to `ac=my` of the background plugin.
  static BackgroundStyleForm? parse(Object? json) {
    if (json is! Map || _str(json['method']).toUpperCase() != 'POST') return null;
    final uri = _formUri(_str(json['url']), plugin: 'background:memcp', acs: const {'my'}, more: const {'p'});
    final fields = _fields(json['fields']);
    if (uri == null || fields == null) return null;
    return BackgroundStyleForm._(
      url: uri.toString(),
      // The fields the page fills are never taken from the fixed ones.
      fields: Map.unmodifiable({
        for (final e in fields.entries)
          if (!BackgroundStyleFields.always.contains(e.key) && e.key != BackgroundStyleFields.stretch) e.key: e.value,
      }),
      values: Map.unmodifiable(_strings(json['values'])),
    );
  }

  /// Absolute URL the form posts to.
  final String url;

  /// Fixed fields (form hash, the submit flag naming the position).
  final Map<String, String> fields;

  /// What the website's form starts with ([BackgroundStyleFields]).
  final Map<String, String> values;

  /// The body with every field of [values] the page shows: the four always sent ([BackgroundStyleFields.always]), the
  /// stretch only when `1`.
  Map<String, String> body(Map<String, String> values) => {
    ...fields,
    for (final name in BackgroundStyleFields.always) name: values[name] ?? this.values[name] ?? '',
    if (values[BackgroundStyleFields.stretch] == '1') BackgroundStyleFields.stretch: '1',
  };
}

/// The background a position uses now (`backgrounds.content`／`.sidebar` of `bg_mine`).
final class BackgroundInUse {
  const BackgroundInUse._({
    required this.position,
    required this.imageUrl,
    required this.expiration,
    required this.permanent,
    required this.display,
    required this.style,
    required this.form,
  });

  static BackgroundInUse? _parse(Object? json, BackgroundPosition position) {
    if (json is! Map) return null;
    final style = json['style'];
    return BackgroundInUse._(
      position: position,
      imageUrl: apiImageUrl(json['image']),
      expiration: tsdmAppInt(json['expiration']),
      permanent: json['permanent'] == 1 || tsdmAppInt(json['expiration']) == 0,
      display: json['display'] == 1,
      style: (
        repeat: _str(style is Map ? style['repeat'] : null),
        alignX: _str(style is Map ? style['align_x'] : null),
        alignY: _str(style is Map ? style['align_y'] : null),
        size: _str(style is Map ? style['size'] : null),
      ),
      form: BackgroundStyleForm.parse(json['form']),
    );
  }

  /// Which position.
  final BackgroundPosition position;

  /// The picture, null when the forum can not draw it either.
  final String? imageUrl;

  /// Until when (unix seconds), 0 for good.
  final int expiration;

  /// Kept for good.
  final bool permanent;

  /// Shown on the thread pages (`dipbg` 1).
  final bool display;

  /// How it is drawn now.
  final BackgroundStyle style;

  /// The display form, null when the answer has none usable.
  final BackgroundStyleForm? form;
}

/// My backgrounds (`bg_mine`).
final class BackgroundMine {
  const BackgroundMine._({required this.uid, required this.content, required this.sidebar, required this.choices});

  /// The answer [json] of `bgmine`; null when it is not one.
  static BackgroundShopAnswer<BackgroundMine>? fromJson(Map<String, dynamic>? json) {
    if (_unavailable<BackgroundMine>(json, 'bg_mine') case final a?) return a;
    if (!_usable(json, 'bg_mine', 74)) return null;
    final backgrounds = json!['backgrounds'];
    final choices = json['choices'];
    return BackgroundShopLoaded(
      BackgroundMine._(
        uid: tsdmAppInt(json['uid']),
        content: BackgroundInUse._parse(backgrounds is Map ? backgrounds['content'] : null, BackgroundPosition.content),
        sidebar: BackgroundInUse._parse(backgrounds is Map ? backgrounds['sidebar'] : null, BackgroundPosition.sidebar),
        choices: Map.unmodifiable({
          if (choices is Map)
            for (final e in choices.entries)
              '${e.key}': List<BackgroundChoice>.unmodifiable([
                for (final c in _list(e.value))
                  if (_str(c['value']).isNotEmpty) (value: _str(c['value']), label: _str(c['label'])),
              ]),
        }),
      ),
    );
  }

  /// The account it was served to.
  final int uid;

  /// The content background, null when none.
  final BackgroundInUse? content;

  /// The sidebar background, null when none.
  final BackgroundInUse? sidebar;

  /// The choices of each field of the display form ([BackgroundStyleFields]).
  final Map<String, List<BackgroundChoice>> choices;
}

/// A credit of the shop with the account's balance.
typedef BackgroundCredit = ({int id, String title, String unit, int balance});

/// How long a plan keeps a background.
enum BackgroundPlanKind {
  /// Paid per month (`c<credit>`).
  month,

  /// One year (`sy`, event shop).
  year,

  /// For good (`sf`, event shop).
  forever,
}

/// A way to pay for a background (`offers[]` of `bg_store`).
final class BackgroundOffer {
  const BackgroundOffer._({
    required this.plan,
    required this.creditId,
    required this.creditTitle,
    required this.creditUnit,
    required this.price,
    required this.kind,
    required this.maxMonths,
  });

  static BackgroundOffer? _parse(Map<String, dynamic> json) {
    final credit = json['credit'];
    final kind = switch (json['kind']) {
      'month' => BackgroundPlanKind.month,
      'year' => BackgroundPlanKind.year,
      'forever' => BackgroundPlanKind.forever,
      _ => null,
    };
    final plan = _str(json['plan']);
    final price = tsdmAppInt(json['price']);
    if (kind == null || !_fieldValue.hasMatch(plan) || plan.isEmpty || price < 0 || credit is! Map) return null;
    final most = tsdmAppInt(json['max_months']);
    return BackgroundOffer._(
      plan: plan,
      creditId: tsdmAppInt(credit['id']),
      creditTitle: _str(credit['title']),
      creditUnit: _str(credit['unit']),
      price: price,
      kind: kind,
      // The plugin refuses a cost above 4294967295.
      maxMonths: kind != BackgroundPlanKind.month
          ? 1
          : [
              if (most > 0) most else 1,
              if (price > 0) BackgroundOffer.maxCost ~/ price else 1 << 30,
            ].reduce((a, b) => a < b ? a : b),
    );
  }

  /// The most a purchase may cost (the plugin's limit).
  static const maxCost = 4294967295;

  /// The value sent as the plan.
  final String plan;

  /// The credit paid with.
  final int creditId;

  /// Its name.
  final String creditTitle;

  /// Its unit.
  final String creditUnit;

  /// Per month, or for the whole plan.
  final int price;

  /// How long.
  final BackgroundPlanKind kind;

  /// Months at most (1 unless [kind] is [BackgroundPlanKind.month]).
  final int maxMonths;

  /// What [months] cost (one plan for a year or for good).
  int cost(int months) => kind == BackgroundPlanKind.month ? price * months : price;
}

/// A background of the shop (`backgrounds[]` of `bg_store`).
final class BackgroundStoreItem {
  const BackgroundStoreItem._({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.buys,
    required this.special,
    required this.nonsale,
    required this.offers,
    required this.ownedUntil,
    required this.ownedForever,
  });

  /// Id in the shop.
  final int id;

  /// Name (plain text).
  final String name;

  /// Preview.
  final String? imageUrl;

  /// How many times it was bought.
  final int buys;

  /// An event background.
  final bool special;

  /// Not for sale.
  final bool nonsale;

  /// How it may be paid for here.
  final List<BackgroundOffer> offers;

  /// The account has it until then (unix seconds), null when it has not.
  final int? ownedUntil;

  /// The account has it for good.
  final bool ownedForever;

  /// Whether it can be bought: for sale, with a way to pay, not had for good.
  bool get buyable => !nonsale && offers.isNotEmpty && !ownedForever;
}

/// The purchase form (`buy` of `bg_store`).
final class BackgroundBuyForm {
  const BackgroundBuyForm._({
    required this.url,
    required this.fields,
    required this.idParam,
    required this.positionParam,
    required this.positions,
    required this.planField,
    required this.monthsField,
  });

  static BackgroundBuyForm? _parse(Object? json) {
    if (json is! Map || _str(json['method']).toUpperCase() != 'POST') return null;
    final uri = _formUri(_str(json['url']), plugin: 'background:memcp', acs: const {'buybg'});
    final fields = _fields(json['fields']);
    final query = json['query'];
    final positions = _strings(json['positions']);
    final idParam = _str(query is Map ? query['bgid'] : null);
    final positionParam = _str(query is Map ? query['position'] : null);
    final planField = _str(json['plan_field']);
    final monthsField = _str(json['months_field']);
    final content = positions['content'] ?? '';
    final sidebar = positions['sidebar'] ?? '';
    if (uri == null ||
        fields == null ||
        !_names([idParam, positionParam, planField, monthsField]) ||
        {'id', 'ac', idParam}.length != 3 ||
        {'id', 'ac', idParam, positionParam}.length != 4 ||
        !_fieldValue.hasMatch(content) ||
        !_fieldValue.hasMatch(sidebar) ||
        content.isEmpty ||
        sidebar.isEmpty) {
      return null;
    }
    return BackgroundBuyForm._(
      url: uri.toString(),
      fields: Map.unmodifiable({
        for (final e in fields.entries)
          if (e.key != planField && e.key != monthsField) e.key: e.value,
      }),
      idParam: idParam,
      positionParam: positionParam,
      positions: {BackgroundPosition.content: content, BackgroundPosition.sidebar: sidebar},
      planField: planField,
      monthsField: monthsField,
    );
  }

  /// Absolute URL the form posts to (without the background and the position).
  final String url;

  /// Fixed fields.
  final Map<String, String> fields;

  /// The url parameter of the background.
  final String idParam;

  /// The url parameter of the position.
  final String positionParam;

  /// The value of each position.
  final Map<BackgroundPosition, String> positions;

  /// The field of the plan.
  final String planField;

  /// The field of the months.
  final String monthsField;

  /// Where to post the purchase of [item] for [position].
  String target(BackgroundStoreItem item, BackgroundPosition position) =>
      _withQuery(url, {idParam: '${item.id}', positionParam: positions[position] ?? ''});

  /// The body of a purchase with [offer] for [months] (1 for a plan of a year or for good).
  Map<String, String> body(BackgroundOffer offer, int months) => {
    ...fields,
    planField: offer.plan,
    monthsField: '${offer.kind == BackgroundPlanKind.month ? months : 1}',
  };
}

/// Which list of the shop.
enum BackgroundStoreMode {
  /// 购买背景.
  shop,

  /// 活动商店 (`mode=special`).
  special,
}

/// A page of the shop or of the event shop (`bg_store`).
final class BackgroundStore {
  const BackgroundStore._({
    required this.uid,
    required this.mode,
    required this.specialOn,
    required this.specialTitle,
    required this.keyword,
    required this.paging,
    required this.credits,
    required this.items,
    required this.buy,
  });

  /// The answer [json] of `bgstore`; null when it is not one.
  static BackgroundShopAnswer<BackgroundStore>? fromJson(Map<String, dynamic>? json) {
    if (json != null && json['ok'] == 0 && json['message_key'] == 'bgshop_special_closed') {
      return const BackgroundShopUnavailable();
    }
    if (_unavailable<BackgroundStore>(json, 'bg_store') case final a?) return a;
    if (!_usable(json, 'bg_store', 75)) return null;
    final j = json!;
    return BackgroundShopLoaded(
      BackgroundStore._(
        uid: tsdmAppInt(j['uid']),
        mode: j['mode'] == 'special' ? BackgroundStoreMode.special : BackgroundStoreMode.shop,
        specialOn: j['special_on'] == 1,
        specialTitle: _str(j['special_title']),
        keyword: _str(j['keyword']),
        paging: _paging(j),
        credits: List.unmodifiable([
          for (final c in _list(j['credits']))
            (
              id: tsdmAppInt(c['id']),
              title: _str(c['title']),
              unit: _str(c['unit']),
              balance: tsdmAppInt(c['balance']),
            ),
        ]),
        items: List.unmodifiable([
          for (final b in _list(j['backgrounds']))
            if (tsdmAppInt(b['id']) > 0)
              BackgroundStoreItem._(
                id: tsdmAppInt(b['id']),
                name: _str(b['name']),
                imageUrl: apiImageUrl(b['image']),
                buys: tsdmAppInt(b['buys']),
                special: b['special'] == 1,
                nonsale: b['nonsale'] == 1,
                offers: List.unmodifiable([
                  for (final o in _list(b['offers'])) ?BackgroundOffer._parse(o),
                ]),
                ownedUntil: switch (b['owned']) {
                  final Map<dynamic, dynamic> owned => tsdmAppInt(owned['expiration']),
                  _ => null,
                },
                ownedForever: switch (b['owned']) {
                  final Map<dynamic, dynamic> owned => owned['permanent'] == 1 || tsdmAppInt(owned['expiration']) == 0,
                  _ => false,
                },
              ),
        ]),
        buy: BackgroundBuyForm._parse(j['buy']),
      ),
    );
  }

  /// The account it was served to.
  final int uid;

  /// Which list.
  final BackgroundStoreMode mode;

  /// The event shop is open.
  final bool specialOn;

  /// The forum's name of the event shop.
  final String specialTitle;

  /// The keyword as the plugin took it.
  final String keyword;

  /// Paging.
  final ApiPaging paging;

  /// The credits of this page's plans and the account's balance of each.
  final List<BackgroundCredit> credits;

  /// This page.
  final List<BackgroundStoreItem> items;

  /// The purchase form, null when the answer has none usable.
  final BackgroundBuyForm? buy;

  /// The account's balance of credit [id], null when the page does not tell.
  int? balanceOf(int id) => credits.where((c) => c.id == id).firstOrNull?.balance;
}

/// A background of the storeroom (`slots[]` of `bg_slot`).
final class BackgroundSlot {
  const BackgroundSlot._({
    required this.sid,
    required this.imageUrl,
    required this.bgid,
    required this.name,
    required this.expiration,
    required this.permanent,
    required this.inContent,
    required this.inSidebar,
  });

  /// Id of the slot.
  final int sid;

  /// Picture.
  final String? imageUrl;

  /// Id in the shop, 0 for a picture sent by the staff.
  final int bgid;

  /// Name in the shop, empty for a picture sent by the staff.
  final String name;

  /// Until when (unix seconds), 0 for good.
  final int expiration;

  /// Kept for good.
  final bool permanent;

  /// The thread pages show it as the content background now.
  final bool inContent;

  /// The thread pages show it as the sidebar background now.
  final bool inSidebar;

  /// Whether it is in use at [position].
  bool inUse(BackgroundPosition position) => position == BackgroundPosition.content ? inContent : inSidebar;
}

/// The form putting a slot in use (`set` of `bg_slot`): a GET carrying the form hash.
final class BackgroundSlotForm {
  const BackgroundSlotForm._({
    required this.url,
    required this.fields,
    required this.sidField,
    required this.sideField,
    required this.sides,
    required this.pageField,
  });

  static BackgroundSlotForm? _parse(Object? json) {
    if (json is! Map || _str(json['method']).toUpperCase() != 'GET') return null;
    final uri = _formUri(_str(json['url']), plugin: 'background:memcp', acs: const {'slot'});
    final fields = _fields(json['fields']);
    final sides = _strings(json['sides']);
    final names = [_str(json['sid_field']), _str(json['side_field']), _str(json['page_field'])];
    final content = sides['content'] ?? '';
    final sidebar = sides['sidebar'] ?? '';
    if (uri == null ||
        fields == null ||
        !_names(names) ||
        {'id', 'ac', ...names, ...fields.keys}.length != 5 + fields.length ||
        content.isEmpty ||
        sidebar.isEmpty ||
        !_fieldValue.hasMatch(content) ||
        !_fieldValue.hasMatch(sidebar) ||
        fields.values.any((v) => !_fieldValue.hasMatch(v))) {
      return null;
    }
    return BackgroundSlotForm._(
      url: uri.toString(),
      fields: fields,
      sidField: names[0],
      sideField: names[1],
      sides: {BackgroundPosition.content: content, BackgroundPosition.sidebar: sidebar},
      pageField: names[2],
    );
  }

  /// The url without the slot.
  final String url;

  /// Fixed fields (the form hash).
  final Map<String, String> fields;

  /// The parameter of the slot.
  final String sidField;

  /// The parameter of the position.
  final String sideField;

  /// The value of each position.
  final Map<BackgroundPosition, String> sides;

  /// The parameter of the page.
  final String pageField;

  /// The GET putting [slot] in use at [position], from page [page].
  String target(BackgroundSlot slot, BackgroundPosition position, int page) => _withQuery(url, {
    sidField: '${slot.sid}',
    sideField: sides[position] ?? '',
    pageField: '$page',
    ...fields,
  });
}

/// A page of the storeroom (`bg_slot`).
final class BackgroundSlots {
  const BackgroundSlots._({required this.uid, required this.paging, required this.slots, required this.set});

  /// The answer [json] of `bgslot`; null when it is not one.
  static BackgroundShopAnswer<BackgroundSlots>? fromJson(Map<String, dynamic>? json) {
    if (_unavailable<BackgroundSlots>(json, 'bg_slot') case final a?) return a;
    if (!_usable(json, 'bg_slot', 76)) return null;
    final j = json!;
    return BackgroundShopLoaded(
      BackgroundSlots._(
        uid: tsdmAppInt(j['uid']),
        paging: _paging(j),
        slots: List.unmodifiable([
          for (final s in _list(j['slots']))
            if (tsdmAppInt(s['sid']) > 0)
              BackgroundSlot._(
                sid: tsdmAppInt(s['sid']),
                imageUrl: apiImageUrl(s['image']),
                bgid: tsdmAppInt(s['bgid']),
                name: _str(s['name']),
                expiration: tsdmAppInt(s['expiration']),
                permanent: s['permanent'] == 1 || tsdmAppInt(s['expiration']) == 0,
                inContent: s['in_use'] is Map && (s['in_use'] as Map)['content'] == 1,
                inSidebar: s['in_use'] is Map && (s['in_use'] as Map)['sidebar'] == 1,
              ),
        ]),
        set: BackgroundSlotForm._parse(j['set']),
      ),
    );
  }

  /// The account it was served to.
  final int uid;

  /// Paging.
  final ApiPaging paging;

  /// This page.
  final List<BackgroundSlot> slots;

  /// The form putting a slot in use, null when the answer has none usable.
  final BackgroundSlotForm? set;
}

/// A medal an exchange asks for.
typedef BackgroundCampaignMedal = ({int id, String name, String? imageUrl, bool owned});

/// A background an exchange offers.
typedef BackgroundCampaignChoice = ({int id, String name, String? imageUrl, bool owned});

/// An exchange of backgrounds by medals (`campaigns[]` of `bg_exchange`).
final class BackgroundCampaign {
  const BackgroundCampaign._({
    required this.id,
    required this.minMedals,
    required this.days,
    required this.medals,
    required this.ownedMedals,
    required this.exchanged,
    required this.eligible,
    required this.backgrounds,
  });

  /// The campaign's code (sent as the action).
  final String id;

  /// Medals needed.
  final int minMedals;

  /// Days kept, 0 for good.
  final int days;

  /// The medals it counts.
  final List<BackgroundCampaignMedal> medals;

  /// How many of them the account has.
  final int ownedMedals;

  /// The account exchanged one of this kind already.
  final bool exchanged;

  /// The account can exchange now.
  final bool eligible;

  /// The backgrounds to choose from.
  final List<BackgroundCampaignChoice> backgrounds;
}

/// The exchange form (`form` of `bg_exchange`): a GET carrying the form hash.
final class BackgroundExchangeForm {
  const BackgroundExchangeForm._({
    required this.url,
    required this.fields,
    required this.actionField,
    required this.bgField,
  });

  static BackgroundExchangeForm? _parse(Object? json) {
    if (json is! Map || _str(json['method']).toUpperCase() != 'GET') return null;
    final uri = _formUri(_str(json['url']), plugin: 'background:sp');
    final fields = _fields(json['fields']);
    final names = [_str(json['action_field']), _str(json['bg_field'])];
    if (uri == null ||
        fields == null ||
        !_names(names) ||
        {'id', 'ac', ...names, ...fields.keys}.length != 4 + fields.length ||
        fields.values.any((v) => !_fieldValue.hasMatch(v))) {
      return null;
    }
    return BackgroundExchangeForm._(url: uri.toString(), fields: fields, actionField: names[0], bgField: names[1]);
  }

  /// The url without the campaign.
  final String url;

  /// Fixed fields (the form hash).
  final Map<String, String> fields;

  /// The parameter of the campaign.
  final String actionField;

  /// The parameter of the background.
  final String bgField;

  /// The GET exchanging [campaign] for background [bgid].
  String target(BackgroundCampaign campaign, int bgid) =>
      _withQuery(url, {actionField: campaign.id, bgField: '$bgid', ...fields});
}

/// The exchange page (`bg_exchange`).
final class BackgroundExchange {
  const BackgroundExchange._({required this.uid, required this.campaigns, required this.form});

  /// The answer [json] of `bgexchange`; null when it is not one.
  static BackgroundShopAnswer<BackgroundExchange>? fromJson(Map<String, dynamic>? json) {
    if (_unavailable<BackgroundExchange>(json, 'bg_exchange') case final a?) return a;
    if (!_usable(json, 'bg_exchange', 77)) return null;
    final j = json!;
    if (j['enabled'] != 1) return const BackgroundShopUnavailable();
    return BackgroundShopLoaded(
      BackgroundExchange._(
        uid: tsdmAppInt(j['uid']),
        campaigns: List.unmodifiable([
          for (final c in _list(j['campaigns']))
            if (_fieldValue.hasMatch(_str(c['id'])) && _str(c['id']).isNotEmpty)
              BackgroundCampaign._(
                id: _str(c['id']),
                minMedals: tsdmAppInt(c['min_medals']),
                days: tsdmAppInt(c['days']),
                medals: List.unmodifiable([
                  for (final m in _list(c['medals']))
                    (
                      id: tsdmAppInt(m['id']),
                      name: _str(m['name']),
                      imageUrl: apiImageUrl(m['image']),
                      owned: m['owned'] == 1,
                    ),
                ]),
                ownedMedals: tsdmAppInt(c['owned_medals']),
                exchanged: c['exchanged'] == 1,
                eligible: c['eligible'] == 1,
                backgrounds: List.unmodifiable([
                  for (final b in _list(c['backgrounds']))
                    if (tsdmAppInt(b['id']) > 0)
                      (
                        id: tsdmAppInt(b['id']),
                        name: _str(b['name']),
                        imageUrl: apiImageUrl(b['image']),
                        owned: b['owned'] == 1,
                      ),
                ]),
              ),
        ]),
        form: BackgroundExchangeForm._parse(j['form']),
      ),
    );
  }

  /// The account it was served to.
  final int uid;

  /// The exchanges, in the forum's order.
  final List<BackgroundCampaign> campaigns;

  /// The exchange form, null when the answer has none usable.
  final BackgroundExchangeForm? form;
}

ApiPaging _paging(Map<String, dynamic> json) {
  final page = tsdmAppInt(json['page']);
  final pages = tsdmAppInt(json['pages']);
  return (page: page < 1 ? 1 : page, pages: pages < 1 ? 1 : pages, total: tsdmAppInt(json['count']));
}

/// The background plugin off or too old for an answer of [type].
BackgroundShopAnswer<T>? _unavailable<T>(Map<String, dynamic>? json, String type) {
  if (json == null || json['ok'] != 1) return null;
  if (json['installed'] == 0) return BackgroundShopUnavailable<T>();
  if (json['installed'] == 1 && json['type'] == type && json['supported'] == 0) return BackgroundShopUnavailable<T>();
  return null;
}

bool _usable(Map<String, dynamic>? json, String type, int schema) =>
    apiInstalled(json) && json!['type'] == type && tsdmAppInt(json['schema']) >= schema && json['supported'] == 1;

/// The answer to one of the background plugin's forms sent with `tsdmapp=json&tsdmv=4`.
enum BackgroundShopWrite {
  /// The display form (`bgshop_style_saved`).
  style('bgshop_style_saved'),

  /// A purchase (`bgshop_bought`).
  buy('bgshop_bought'),

  /// A slot put in use (`bgshop_slot_set`).
  slot('bgshop_slot_set'),

  /// An exchange (`bgshop_exchanged`).
  exchange('bgshop_exchanged')
  ;

  const BackgroundShopWrite(this.successKey);

  /// The only `message_key` that is a success.
  final String successKey;
}

/// What a write of the shop came to.
sealed class BackgroundShopOutcome {
  const BackgroundShopOutcome();
}

/// Done.
final class BackgroundShopDone extends BackgroundShopOutcome {
  /// Constructor.
  const BackgroundShopDone();
}

/// The forum refused it: [key] is the plugin's `message_key` (maybe empty), [message] the background plugin's words.
final class BackgroundShopRefused extends BackgroundShopOutcome {
  /// Constructor.
  const BackgroundShopRefused({required this.key, required this.message, required this.login});

  /// The `message_key`.
  final String key;

  /// The forum's words (maybe a code such as `err_not_enough_medals`).
  final String message;

  /// The forum asks to log in.
  final bool login;
}

/// Nothing is known: the answer was not a write result (the forum's HTTP 503 page for a stale form hash, the page of
/// a plugin switched off, any other page, no answer at all), or the plugin could not tell the background plugin's
/// words (`bgshop_unknown`). The write may or may not have been done; it is never sent again by itself.
final class BackgroundShopUnknown extends BackgroundShopOutcome {
  /// Constructor.
  const BackgroundShopUnknown({this.answered = false});

  /// The plugin answered with a write result (`bgshop_unknown`); false for an answer that is not one.
  final bool answered;
}

/// The `message_key` of a write result whose words the plugin could not tell (plugin 4.1.0): not known to be done nor
/// refused.
const backgroundShopUnknownKey = 'bgshop_unknown';

/// The outcome of [write] from the answer [data] of a write sent for account [uid]; null when the answer was served
/// to another account.
BackgroundShopOutcome? backgroundShopOutcomeOf(Object? data, BackgroundShopWrite write, {required int uid}) {
  final result = tsdmAppWriteResultOf(data);
  if (result == null) return const BackgroundShopUnknown();
  if (result.uid != uid && !(result.uid == 0 && result.login)) return null;
  if (result.ok && !result.login && result.messageKey == write.successKey) return const BackgroundShopDone();
  if (!result.login && result.messageKey == backgroundShopUnknownKey) {
    return const BackgroundShopUnknown(answered: true);
  }
  return BackgroundShopRefused(key: result.messageKey, message: result.message, login: result.login);
}

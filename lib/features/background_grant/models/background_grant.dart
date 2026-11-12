import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/medal_title_tools/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// Sending backgrounds of the background shop plugin (`bggrant` of the forum's app API, plugin 3.9.0, `schema` 31):
/// the API gives the shop's catalogue and the plugin's own form (布景管理 → 发放仓库背景); the app posts that form to the
/// background plugin itself, which checks and does the work exactly as for a browser.

String _str(Object? v) => v == null ? '' : '$v'.trim();
List<Map<String, dynamic>> _list(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

final _fieldName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');

/// A background of the shop's catalogue.
final class BackgroundItem {
  /// Constructor.
  const BackgroundItem({required this.id, required this.name, required this.file, this.imageUrl});

  /// Id in the shop.
  final int id;

  /// Name.
  final String name;

  /// The value of the form's image field (`slotaddurl`).
  final String file;

  /// Preview.
  final String? imageUrl;
}

/// A shortcut of the expiry field, as the website's buttons.
final class BackgroundExpiryPreset {
  /// Constructor.
  const BackgroundExpiryPreset({required this.label, required this.days, required this.months});

  /// The forum's label.
  final String label;

  /// Days from today (`N天`), 0 when not by days.
  final int days;

  /// Months from today (a date), 0 when not by months.
  final int months;

  /// The value of the expiry field on [today]: `<days>天`, the date [months] months on (`YYYY-MM-DD`, the last day of
  /// a shorter month), or `0` (for good).
  String value(DateTime today) {
    if (days > 0) {
      return '$days天';
    }
    if (months > 0) {
      final total = today.month - 1 + months;
      final year = today.year + total ~/ 12;
      final month = total % 12 + 1;
      final last = DateTime(year, month + 1, 0).day;
      final day = today.day > last ? last : today.day;
      String two(int v) => v.toString().padLeft(2, '0');
      return '$year-${two(month)}-${two(day)}';
    }
    return '0';
  }
}

/// The background plugin's sending form as the API describes it.
final class BackgroundGrantForm {
  /// Constructor.
  const BackgroundGrantForm({
    required this.url,
    required this.fields,
    required this.urlField,
    required this.uidsField,
    required this.timeField,
    required this.notifyField,
    required this.successPrefix,
  });

  /// The form of [json]; null unless it posts to the background plugin's `memcp` page `ac=slotadd` of this forum with
  /// plain field names, so a tampered answer can never redirect a write or send other fields.
  static BackgroundGrantForm? parse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final fields = json['fields'];
    final raw = _str(json['url']);
    final uri = Uri.parse('$baseUrl/').resolve(raw);
    final names = [json['url_field'], json['uids_field'], json['time_field'], json['notify_field']].map(_str).toList();
    if (raw.isEmpty ||
        fields is! Map ||
        uri.origin != Uri.parse(baseUrl).origin ||
        uri.path != '/plugin.php' ||
        uri.queryParameters['id'] != 'background:memcp' ||
        uri.queryParameters['ac'] != 'slotadd' ||
        uri.queryParameters.keys.any((k) => k != 'id' && k != 'ac') ||
        names.any((n) => !_fieldName.hasMatch(n)) ||
        _str(json['success_prefix']).isEmpty) {
      return null;
    }
    return BackgroundGrantForm(
      url: uri.toString(),
      // The fields the app fills are never taken from the fixed ones: no notice means the field is not sent at all.
      fields: Map.unmodifiable({
        for (final e in fields.entries)
          if (!names.contains('${e.key}')) '${e.key}': '${e.value}',
      }),
      urlField: names[0],
      uidsField: names[1],
      timeField: names[2],
      notifyField: names[3],
      successPrefix: _str(json['success_prefix']),
    );
  }

  /// Absolute URL the form posts to.
  final String url;

  /// Fixed fields (form hash, submit flag).
  final Map<String, String> fields;

  /// The image (a file of the catalogue or a full image URL).
  final String urlField;

  /// The members, UIDs separated by commas.
  final String uidsField;

  /// The expiry.
  final String timeField;

  /// Notify the members (`1`); left out for no notice.
  final String notifyField;

  /// How the plugin's message of a sending done starts (`已发放给`).
  final String successPrefix;

  /// The body sending [image] to [uids] until [expiry], with a notice when [notify].
  Map<String, String> body({
    required String image,
    required List<int> uids,
    required String expiry,
    required bool notify,
  }) => {
    ...fields,
    urlField: image,
    uidsField: uids.join(','),
    timeField: expiry.isEmpty ? '0' : expiry,
    if (notify) notifyField: '1',
  };
}

/// The answer of `bggrant`.
final class BackgroundGrantInfo {
  /// Constructor.
  const BackgroundGrantInfo({
    required this.uid,
    required this.supported,
    required this.canGrant,
    required this.keyword,
    required this.paging,
    required this.items,
    required this.defaultExpiry,
    required this.presets,
    required this.maxUrl,
    this.form,
  });

  /// The answer [json], null when it is not usable (no answer, the background plugin missing or off).
  static BackgroundGrantInfo? fromJson(Map<String, dynamic>? json) {
    if (!apiInstalled(json) || json!['type'] != 'bggrant') {
      return null;
    }
    final expiry = json['expiry'];
    final limits = json['limits'];
    final page = tsdmAppInt(json['page']);
    final pages = tsdmAppInt(json['pages']);
    return BackgroundGrantInfo(
      uid: tsdmAppInt(json['uid']),
      supported: json['supported'] == 1,
      canGrant: json['can_grant'] == 1,
      keyword: _str(json['keyword']),
      paging: (page: page < 1 ? 1 : page, pages: pages < 1 ? 1 : pages, total: tsdmAppInt(json['count'])),
      items: [
        for (final b in _list(json['backgrounds']))
          if (_str(b['file']).isNotEmpty)
            BackgroundItem(
              id: tsdmAppInt(b['id']),
              name: _str(b['name']),
              file: _str(b['file']),
              imageUrl: apiImageUrl(b['image']),
            ),
      ],
      defaultExpiry: expiry is Map && _str(expiry['default']).isNotEmpty ? _str(expiry['default']) : '0',
      presets: [
        for (final p in _list(expiry is Map ? expiry['presets'] : null))
          BackgroundExpiryPreset(
            label: _str(p['label']),
            days: tsdmAppInt(p['days']).clamp(0, 36500),
            months: tsdmAppInt(p['months']).clamp(0, 1200),
          ),
      ],
      maxUrl: limits is Map && tsdmAppInt(limits['url']) > 0 ? tsdmAppInt(limits['url']) : 255,
      form: BackgroundGrantForm.parse(json['form']),
    );
  }

  /// The account the answer was served to.
  final int uid;

  /// The background plugin is new enough to send.
  final bool supported;

  /// The account may send backgrounds.
  final bool canGrant;

  /// The keyword the catalogue was filtered by.
  final String keyword;

  /// Paging of the catalogue (`total`: how many match).
  final ApiPaging paging;

  /// This page of the catalogue.
  final List<BackgroundItem> items;

  /// The expiry the form starts with.
  final String defaultExpiry;

  /// Shortcuts of the expiry.
  final List<BackgroundExpiryPreset> presets;

  /// Characters of the image field at most.
  final int maxUrl;

  /// The sending form, null when the answer has none usable.
  final BackgroundGrantForm? form;

  /// The page can send: allowed, supported and with a form.
  bool get usable => canGrant && supported && form != null;
}

/// What the background plugin answered to a sending: its message, and whether it is the one of a sending done.
typedef BackgroundGrantResult = ({bool success, String message});

/// The result of a sending from the plugin's [message]: done when it starts with [successPrefix] and, if a count
/// follows it, that count is above 0 (the plugin's messages carry no language key).
BackgroundGrantResult backgroundGrantResultOf(String message, String successPrefix) {
  final text = message.trim();
  if (successPrefix.isEmpty || !text.startsWith(successPrefix)) {
    return (success: false, message: text);
  }
  // Every UID unknown: the plugin still starts with the prefix (`已发放给 0 位会员…找不到的 UID 999999`). Nothing was
  // sent, so it is not a success; the message is shown as it is.
  final nobody = RegExp(r'^\s*0+(?!\d)').hasMatch(text.substring(successPrefix.length));
  return (success: !nobody, message: text);
}

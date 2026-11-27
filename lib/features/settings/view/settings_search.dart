import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/view/cross_device_sync_page.dart';
import 'package:tsdm_client/features/settings/view/notice_categories_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// One setting the search finds.
///
/// Either a row of the settings page as it is built now ([element]: its texts, its switch and what a tap on it does
/// are the row's own, so the search never differs from the page), or a row of one of its sub pages ([route]).
final class SettingsSearchEntry {
  /// Constructor.
  const SettingsSearchEntry({
    required this.id,
    required this.title,
    required this.group,
    this.subtitle,
    this.icon,
    this.keywords = '',
    this.element,
    this.route,
  });

  /// The key of the row (`settings-two-pane-layout`), or its group and title when it has none.
  final String id;

  /// Title of the row.
  final String title;

  /// Second line of the row, if any.
  final String? subtitle;

  /// Where the row is: the title of its group, with the sub page after it (`Account › Sync across devices`).
  final String group;

  /// Icon of the row.
  final IconData? icon;

  /// More words the row is found by, of the current language.
  final String keywords;

  /// The row on the settings page; null for a row of a sub page.
  final Element? element;

  /// Name of the sub page the row is on; null for a row of the settings page.
  final String? route;

  /// The row's switch while it is still on the page, null for any other row.
  SwitchListTile? get switchTile {
    final element = this.element;
    if (element == null || !element.mounted) {
      return null;
    }
    final widget = element.widget;
    return widget is SwitchListTile ? widget : null;
  }

  /// Whether every word of [query] is in the row's texts; false for an empty query.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (words.isEmpty) {
      return false;
    }
    final text = '$title ${subtitle ?? ''} $group $keywords'.toLowerCase();
    return words.every(text.contains);
  }
}

/// Every setting to search: the rows under [page] (the element of the settings page) as they are built now, then the
/// rows of the sub pages.
///
/// The rows of a platform or a state the page leaves out are not there to find; [noticeCategories] tells whether the
/// page of the notification categories is reachable.
List<SettingsSearchEntry> collectSettingsSearchEntries(
  Element page, {
  required Translations t,
  required SettingsMap settings,
  required bool noticeCategories,
}) {
  final keywords = t.settingsPage.search.keywords;
  final entries = <SettingsSearchEntry>[];
  final seen = <String>{};

  void add(SettingsSearchEntry entry) {
    if (entry.title.isNotEmpty && seen.add(entry.id)) {
      entries.add(entry);
    }
  }

  // The key of an expansion tile names its header, the list tile it builds first: taken by the next row read.
  String? headerId;

  void visit(Element element, String group) {
    final widget = element.widget;
    var inGroup = group;
    if (widget is AppTileGroup) {
      inGroup = widget.title ?? group;
    }
    if (widget is ExpansionTile) {
      final key = widget.key;
      headerId = key is ValueKey<String> ? key.value : null;
    }
    if (widget is ListTile || widget is SwitchListTile) {
      final hasSubtitle = switch (widget) {
        ListTile(:final subtitle) => subtitle != null,
        SwitchListTile(:final subtitle) => subtitle != null,
        _ => false,
      };
      // Leading, title, subtitle, trailing: the first text is the title, the second the subtitle when there is one.
      final texts = <String>[];
      IconData? icon;
      void read(Element child) {
        final w = child.widget;
        if (w is Text && w.data != null) {
          texts.add(w.data!);
        } else if (w is Icon) {
          icon ??= w.icon;
        }
        child.visitChildren(read);
      }

      element.visitChildren(read);
      final title = texts.firstOrNull ?? '';
      final key = widget.key;
      final id = key is ValueKey<String> ? key.value : headerId ?? '$inGroup/$title';
      headerId = null;
      add(
        SettingsSearchEntry(
          id: id,
          title: title,
          subtitle: hasSubtitle && texts.length > 1 ? texts[1] : null,
          group: inGroup,
          icon: icon,
          keywords: keywords[id] ?? '',
          element: element,
        ),
      );
      // A switch row is a list tile inside: one entry for it.
      return;
    }
    element.visitChildren((child) => visit(child, inGroup));
  }

  page.visitChildren((child) => visit(child, ''));

  final account = t.settingsPage.accountSection;
  final syncGroup = '${account.title} › ${account.crossDeviceSync.title}';
  for (final item in crossDeviceSyncItems(t, settings)) {
    final id = 'settings-${item.key.name}';
    add(
      SettingsSearchEntry(
        id: id,
        title: item.title,
        group: syncGroup,
        icon: item.icon,
        keywords: keywords[id] ?? '',
        route: ScreenPaths.settingsCrossDeviceSync.path,
      ),
    );
  }
  if (noticeCategories) {
    final behavior = t.settingsPage.behaviorSection;
    final tr = behavior.noticeCategories;
    final group = '${behavior.autoSyncNotice.title} › ${tr.title}';
    final route = ScreenPaths.settingsNoticeCategories.path;
    for (final item in noticeCategoryItems(t)) {
      final id = 'notice-category-${item.category.name}';
      add(
        SettingsSearchEntry(
          id: id,
          title: item.title,
          group: group,
          icon: item.icon,
          keywords: keywords[id] ?? '',
          route: route,
        ),
      );
    }
    for (final (id, icon, title) in [
      ('notice-followed-thread-interval', Icons.update_outlined, '${tr.followedThread} · ${tr.followedThreadInterval}'),
      ('notice-quiet-hours', Icons.bedtime_outlined, tr.quietHours),
    ]) {
      add(
        SettingsSearchEntry(
          id: id,
          title: title,
          group: group,
          icon: icon,
          keywords: keywords[id] ?? '',
          route: route,
        ),
      );
    }
  }
  return entries;
}

/// The search of the settings: the rows whose texts hold every word typed, as it is typed.
///
/// A switch is switched in the list. Any other row is given back to the settings page (the route is popped with the
/// [SettingsSearchEntry]), which opens the row's dialog or page from its own, still mounted, context.
class SettingsSearchPage extends StatefulWidget {
  /// Constructor.
  const SettingsSearchPage({required this.collect, super.key});

  /// The settings to search, read again after a setting changed (a switch shows or hides other rows).
  final List<SettingsSearchEntry> Function() collect;

  @override
  State<SettingsSearchPage> createState() => _SettingsSearchPageState();
}

class _SettingsSearchPageState extends State<SettingsSearchPage> {
  final _query = TextEditingController();
  late List<SettingsSearchEntry> _entries = widget.collect();

  /// The app lock keeps its switches in a cubit of its own: its changes are heard here too, they come after the tap
  /// (the PIN is asked first).
  StreamSubscription<void>? _appLockSub;

  @override
  void initState() {
    super.initState();
    if (getIt.isRegistered<AppLockCubit>()) {
      _appLockSub = getIt.get<AppLockCubit>().stream.listen((_) => _readAgain());
    }
  }

  @override
  void dispose() {
    unawaited(_appLockSub?.cancel());
    _query.dispose();
    super.dispose();
  }

  /// The settings page under this one builds with the new settings in this frame: its rows are read after it.
  void _readAgain() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) {
      setState(() => _entries = widget.collect());
    }
  });

  Widget _row(BuildContext context, SettingsSearchEntry entry) {
    final tile = entry.switchTile;
    final onChanged = tile?.onChanged;
    final subtitle = [if (entry.group.isNotEmpty) entry.group, ?entry.subtitle].join(' · ');
    if (tile != null) {
      return SwitchListTile(
        key: ValueKey('settings-search-result-${entry.id}'),
        secondary: Icon(entry.icon),
        title: Text(entry.title),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        value: tile.value,
        // The row's own handler: what the switch does on the page, it does here. Read again afterwards: not every
        // switch is a setting of the bloc (the app lock has a cubit of its own), and the listener only hears the bloc.
        onChanged: onChanged == null
            ? null
            : (v) {
                onChanged(v);
                _readAgain();
              },
      );
    }
    return ListTile(
      key: ValueKey('settings-search-result-${entry.id}'),
      leading: Icon(entry.icon),
      title: Text(entry.title),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      onTap: () => Navigator.of(context).pop(entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.search;
    final query = _query.text;
    final found = _entries.where((e) => e.matches(query)).toList();
    return BlocListener<SettingsBloc, SettingsState>(
      listener: (_, _) => _readAgain(),
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            key: const ValueKey('settings-search-field'),
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(hintText: tr.title, border: InputBorder.none),
            onChanged: (_) => setState(() {}),
          ),
          actions: [
            if (query.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.clear_outlined),
                tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                onPressed: () => setState(_query.clear),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: found.isEmpty
              ? (query.trim().isEmpty ? const SizedBox.shrink() : Center(child: Text(tr.empty)))
              : AppCenteredList(
                  maxWidth: appFormMaxWidth,
                  builder: (context, horizontal, _) => ListView.builder(
                    padding: horizontal,
                    itemCount: found.length,
                    itemBuilder: (context, index) => _row(context, found[index]),
                  ),
                ),
        ),
      ),
    );
  }
}

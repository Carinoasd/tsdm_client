import 'package:flutter/material.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';

/// A forum a search can be limited to: its id, its name, the group it is listed under and whether it is a subforum.
typedef SearchForumOption = ({int fid, String name, String group, bool sub});

final _fidRe = RegExp(r'[?&]fid=(\d+)');

/// The forums of the forum index [groups] a search can be limited to, in the order of the index: each forum with its
/// subforums after it (the forum matches the forums asked one by one, a forum does not bring its subforums along).
/// The favorites panel (the same forums again), link forums and forums seen only by name are left out.
List<SearchForumOption> searchForumOptions(List<ForumGroup> groups) {
  final seen = <int>{};
  final options = <SearchForumOption>[];
  for (final group in groups) {
    if (group.isFavorites) {
      continue;
    }
    for (final forum in group.forumList) {
      if (forum.forumID <= 0 || forum.redirectUrl != null || forum.isPrivate || !seen.add(forum.forumID)) {
        continue;
      }
      options.add((fid: forum.forumID, name: forum.name, group: group.name, sub: false));
      for (final (name, url) in forum.subForumList ?? const <(String, String)>[]) {
        final fid = int.tryParse(_fidRe.firstMatch(url)?.group(1) ?? '');
        if (fid != null && fid > 0 && seen.add(fid)) {
          options.add((fid: fid, name: name, group: group.name, sub: true));
        }
      }
    }
  }
  return options;
}

/// Let the user pick the forums of [options] to search in, [selected] picked at first: the forums picked (empty for
/// any forum), null when dismissed. A picked forum not in [options] (a forum page the search was opened from, missing
/// from the index) stays picked.
Future<Set<int>?> showSearchForumPicker(
  BuildContext context, {
  required List<SearchForumOption> options,
  required Set<int> selected,
}) => showDialog<Set<int>>(
  context: context,
  builder: (context) => _ForumPickerDialog(options: options, selected: selected),
);

class _ForumPickerDialog extends StatefulWidget {
  const _ForumPickerDialog({required this.options, required this.selected});

  final List<SearchForumOption> options;
  final Set<int> selected;

  @override
  State<_ForumPickerDialog> createState() => _ForumPickerDialogState();
}

class _ForumPickerDialogState extends State<_ForumPickerDialog> {
  late final Set<int> _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final tr = context.t.searchPage.filter;
    final materialL10n = MaterialLocalizations.of(context);
    final groupStyle = Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary);
    final known = {for (final e in widget.options) e.fid};
    final rows = <Widget>[];
    // Picked forums the index does not list (a forum page the search was opened from) come first, by id.
    var group = '';
    for (final option in [
      for (final fid in widget.selected.where((e) => !known.contains(e)).toList()..sort())
        (fid: fid, name: tr.forumId(fid: fid), group: '', sub: false),
      ...widget.options,
    ]) {
      if (option.group != group) {
        group = option.group;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
            child: Text(option.group, style: groupStyle),
          ),
        );
      }
      rows.add(
        CheckboxListTile(
          key: ValueKey('search-forum-${option.fid}'),
          dense: true,
          contentPadding: EdgeInsets.only(left: option.sub ? 40 : 16, right: 16),
          value: _picked.contains(option.fid),
          title: Text(context.displayText(option.name)),
          onChanged: (v) => setState(() {
            if (v ?? false) {
              _picked.add(option.fid);
            } else {
              _picked.remove(option.fid);
            }
          }),
        ),
      );
    }
    return AlertDialog(
      title: Text(tr.forum),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(shrinkWrap: true, children: rows),
      ),
      actions: [
        TextButton(
          onPressed: _picked.isEmpty ? null : () => setState(_picked.clear),
          child: Text(tr.clear),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(materialL10n.cancelButtonLabel)),
        FilledButton(onPressed: () => Navigator.of(context).pop({..._picked}), child: Text(materialL10n.okButtonLabel)),
      ],
    );
  }
}

/// The filters of a search as one row of chips: the forums (picked in a dialog, [onPickForums]), the time range, the
/// order and title only, each chip marked while it differs from the forum's default.
class SearchFilterBar extends StatelessWidget {
  /// Constructor.
  const SearchFilterBar({
    required this.filter,
    required this.fids,
    required this.forumNames,
    required this.onFilterChanged,
    required this.onPickForums,
    super.key,
  });

  /// The filters chosen.
  final SearchFilter filter;

  /// The forums picked, empty for any forum.
  final List<int> fids;

  /// Names of the forums known, by id.
  final Map<int, String> forumNames;

  /// A filter was changed.
  final ValueChanged<SearchFilter> onFilterChanged;

  /// The forum chip was tapped.
  final VoidCallback onPickForums;

  String _timeLabel(BuildContext context, SearchTimeRange range) {
    final tr = context.t.searchPage.filter.time;
    return switch (range) {
      SearchTimeRange.all => tr.all,
      SearchTimeRange.day => tr.day,
      SearchTimeRange.week => tr.week,
      SearchTimeRange.month => tr.month,
      SearchTimeRange.threeMonths => tr.threeMonths,
      SearchTimeRange.halfYear => tr.halfYear,
      SearchTimeRange.year => tr.year,
    };
  }

  String _orderLabel(BuildContext context, SearchOrderBy order) {
    final tr = context.t.searchPage.filter.order;
    return switch (order) {
      SearchOrderBy.lastpost => tr.lastpost,
      SearchOrderBy.dateline => tr.dateline,
      SearchOrderBy.replies => tr.replies,
      SearchOrderBy.views => tr.views,
    };
  }

  String _forumLabel(BuildContext context) {
    final tr = context.t.searchPage.filter;
    return switch (fids) {
      [] => tr.forum,
      [final fid] => forumNames[fid] ?? tr.forumId(fid: fid),
      _ => tr.forumCount(count: fids.length),
    };
  }

  /// A chip opening a menu of [items].
  Widget _menuChip({
    required Key key,
    required IconData icon,
    required String label,
    required bool marked,
    required List<Widget> items,
  }) => MenuAnchor(
    menuChildren: items,
    builder: (context, controller, _) => FilterChip(
      key: key,
      avatar: Icon(icon),
      label: Text(label),
      selected: marked,
      showCheckmark: false,
      onSelected: (_) => controller.isOpen ? controller.close() : controller.open(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tr = context.t.searchPage.filter;
    final order = tr.order;
    final check = Icon(Icons.check, size: 18, color: Theme.of(context).colorScheme.primary);
    const none = SizedBox(width: 18);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilterChip(
          key: const ValueKey('search-filter-forum'),
          avatar: const Icon(Icons.forum_outlined),
          label: Text(_forumLabel(context), maxLines: 1, overflow: TextOverflow.ellipsis),
          selected: fids.isNotEmpty,
          showCheckmark: false,
          onSelected: (_) => onPickForums(),
        ),
        _menuChip(
          key: const ValueKey('search-filter-time'),
          icon: Icons.schedule_outlined,
          label: _timeLabel(context, filter.timeRange),
          marked: filter.timeRange != SearchTimeRange.all,
          items: [
            for (final range in SearchTimeRange.values)
              MenuItemButton(
                leadingIcon: range == filter.timeRange ? check : none,
                onPressed: () => onFilterChanged(filter.copyWith(timeRange: range)),
                child: Text(_timeLabel(context, range)),
              ),
          ],
        ),
        _menuChip(
          key: const ValueKey('search-filter-order'),
          icon: filter.ascending ? Icons.arrow_upward : Icons.arrow_downward,
          label: _orderLabel(context, filter.orderBy),
          marked: filter.orderBy != SearchOrderBy.lastpost || filter.ascending,
          items: [
            for (final orderBy in SearchOrderBy.values)
              MenuItemButton(
                leadingIcon: orderBy == filter.orderBy ? check : none,
                onPressed: () => onFilterChanged(filter.copyWith(orderBy: orderBy)),
                child: Text(_orderLabel(context, orderBy)),
              ),
            const Divider(height: 8),
            for (final (ascending, label) in [(false, order.descending), (true, order.ascending)])
              MenuItemButton(
                leadingIcon: ascending == filter.ascending ? check : none,
                onPressed: () => onFilterChanged(filter.copyWith(ascending: ascending)),
                child: Text(label),
              ),
          ],
        ),
        FilterChip(
          key: const ValueKey('search-filter-title-only'),
          label: Text(tr.titleOnly),
          selected: filter.titleOnly,
          onSelected: (v) => onFilterChanged(filter.copyWith(titleOnly: v)),
        ),
      ],
    );
  }
}

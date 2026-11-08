import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/search/widgets/search_filter_bar.dart';
import 'package:tsdm_client/features/thread/v1/utils/immersive_forums.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';

/// Let the user pick the forums whose threads open in immersive reading, [initial] picked at first: the forums picked,
/// null when dismissed.
Future<ImmersiveForums?> showImmersiveForumsDialog(BuildContext context, ImmersiveForums initial) =>
    showDialog<ImmersiveForums>(
      context: context,
      builder: (_) => ImmersiveForumsDialog(initial: initial),
    );

/// The dialog of [showImmersiveForumsDialog]: a switch for every forum, then the forums of the forum index (the cached
/// homepage, fetched when there is none) to check, a forum with subforums offering to take them along once checked.
class ImmersiveForumsDialog extends StatefulWidget {
  /// Constructor.
  const ImmersiveForumsDialog({required this.initial, super.key});

  /// The forums picked at first.
  final ImmersiveForums initial;

  @override
  State<ImmersiveForumsDialog> createState() => _ImmersiveForumsDialogState();
}

class _ImmersiveForumsDialogState extends State<ImmersiveForumsDialog> {
  late ImmersiveForums _picked = widget.initial;
  List<SearchForumOption>? _options;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final repository = context.readOrNull<ForumHomeRepository>();
    final groups = repository == null
        ? const <ForumGroup>[]
        : (await repository.fetchHomePage().run()).fold(
            (_) => const <ForumGroup>[],
            (page) => switch (page) {
              ForumHomeWebPage(:final document) => buildGroupListFromDocument(document),
              ForumHomeApiPage(:final json) => forumGroupsFromApi(json),
            },
          );
    if (mounted) {
      setState(() => _options = searchForumOptions(groups));
    }
  }

  List<Widget> _rows(BuildContext context, List<SearchForumOption> options) {
    final tr = context.t.settingsPage.appearanceSection.immersiveReading;
    final groupStyle = Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary);
    final known = {for (final e in options) e.fid};
    final rows = <Widget>[];
    var group = '';
    // Forums picked that the index does not list come first, by id.
    for (final option in [
      for (final fid in {..._picked.exact, ..._picked.withSubforums}.where((e) => !known.contains(e)).toList()..sort())
        (fid: fid, name: tr.forumId(fid: fid), group: '', sub: false),
      ...options,
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
      final picked = _picked.picks(option.fid);
      final hasSubforums =
          !option.sub && (options.skipWhile((e) => e.fid != option.fid).skip(1).firstOrNull?.sub ?? false);
      rows.add(
        CheckboxListTile(
          key: ValueKey('immersive-forum-${option.fid}'),
          dense: true,
          contentPadding: EdgeInsets.only(left: option.sub ? 40 : 16, right: 16),
          value: picked,
          title: Text(option.name),
          onChanged: _picked.all
              ? null
              : (v) => setState(
                  () => _picked = _picked.withForum(
                    option.fid,
                    picked: v ?? false,
                    subforums: _picked.picksWithSubforums(option.fid),
                  ),
                ),
        ),
      );
      if (picked && hasSubforums) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                key: ValueKey('immersive-subforums-${option.fid}'),
                label: Text(tr.withSubforums),
                selected: _picked.picksWithSubforums(option.fid),
                onSelected: _picked.all
                    ? null
                    : (v) => setState(() => _picked = _picked.withForum(option.fid, picked: true, subforums: v)),
              ),
            ),
          ),
        );
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.immersiveReading;
    final materialL10n = MaterialLocalizations.of(context);
    final options = _options;
    return AlertDialog(
      title: Text(tr.title),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            SwitchListTile(
              key: const ValueKey('immersive-all-forums'),
              title: Text(tr.allForums),
              value: _picked.all,
              onChanged: (v) => setState(
                () => _picked = ImmersiveForums(all: v, exact: _picked.exact, withSubforums: _picked.withSubforums),
              ),
            ),
            const Divider(height: 1),
            if (options == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ..._rows(context, options),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(materialL10n.cancelButtonLabel)),
        FilledButton(onPressed: () => Navigator.of(context).pop(_picked), child: Text(materialL10n.okButtonLabel)),
      ],
    );
  }
}

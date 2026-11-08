import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/search/widgets/search_filter_bar.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The message of a failed filter change, null when there is nothing to say.
String? _failureText(BuildContext context, UserBlockResult result) {
  final tr = context.t.userBlock;
  return switch (result) {
    UserBlockResult.ok || UserBlockResult.notBlocked => null,
    UserBlockResult.alreadyBlocked => tr.filter.keywordExists,
    UserBlockResult.selfBlock || UserBlockResult.invalid => tr.invalid,
    UserBlockResult.accountChanged => tr.accountChanged,
    UserBlockResult.storageError => tr.storageError,
  };
}

/// Tell the failure of [result] in [context] when it is still mounted; with [quietWhenSame], nothing to change is no
/// failure.
void _report(BuildContext context, UserBlockResult result, {bool quietWhenSame = false}) {
  if (!context.mounted || (quietWhenSame && result == UserBlockResult.alreadyBlocked)) {
    return;
  }
  if (_failureText(context, result) case final message?) {
    showSnackBar(context: context, message: message);
  }
}

/// The keywords whose threads are hidden: added in a dialog, shown as chips to remove.
class ThreadKeywordFilterSection extends StatelessWidget {
  /// Constructor.
  const ThreadKeywordFilterSection({super.key});

  Future<void> _add(BuildContext context) async {
    final cubit = context.read<UserBlockCubit>();
    // The account is bound before the dialog opens: a choice made for one account is never applied to another one.
    final owner = cubit.owner;
    if (cubit.state.filters.keywords.length >= threadFilterMax) {
      showSnackBar(context: context, message: context.t.userBlock.filter.limitReached);
      return;
    }
    final text = await showDialog<String>(context: context, builder: (_) => const _KeywordDialog());
    if (text == null || text.trim().isEmpty || !context.mounted) {
      return;
    }
    final result = await cubit.addKeyword(text, expectedOwner: owner);
    if (context.mounted) {
      _report(context, result);
    }
  }

  Future<void> _remove(BuildContext context, String key) async {
    final cubit = context.read<UserBlockCubit>();
    final result = await cubit.removeKeyword(key, expectedOwner: cubit.owner);
    if (context.mounted) {
      _report(context, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock.filter;
    final (known, keywords) = context.select<UserBlockCubit, (bool, List<BlockedKeyword>)>(
      (c) => (c.state.status == UserBlockListStatus.ready && c.state.ownerUid != null, c.state.filters.keywords),
    );
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(
            tr.keywords,
            icon: Icons.title_outlined,
            padding: const EdgeInsets.only(bottom: 8),
            trailing: TextButton.icon(
              key: const ValueKey('thread-filter-keyword-add'),
              onPressed: known ? () async => _add(context) : null,
              icon: const Icon(Icons.add),
              label: Text(tr.add),
            ),
          ),
          if (keywords.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in keywords)
                  InputChip(
                    key: ValueKey('thread-filter-keyword-${k.key}'),
                    label: Text(k.text),
                    onDeleted: () async => _remove(context, k.key),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Asks for one keyword: the text entered, null when dismissed.
class _KeywordDialog extends StatefulWidget {
  const _KeywordDialog();

  @override
  State<_KeywordDialog> createState() => _KeywordDialogState();
}

class _KeywordDialogState extends State<_KeywordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock.filter;
    final materialL10n = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(tr.keywords),
      content: TextField(
        key: const ValueKey('thread-filter-keyword-field'),
        controller: _controller,
        autofocus: true,
        inputFormatters: [LengthLimitingTextInputFormatter(threadFilterKeywordMaxLength)],
        textInputAction: TextInputAction.done,
        onSubmitted: (text) => Navigator.of(context).pop(text),
        decoration: InputDecoration(labelText: tr.keyword),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(materialL10n.cancelButtonLabel)),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => FilledButton(
            key: const ValueKey('thread-filter-keyword-confirm'),
            onPressed: _controller.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_controller.text),
            child: Text(tr.add),
          ),
        ),
      ],
    );
  }
}

/// The forums whose threads are hidden in the lists of many forums: picked from the forum index, shown as chips.
class ThreadForumFilterSection extends StatefulWidget {
  /// Constructor.
  const ThreadForumFilterSection({super.key});

  @override
  State<ThreadForumFilterSection> createState() => _ThreadForumFilterSectionState();
}

class _ThreadForumFilterSectionState extends State<ThreadForumFilterSection> {
  List<SearchForumOption> _options = const [];
  bool _loading = false;

  /// The forums of the forum index (the cached homepage, fetched when there is none).
  Future<void> _loadOptions() async {
    final repository = context.readOrNull<ForumHomeRepository>();
    if (repository == null) {
      return;
    }
    final groups = (await repository.fetchHomePage().run()).fold(
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

  Future<void> _pick(List<BlockedForum> current) async {
    if (_loading) {
      return;
    }
    final cubit = context.read<UserBlockCubit>();
    // The account is bound before the picker opens: a choice made for one account is never applied to another one.
    final owner = cubit.owner;
    if (_options.isEmpty) {
      setState(() => _loading = true);
      await _loadOptions();
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
    }
    if (_options.isEmpty && current.isEmpty) {
      showSnackBar(context: context, message: context.t.general.failedToLoad);
      return;
    }
    final picked = await showSearchForumPicker(context, options: _options, selected: {for (final f in current) f.fid});
    if (picked == null || !mounted) {
      return;
    }
    // Only what the user changed in the picker: a forum another device added while it was open stays.
    final before = {for (final f in current) f.fid};
    if (picked.length > threadFilterMax) {
      showSnackBar(context: context, message: context.t.userBlock.filter.limitReached);
      return;
    }
    final names = {for (final o in _options) o.fid: o.name};
    final result = await cubit.changeForums(
      add: {
        for (final fid in picked.difference(before)) fid: names[fid] ?? '',
      },
      remove: before.difference(picked),
      expectedOwner: owner,
    );
    if (mounted) {
      _report(context, result, quietWhenSame: true);
    }
  }

  Future<void> _remove(int fid) async {
    final cubit = context.read<UserBlockCubit>();
    final result = await cubit.changeForums(remove: {fid}, expectedOwner: cubit.owner);
    if (mounted) {
      _report(context, result, quietWhenSame: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock.filter;
    final (known, forums) = context.select<UserBlockCubit, (bool, List<BlockedForum>)>(
      (c) => (c.state.status == UserBlockListStatus.ready && c.state.ownerUid != null, c.state.filters.forums),
    );
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(
            tr.forums,
            icon: Icons.forum_outlined,
            padding: const EdgeInsets.only(bottom: 8),
            trailing: TextButton.icon(
              key: const ValueKey('thread-filter-forum-pick'),
              onPressed: known && !_loading ? () async => _pick(forums) : null,
              icon: _loading
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.edit_outlined),
              label: Text(tr.pickForums),
            ),
          ),
          if (forums.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in forums)
                  InputChip(
                    key: ValueKey('thread-filter-forum-${f.fid}'),
                    label: Text(f.name.isEmpty ? context.t.searchPage.filter.forumId(fid: f.fid) : f.name),
                    onDeleted: () async => _remove(f.fid),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/forum_watch/cubit/forum_watch_cubit.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_state.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_check.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/search/widgets/search_filter_bar.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Tell the result [change] of a change of what the account watches in [context] when it is still mounted; nothing for
/// a change saved.
void showForumWatchChange(BuildContext context, ForumWatchChange change) {
  if (!context.mounted) {
    return;
  }
  final tr = context.t.forumWatch;
  final message = switch (change) {
    ForumWatchChange.ok => null,
    ForumWatchChange.exists => tr.keywordExists,
    ForumWatchChange.limitReached => tr.limitReached(forums: forumWatchForumMax, keywords: forumWatchKeywordMax),
    ForumWatchChange.noAccount => tr.needLogin,
  };
  if (message != null) {
    showSnackBar(context: context, message: message);
  }
}

/// The threads the watched forums and the alert keywords found ([ForumWatchCubit]), and what is watched: the forums
/// watched for new threads, the alert keywords, where they are looked for and how often.
class ForumWatchPage extends StatefulWidget {
  /// Constructor.
  const ForumWatchPage({super.key});

  @override
  State<ForumWatchPage> createState() => _ForumWatchPageState();
}

class _ForumWatchPageState extends State<ForumWatchPage> {
  @override
  void initState() {
    super.initState();
    // The background service may have found threads since the page was read.
    unawaited(context.read<ForumWatchCubit>().reload());
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.forumWatch;
    final state = context.watch<ForumWatchCubit>().state;
    final Widget alerts;
    final Widget settings;
    if (state.uid == null) {
      alerts = settings = AppStateView(icon: Icons.login_outlined, message: tr.needLogin);
    } else if (!state.loaded) {
      alerts = settings = const CenteredCircularIndicator();
    } else {
      alerts = _AlertList(alerts: state.alerts);
      settings = _WatchSettings(config: state.config, uid: state.uid!);
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.title),
          bottom: TabBar(
            tabs: [
              Tab(key: const ValueKey('forum-watch-tab-alerts'), text: tr.alerts),
              Tab(key: const ValueKey('forum-watch-tab-settings'), text: tr.settings),
            ],
          ),
        ),
        body: SafeArea(bottom: false, child: TabBarView(children: [alerts, settings])),
      ),
    );
  }
}

class _AlertList extends StatelessWidget {
  const _AlertList({required this.alerts});

  final List<WatchAlert> alerts;

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) {
      return AppStateView(icon: Icons.notifications_none_outlined, message: context.t.forumWatch.noAlerts);
    }
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: () => context.read<ForumWatchCubit>().reload(),
      child: AppCenteredList(
        builder: (context, side, _) => ListView.separated(
          padding: side.copyWith(top: 12, bottom: 12),
          itemCount: alerts.length,
          separatorBuilder: (_, _) => appListSeparator,
          itemBuilder: (context, index) {
            final a = alerts[index];
            final info = [a.forumName, a.author, a.at.elapsedTillNow(context)].where((e) => e.isNotEmpty).join(' · ');
            return AppSurface(
              key: ValueKey('forum-watch-alert-${a.tid}'),
              onTap: () async => context.dispatchAsUrl('$baseUrl/forum.php?mod=viewthread&tid=${a.tid}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (a.keywords.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final k in a.keywords)
                          Text(
                            k,
                            style: textTheme.labelMedium?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                      ],
                    ),
                    sizedBoxW4H4,
                  ],
                  Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.titleSmall),
                  sizedBoxW4H4,
                  Text(info, style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _WatchSettings extends StatelessWidget {
  const _WatchSettings({required this.config, required this.uid});

  final ForumWatchConfig config;
  final int uid;

  @override
  Widget build(BuildContext context) {
    return AppCenteredList(
      builder: (context, side, _) => ListView(
        padding: side.copyWith(top: 12, bottom: 12),
        children: [
          _ForumSection(config: config, uid: uid),
          sizedBoxW12H12,
          _KeywordSection(config: config, uid: uid),
          if (config.keywords.isNotEmpty) ...[sizedBoxW12H12, _ScopeSection(config: config, uid: uid)],
          sizedBoxW12H12,
          const _IntervalTile(),
        ],
      ),
    );
  }
}

/// `n/max`, how many of the forums the check may fetch it does.
class _ForumCount extends StatelessWidget {
  const _ForumCount(this.config);

  final ForumWatchConfig config;

  @override
  Widget build(BuildContext context) {
    final count = config.fetchedFids.length;
    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      '$count/$forumWatchForumMax',
      key: const ValueKey('forum-watch-forum-count'),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: count >= forumWatchForumMax ? colorScheme.error : colorScheme.outline,
      ),
    );
  }
}

class _ForumSection extends StatelessWidget {
  const _ForumSection({required this.config, required this.uid});

  final ForumWatchConfig config;
  final int uid;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.forumWatch;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(
            tr.forums,
            icon: Icons.forum_outlined,
            padding: const EdgeInsets.only(bottom: 8),
            trailing: _ForumCount(config),
          ),
          if (config.forums.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in config.forums)
                  InputChip(
                    key: ValueKey('forum-watch-forum-${f.fid}'),
                    label: Text(f.name.isEmpty ? context.t.searchPage.filter.forumId(fid: f.fid) : f.name),
                    onPressed: () async => context.dispatchAsUrl('$baseUrl/forum.php?mod=forumdisplay&fid=${f.fid}'),
                    onDeleted: () async {
                      final result = await context.read<ForumWatchCubit>().unwatchForum(f.fid, expectedUid: uid);
                      if (context.mounted) {
                        showForumWatchChange(context, result);
                      }
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _KeywordSection extends StatelessWidget {
  const _KeywordSection({required this.config, required this.uid});

  final ForumWatchConfig config;
  final int uid;

  Future<void> _add(BuildContext context) async {
    final cubit = context.read<ForumWatchCubit>();
    if (config.keywords.length >= forumWatchKeywordMax) {
      showForumWatchChange(context, ForumWatchChange.limitReached);
      return;
    }
    final text = await showDialog<String>(context: context, builder: (_) => const _KeywordDialog());
    if (text == null || text.trim().isEmpty || !context.mounted) {
      return;
    }
    final result = await cubit.addKeyword(text, expectedUid: uid);
    if (context.mounted) {
      showForumWatchChange(context, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.forumWatch;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(
            tr.keywords,
            icon: Icons.title_outlined,
            padding: const EdgeInsets.only(bottom: 8),
            trailing: TextButton.icon(
              key: const ValueKey('forum-watch-keyword-add'),
              onPressed: () async => _add(context),
              icon: const Icon(Icons.add),
              label: Text(tr.add),
            ),
          ),
          if (config.keywords.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in config.keywords)
                  InputChip(
                    key: ValueKey('forum-watch-keyword-${k.key}'),
                    label: Text(k.text),
                    onDeleted: () async {
                      final result = await context.read<ForumWatchCubit>().removeKeyword(k.key, expectedUid: uid);
                      if (context.mounted) {
                        showForumWatchChange(context, result);
                      }
                    },
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
    final tr = context.t.forumWatch;
    return AlertDialog(
      title: Text(tr.keywords),
      content: TextField(
        key: const ValueKey('forum-watch-keyword-field'),
        controller: _controller,
        autofocus: true,
        inputFormatters: [LengthLimitingTextInputFormatter(forumWatchKeywordMaxLength)],
        textInputAction: TextInputAction.done,
        onSubmitted: (text) => Navigator.of(context).pop(text),
        decoration: InputDecoration(labelText: tr.keyword),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => FilledButton(
            key: const ValueKey('forum-watch-keyword-confirm'),
            onPressed: _controller.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_controller.text),
            child: Text(tr.add),
          ),
        ),
      ],
    );
  }
}

class _ScopeSection extends StatefulWidget {
  const _ScopeSection({required this.config, required this.uid});

  final ForumWatchConfig config;
  final int uid;

  @override
  State<_ScopeSection> createState() => _ScopeSectionState();
}

class _ScopeSectionState extends State<_ScopeSection> {
  List<SearchForumOption> _options = const [];
  bool _loading = false;

  KeywordScope get _scope => widget.config.scope;

  Future<void> _set(KeywordScope scope) async {
    final result = await context.read<ForumWatchCubit>().setScope(scope, expectedUid: widget.uid);
    if (mounted) {
      showForumWatchChange(context, result);
    }
  }

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

  Future<void> _pick() async {
    if (_loading) {
      return;
    }
    if (_options.isEmpty) {
      setState(() => _loading = true);
      await _loadOptions();
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
    }
    if (_options.isEmpty && _scope.forums.isEmpty) {
      showSnackBar(context: context, message: context.t.general.failedToLoad);
      return;
    }
    final picked = await showSearchForumPicker(
      context,
      options: _options,
      selected: {for (final f in _scope.forums) f.fid},
    );
    if (picked == null || !mounted) {
      return;
    }
    final names = {for (final o in _options) o.fid: o.name};
    final kept = {for (final f in _scope.forums) f.fid: f};
    final now = DateTime.now().millisecondsSinceEpoch;
    await _set(
      _scope.copyWith(
        forums: [
          for (final fid in picked) kept[fid] ?? WatchedForum(fid: fid, name: names[fid] ?? '', updated: now),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.forumWatch;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(
            tr.scope,
            icon: Icons.manage_search_outlined,
            padding: const EdgeInsets.only(bottom: 8),
            trailing: _scope.custom ? _ForumCount(widget.config) : null,
          ),
          SegmentedButton<bool>(
            key: const ValueKey('forum-watch-scope'),
            segments: [
              ButtonSegment(value: false, label: Text(tr.scopeDefault)),
              ButtonSegment(value: true, label: Text(tr.scopeCustom)),
            ],
            selected: {_scope.custom},
            showSelectedIcon: false,
            onSelectionChanged: (v) async => _set(_scope.copyWith(custom: v.first)),
          ),
          if (_scope.custom) ...[
            SwitchListTile(
              key: const ValueKey('forum-watch-scope-latest'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr.latest),
              value: _scope.latest,
              onChanged: (v) async => _set(_scope.copyWith(latest: v)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final f in _scope.forums)
                  InputChip(
                    key: ValueKey('forum-watch-scope-forum-${f.fid}'),
                    label: Text(f.name.isEmpty ? context.t.searchPage.filter.forumId(fid: f.fid) : f.name),
                    onDeleted: () async =>
                        _set(_scope.copyWith(forums: [..._scope.forums.where((e) => e.fid != f.fid)])),
                  ),
                TextButton.icon(
                  key: const ValueKey('forum-watch-scope-pick'),
                  onPressed: _loading ? null : _pick,
                  icon: _loading
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.edit_outlined),
                  label: Text(tr.pickForums),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _IntervalTile extends StatelessWidget {
  const _IntervalTile();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.forumWatch;
    final minutes = context.select<SettingsBloc, int>((b) => b.state.settingsMap.forumWatchCheckMinutes);
    return AppSurface(
      padding: EdgeInsets.zero,
      child: ListTile(
        key: const ValueKey('forum-watch-interval'),
        leading: const Icon(Icons.update_outlined),
        title: Text(tr.interval),
        trailing: Text(tr.minutes(n: minutes)),
        onTap: () async {
          final picked = await showDialog<int>(
            context: context,
            builder: (context) => SimpleDialog(
              title: Text(tr.interval),
              children: [
                for (final m in forumWatchCheckChoices)
                  SimpleDialogOption(
                    key: ValueKey('forum-watch-interval-$m'),
                    onPressed: () => Navigator.of(context).pop(m),
                    child: Row(
                      children: [
                        Expanded(child: Text(tr.minutes(n: m))),
                        if (m == minutes) Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
                      ],
                    ),
                  ),
              ],
            ),
          );
          if (picked != null) {
            await getIt.get<SettingsRepository>().setValue(SettingsKeys.forumWatchCheckMinutes, picked);
          }
        },
      ),
    );
  }
}

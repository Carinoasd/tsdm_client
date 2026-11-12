import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_pages_widgets.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The panel's post management (`modcp_post`): search the posts of the account's forums (one, or all of them) by
/// author, words, IP and time, each opening its floor; those picked deleted together when the account may.
///
/// The panel keeps the results in its session: after the password was asked again the search is run again.
class ModcpPostsPage extends StatefulWidget {
  /// Constructor.
  const ModcpPostsPage({required this.repository, super.key});

  /// The panel's pages.
  final ModcpPagesRepository repository;

  @override
  State<ModcpPostsPage> createState() => _ModcpPostsPageState();
}

class _ModcpPostsPageState extends State<ModcpPostsPage> {
  bool _loading = true;
  bool _busy = false;
  Either<AppException, ModcpAnswer<ModcpPostPage>>? _answer;

  /// The forum searched, 0 for all the account's.
  int _fid = 0;

  /// The forum and the conditions searched last, null before a search.
  ({int fid, Map<String, String> conditions})? _searched;

  /// The page read last: its search form is what is asked again once the panel's password was given.
  ModcpPostPage? _last;

  final _users = TextEditingController();
  final _keywords = TextEditingController();
  final _ip = TextEditingController();
  String _option = '0';
  String _start = '';
  String _end = '';

  /// The fields were filled from an answer.
  bool _filled = false;

  final _picked = <int>{};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_ask(() => widget.repository.fetchPosts().run()));
  }

  @override
  void dispose() {
    _users.dispose();
    _keywords.dispose();
    _ip.dispose();
    super.dispose();
  }

  ModcpPostPage? get _shown => switch (_answer) {
    Right(value: ModcpReady(:final value)) => value,
    _ => null,
  };

  Future<void> _ask(Future<Either<AppException, ModcpAnswer<ModcpPostPage>>> Function() request) async {
    final generation = ++_generation;
    setState(() => _loading = true);
    final answer = await request();
    if (!mounted || generation != _generation) {
      return;
    }
    final isPage = switch (answer) {
      Right(value: ModcpReady() || ModcpNeedsLogin()) => true,
      _ => false,
    };
    if (!isPage && _shown != null) {
      setState(() => _loading = false);
      showModcpLoadFailure(context, answer);
      return;
    }
    _show(answer);
  }

  void _show(Either<AppException, ModcpAnswer<ModcpPostPage>> answer) => setState(() {
    _loading = false;
    _answer = answer;
    if (answer case Right(value: ModcpReady(:final value))) {
      _last = value;
      final listed = {for (final p in value.posts) p.pid};
      _picked.retainWhere(listed.contains);
      if (!_filled) {
        _filled = true;
        _option = value.filters[ModcpPostQuery.threadOption]?.isNotEmpty ?? false
            ? value.filters[ModcpPostQuery.threadOption]!
            : '0';
        _start = value.filters[ModcpPostQuery.startTime] ?? '';
        _end = value.filters[ModcpPostQuery.endTime] ?? '';
      }
    }
  });

  Map<String, String> _conditions(ModcpPostPage shown) => {
    ModcpPostQuery.threadOption: _option,
    ModcpPostQuery.users: _users.text.trim(),
    ModcpPostQuery.keywords: _keywords.text.trim(),
    ModcpPostQuery.useIp: _ip.text.trim(),
    ModcpPostQuery.startTime: _start,
    if (!shown.limits.endTimeFixed) ModcpPostQuery.endTime: _end,
  };

  Future<void> _search(ModcpPostPage shown) async {
    final conditions = _conditions(shown);
    if (!ModcpPostQuery.hasCondition(conditions)) {
      showSnackBar(context: context, message: context.t.modcpPages.errorCondition);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(_picked.clear);
    final fid = _fid;
    _searched = (fid: fid, conditions: {...conditions});
    await _ask(() => widget.repository.searchPosts(shown, fid, conditions).run());
  }

  /// What was shown last, asked again: the search run again as it was sent (the panel's session may have lost it, or
  /// asked its password meanwhile).
  Future<void> _reload() async {
    final last = _last;
    final searched = _searched;
    if (last != null && searched != null) {
      return _ask(() => widget.repository.searchPosts(last, searched.fid, searched.conditions).run());
    }
    return _ask(() => widget.repository.fetchPosts(fid: searched?.fid ?? 0).run());
  }

  Future<void> _delete(ModcpPostPage shown) async {
    final pids = [
      for (final p in shown.posts)
        if (_picked.contains(p.pid)) p.pid,
    ];
    if (pids.isEmpty || _busy) {
      return;
    }
    final tr = context.t.modcpPages;
    var keepCredits = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(tr.deletePosts),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.t.modcp.selected(count: pids.length)),
              CheckboxListTile(
                key: const ValueKey('modcp-posts-keep-credits'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: keepCredits,
                title: Text(tr.keepCredits),
                onChanged: (v) => setDialogState(() => keepCredits = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.general.cancel)),
            FilledButton(
              key: const ValueKey('modcp-posts-delete-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.t.modcp.delete),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final outcome = await widget.repository.deletePosts(shown, pids, keepCredits: keepCredits).run();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    final posted = outcome.toNullable();
    showSnackBar(
      context: context,
      message: modcpPagesOutcomeText(
        context,
        outcome.map((e) => e.outcome),
        done: tr.postsDeleted(count: pids.length),
        refused: posted?.page?.error == ModcpPostError.noperm ? tr.errorNoPerm : null,
      ),
    );
    if (outcome case Right(value: (outcome: ModcpWriteDone(), page: _))) {
      setState(_picked.clear);
    }
    if (posted?.page case final page?) {
      _generation++;
      _show(Right(ModcpReady(page)));
    } else {
      await _reload();
    }
  }

  String? _errorText(ModcpPostPage page) {
    final tr = context.t.modcpPages;
    return switch (page.error) {
      ModcpPostError.none => null,
      ModcpPostError.condition => tr.errorCondition,
      ModcpPostError.range => tr.errorRange(days: page.limits.days),
      ModcpPostError.keyword => tr.errorKeyword(bytes: page.limits.keywordMinBytes),
      ModcpPostError.noperm => tr.errorNoPerm,
      ModcpPostError.unknown => context.t.moderate.failed,
    };
  }

  Widget _form(ModcpPostPage shown) {
    final tr = context.t.modcpPages;
    final options = shown.threadOptions.isEmpty ? [(value: '0', label: tr.scope)] : shown.threadOptions;
    final forums = [ModcpForum(fid: 0, name: tr.allForums), ...shown.forums];
    final error = _errorText(shown);
    return AppSurface(
      key: const ValueKey('modcp-posts-form'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: const ValueKey('modcp-posts-forum'),
                  initialValue: forums.any((f) => f.fid == _fid) ? _fid : 0,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: context.t.modcp.switchForum),
                  items: [
                    for (final f in forums)
                      DropdownMenuItem(
                        value: f.fid,
                        child: Text(context.displayText(f.name), overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _fid = v ?? 0),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('modcp-posts-option'),
                  initialValue: options.any((o) => o.value == _option) ? _option : options.first.value,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: tr.scope),
                  items: [
                    for (final o in options)
                      DropdownMenuItem(value: o.value, child: Text(context.displayText(o.label))),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _option = v ?? '0'),
                ),
              ),
            ],
          ),
          TextField(
            key: const ValueKey('modcp-posts-users'),
            controller: _users,
            decoration: InputDecoration(labelText: tr.authors),
          ),
          TextField(
            key: const ValueKey('modcp-posts-keywords'),
            controller: _keywords,
            decoration: InputDecoration(labelText: context.t.modcp.keyword),
          ),
          TextField(
            key: const ValueKey('modcp-posts-ip'),
            controller: _ip,
            decoration: InputDecoration(labelText: context.t.modcp.ip),
          ),
          Row(
            children: [
              Expanded(
                child: ModcpDateField(
                  key: const ValueKey('modcp-posts-starttime'),
                  label: context.t.modcp.startDate,
                  value: _start,
                  onChanged: (v) => setState(() => _start = v),
                ),
              ),
              if (!shown.limits.endTimeFixed) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: ModcpDateField(
                    key: const ValueKey('modcp-posts-endtime'),
                    label: context.t.modcp.endDate,
                    value: _end,
                    onChanged: (v) => setState(() => _end = v),
                  ),
                ),
              ],
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error,
                key: const ValueKey('modcp-posts-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey('modcp-posts-search'),
              icon: const Icon(Icons.search),
              label: Text(context.t.modcp.search),
              onPressed: _loading || _busy || shown.search == null ? null : () => _search(shown),
            ),
          ),
        ],
      ),
    );
  }

  Widget _post(ModcpPostPage shown, ModcpPostRow post) {
    final theme = Theme.of(context);
    final tr = context.t.modcpPages;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.displayText(post.subject),
          style: theme.textTheme.titleSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (post.message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(post.message, maxLines: 4, overflow: TextOverflow.ellipsis),
          ),
        const SizedBox(height: 4),
        modcpMutedLine(context, [
          post.author,
          if (post.dateline > 0) toolsDateTime(post.dateline),
          if (post.fid != shown.fid) context.displayText(post.forum),
          if (post.first) tr.firstPost,
          if (post.pending) tr.pending,
        ]),
      ],
    );
    void open() => unawaited(
      context.pushNamed(
        ScreenPaths.threadV1,
        queryParameters: {'pid': '${post.pid}', 'overrideReverseOrder': 'false'},
      ),
    );
    if (!shown.canDelete) {
      return Card(
        key: ValueKey('modcp-post-${post.pid}'),
        margin: EdgeInsets.zero,
        shape: appSurfaceShape(context),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: open,
          child: Padding(padding: const EdgeInsets.all(16), child: content),
        ),
      );
    }
    return ModcpPickCard(
      key: ValueKey('modcp-post-${post.pid}'),
      picked: _picked.contains(post.pid),
      onChanged: _busy ? null : (picked) => setState(() => picked ? _picked.add(post.pid) : _picked.remove(post.pid)),
      onTap: open,
      child: content,
    );
  }

  Widget _page(ModcpPostPage shown) {
    final pids = [for (final p in shown.posts) p.pid];
    final allPicked = pids.isNotEmpty && pids.every(_picked.contains);
    final searched = shown.isSearch;
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: AppCenteredList(
            builder: (context, padding, _) => ListView.separated(
              padding: padding.copyWith(top: 8, bottom: 8),
              itemCount: 1 + (searched ? (shown.posts.isEmpty ? 1 : shown.posts.length + 1) : 0),
              separatorBuilder: (_, _) => appListSeparator,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _form(shown);
                }
                if (shown.posts.isEmpty) {
                  return AppStateView(
                    icon: Icons.article_outlined,
                    message: context.t.modcpPages.postsEmpty,
                    scrollable: false,
                  );
                }
                if (index == shown.posts.length + 1) {
                  return ToolsPager(
                    paging: (page: shown.page, pages: shown.pages, total: shown.count),
                    enabled: !_loading && !_busy,
                    onPage: (page) {
                      setState(_picked.clear);
                      unawaited(_ask(() => widget.repository.fetchPostResults(shown, page).run()));
                    },
                  );
                }
                return _post(shown, shown.posts[index - 1]);
              },
            ),
          ),
        ),
        if (shown.canDelete && searched && shown.posts.isNotEmpty)
          ModcpPickBar(
            picked: _picked.length,
            allPicked: allPicked,
            sending: _busy,
            onPickAll: _busy ? null : () => setState(() => allPicked ? _picked.clear() : _picked.addAll(pids)),
            actions: [
              TextButton(
                key: const ValueKey('modcp-posts-delete'),
                onPressed: _picked.isEmpty || _busy ? null : () => _delete(shown),
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                child: Text(context.t.modcp.delete),
              ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.t.modcpPages.posts)),
    body: ModcpAnswerView<ModcpPostPage>(
      repository: widget.repository.panel,
      loading: _loading && _shown == null,
      answer: _answer,
      onReload: _reload,
      builder: (context, page) => _page(page),
    ),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_pages_widgets.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The panel's thread management (`modcp_thread`): the threads of a forum the account moderates (chosen first, the
/// only one right away), searched by the panel's conditions, each opening its thread; those picked managed together
/// with the forum page's sheet (the operations the answer's `perms` allow).
///
/// The results of a search are kept in the panel's session: after the password was asked again the search is run
/// again rather than its pages read.
class ModcpThreadsPage extends StatefulWidget {
  /// Constructor.
  const ModcpThreadsPage({required this.repository, this.moderateRepository, super.key});

  /// The panel's pages.
  final ModcpPagesRepository repository;

  /// The management of the threads picked; the app's client when null.
  final ModerateRepository? moderateRepository;

  @override
  State<ModcpThreadsPage> createState() => _ModcpThreadsPageState();
}

class _ModcpThreadsPageState extends State<ModcpThreadsPage> {
  bool _loading = true;
  Either<AppException, ModcpAnswer<ModcpThreadPage>>? _answer;
  int _fid = 0;
  int _page = 1;

  /// The conditions searched, null when the forum's threads are listed.
  Map<String, String>? _conditions;

  /// The forums the panel offered, last read.
  List<ModcpForum> _forums = const [];

  /// A forum was chosen by hand: the only one is not chosen again without asking.
  bool _picking = false;

  /// The page read last: what is asked again once the panel's password was given.
  ModcpThreadPage? _last;

  final _picked = <int>{};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open(0));
  }

  ModcpThreadPage? get _shown => switch (_answer) {
    Right(value: ModcpReady(:final value)) => value,
    _ => null,
  };

  /// Ask [request] and show its answer; [accept] tells whether a page read is the one asked (a search answered with
  /// the whole forum is not its results). [searching] are the conditions asked: kept once its results are shown, or
  /// when the panel asks its password first (run again once logged in).
  Future<void> _ask(
    Future<Either<AppException, ModcpAnswer<ModcpThreadPage>>> Function() request, {
    bool Function(ModcpThreadPage page)? accept,
    VoidCallback? onRejected,
    Map<String, String>? searching,
    ({int fid, int page})? opening,
  }) async {
    final generation = ++_generation;
    setState(() => _loading = true);
    final answer = await request();
    if (!mounted || generation != _generation) {
      return;
    }
    if (answer case Right(value: ModcpReady(:final value)) when accept != null && !accept(value)) {
      setState(() => _loading = false);
      onRejected?.call();
      return;
    }
    final isPage = switch (answer) {
      Right(value: ModcpReady() || ModcpNeedsLogin()) => true,
      _ => false,
    };
    if (!isPage && _shown != null) {
      // Keep the list shown: the failure is told beside it.
      setState(() => _loading = false);
      showModcpLoadFailure(context, answer);
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
      switch (answer) {
        case Right(value: ModcpReady(:final value)):
          _last = value;
          if (value.forums.isNotEmpty) _forums = value.forums;
          _fid = value.fid;
          _page = value.page;
          final listed = {for (final t in value.threads) t.tid};
          _picked.retainWhere(listed.contains);
          _conditions = value.isSearch ? (searching ?? _conditions) : null;
        case Right(value: ModcpNeedsLogin()) when searching != null:
          _conditions = searching;
        case Right(value: ModcpNeedsLogin()) when opening != null:
          // What was asked is asked again once logged in.
          _conditions = null;
          _fid = opening.fid;
          _page = opening.page;
        default:
          break;
      }
    });
    if (answer case Right(
      value: ModcpReady(value: ModcpThreadPage(needForum: true, :final forums)),
    ) when forums.length == 1 && !_picking) {
      await _open(forums.single.fid);
    }
  }

  /// The threads of forum [fid], page [page].
  Future<void> _open(int fid, {int page = 1}) => _ask(
    () => widget.repository.fetchThreads(fid: fid, page: page).run(),
    opening: (fid: fid, page: page),
  );

  /// What was shown last, asked again: the search run again (the panel's session may have lost it, or asked its
  /// password meanwhile), or the forum's page.
  Future<void> _reload() async {
    final conditions = _conditions;
    final last = _last;
    if (conditions != null && last != null && !last.needForum) {
      return _search(last, conditions);
    }
    return _ask(() => widget.repository.fetchThreads(fid: _fid, page: _page).run());
  }

  Future<void> _search(ModcpThreadPage shown, Map<String, String> conditions) => _ask(
    () => widget.repository.searchThreads(shown, conditions).run(),
    accept: (page) => page.isSearch,
    onRejected: () => showSnackBar(context: context, message: context.t.modcpPages.needCondition),
    searching: conditions,
  );

  Future<void> _goTo(ModcpThreadPage shown, int page) {
    if (shown.isSearch) {
      return _ask(
        () => widget.repository.fetchThreadResults(shown, page).run(),
        accept: (p) => p.isSearch,
        onRejected: () => showSnackBar(context: context, message: context.t.general.failedToLoad),
      );
    }
    return _open(shown.fid, page: page);
  }

  Future<void> _switchForum(ModcpThreadPage shown) async {
    final picked = await showModcpForumSwitch(context, _forums, shown.fid);
    if (picked != null && mounted && picked.fid != shown.fid) {
      setState(_picked.clear);
      await _open(picked.fid);
    }
  }

  Future<void> _openSearch(ModcpThreadPage shown) async {
    final conditions = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ThreadSearchSheet(page: shown, initial: _conditions ?? const {}),
    );
    if (conditions == null || !mounted) {
      return;
    }
    if (!ModcpThreadQuery.hasCondition(conditions)) {
      showSnackBar(context: context, message: context.t.modcpPages.needCondition);
      return;
    }
    setState(_picked.clear);
    await _search(shown, conditions);
  }

  Future<void> _moderate(ModcpThreadPage shown) async {
    final threads = [
      for (final t in shown.threads)
        if (_picked.contains(t.tid)) ('${t.tid}', t.subject),
    ];
    if (threads.isEmpty) {
      return;
    }
    // The sheet and its window are modal: nothing else is tapped meanwhile.
    final report = await showBatchModerateSheet(
      context,
      threads: threads,
      fid: shown.fid,
      perms: shown.perms,
      repository: widget.moderateRepository,
    );
    if (report == null || !mounted) {
      return;
    }
    setState(_picked.clear);
    await _reload();
  }

  Widget _thread(ModcpThreadPage shown, ModcpThreadRow thread) {
    final theme = Theme.of(context);
    final tr = context.t.moderate;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              for (final (show, icon, tip) in [
                (thread.displayOrder > 0, Icons.vertical_align_top_outlined, tr.stick),
                (thread.digest > 0, Icons.star_outline, tr.digest),
                (thread.closed, Icons.lock_outline, tr.close),
              ])
                if (show)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(icon, size: 16, color: theme.colorScheme.primary, semanticLabel: tip),
                    ),
                  ),
              TextSpan(text: context.displayText(thread.subject)),
            ],
          ),
          style: theme.textTheme.titleSmall,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        modcpMutedLine(context, [
          thread.author,
          if (thread.dateline > 0) toolsDateTime(thread.dateline),
          '${thread.replies}/${thread.views}',
        ]),
      ],
    );
    void open() => unawaited(context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '${thread.tid}'}));
    if (!shown.canModerate) {
      return Card(
        key: ValueKey('modcp-thread-${thread.tid}'),
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
      key: ValueKey('modcp-thread-${thread.tid}'),
      picked: _picked.contains(thread.tid),
      onChanged: (picked) => setState(() => picked ? _picked.add(thread.tid) : _picked.remove(thread.tid)),
      onTap: open,
      child: content,
    );
  }

  Widget _list(ModcpThreadPage shown) {
    if (shown.needForum) {
      return ModcpForumList(
        forums: shown.forums,
        onPick: (forum) {
          _picking = true;
          unawaited(_open(forum.fid));
        },
      );
    }
    final tids = [for (final t in shown.threads) t.tid];
    final allPicked = tids.isNotEmpty && tids.every(_picked.contains);
    final list = shown.threads.isEmpty
        ? RefreshIndicator(
            onRefresh: _reload,
            child: AppScrollableStateView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: AppStateView(
                icon: Icons.topic_outlined,
                message: context.t.modcpPages.threadsEmpty,
                scrollable: false,
              ),
            ),
          )
        : RefreshIndicator(
            onRefresh: _reload,
            child: AppCenteredList(
              builder: (context, padding, _) => ListView.separated(
                padding: padding.copyWith(top: 8, bottom: 8),
                itemCount: shown.threads.length + 1,
                separatorBuilder: (_, _) => appListSeparator,
                itemBuilder: (context, index) => index == shown.threads.length
                    ? ToolsPager(
                        paging: (page: shown.page, pages: shown.pages, total: shown.count),
                        enabled: !_loading,
                        onPage: (page) {
                          setState(_picked.clear);
                          unawaited(_goTo(shown, page));
                        },
                      )
                    : _thread(shown, shown.threads[index]),
              ),
            ),
          );
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(),
        Expanded(child: list),
        if (shown.canModerate && shown.threads.isNotEmpty)
          ModcpPickBar(
            picked: _picked.length,
            allPicked: allPicked,
            sending: false,
            onPickAll: () => setState(() => allPicked ? _picked.clear() : _picked.addAll(tids)),
            actions: [
              FilledButton.tonal(
                key: const ValueKey('modcp-threads-moderate'),
                onPressed: _picked.isEmpty ? null : () => _moderate(shown),
                child: Text(context.t.moderate.menu),
              ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcpPages;
    final shown = _shown;
    final forumShown = shown != null && !shown.needForum;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          forumShown && shown.forumName.isNotEmpty
              ? '${tr.threads} · ${context.displayText(shown.forumName)}'
              : tr.threads,
        ),
        actions: [
          if (forumShown && _conditions != null)
            IconButton(
              key: const ValueKey('modcp-threads-clear-search'),
              tooltip: tr.allThreads,
              icon: const Icon(Icons.filter_alt_off_outlined),
              onPressed: _loading ? null : () => _open(shown.fid),
            ),
          if (forumShown && shown.search != null)
            IconButton(
              key: const ValueKey('modcp-threads-search'),
              tooltip: context.t.modcp.search,
              icon: const Icon(Icons.search),
              onPressed: _loading ? null : () => _openSearch(shown),
            ),
          if (forumShown && _forums.length > 1)
            IconButton(
              key: const ValueKey('modcp-switch-forum'),
              tooltip: context.t.modcp.switchForum,
              icon: const Icon(Icons.swap_horiz),
              onPressed: _loading ? null : () => _switchForum(shown),
            ),
        ],
      ),
      body: ModcpAnswerView<ModcpThreadPage>(
        repository: widget.repository.panel,
        loading: _loading && shown == null,
        answer: _answer,
        onReload: _reload,
        builder: (context, page) => _list(page),
      ),
    );
  }
}

/// The search of the thread management: the panel's conditions, those of the search shown filled in.
class _ThreadSearchSheet extends StatefulWidget {
  const _ThreadSearchSheet({required this.page, required this.initial});

  final ModcpThreadPage page;
  final Map<String, String> initial;

  @override
  State<_ThreadSearchSheet> createState() => _ThreadSearchSheetState();
}

class _ThreadSearchSheetState extends State<_ThreadSearchSheet> {
  static const List<String> _texts = [ModcpThreadQuery.users, ModcpThreadQuery.keywords];
  static const List<String> _numbers = [
    ModcpThreadQuery.viewsMore,
    ModcpThreadQuery.viewsLess,
    ModcpThreadQuery.repliesMore,
    ModcpThreadQuery.repliesLess,
    ModcpThreadQuery.noReplyDays,
  ];

  late final Map<String, TextEditingController> _fields = {
    for (final k in [..._texts, ..._numbers]) k: TextEditingController(text: widget.initial[k] ?? ''),
  };
  late String _option = widget.initial[ModcpThreadQuery.threadOption] ?? '0';
  late String _type = widget.initial[ModcpThreadQuery.typeId] ?? '';
  late String _start = widget.initial[ModcpThreadQuery.startTime] ?? '';
  late String _end = widget.initial[ModcpThreadQuery.endTime] ?? '';

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _label(String key) {
    final tr = context.t.modcpPages;
    return switch (key) {
      ModcpThreadQuery.users => tr.authors,
      ModcpThreadQuery.keywords => context.t.modcp.keyword,
      ModcpThreadQuery.viewsMore => tr.viewsMore,
      ModcpThreadQuery.viewsLess => tr.viewsLess,
      ModcpThreadQuery.repliesMore => tr.repliesMore,
      ModcpThreadQuery.repliesLess => tr.repliesLess,
      _ => tr.noReplyDays,
    };
  }

  /// The field of [key]: a date or a number.
  Widget _field(String key) => switch (key) {
    ModcpThreadQuery.startTime => ModcpDateField(
      key: const ValueKey('modcp-threads-starttime'),
      label: context.t.modcp.startDate,
      value: _start,
      onChanged: (v) => setState(() => _start = v),
    ),
    ModcpThreadQuery.endTime => ModcpDateField(
      key: const ValueKey('modcp-threads-endtime'),
      label: context.t.modcp.endDate,
      value: _end,
      onChanged: (v) => setState(() => _end = v),
    ),
    _ => TextField(
      key: ValueKey('modcp-threads-$key'),
      controller: _fields[key],
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: _label(key)),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final options = page.threadOptions.isEmpty
        ? [(value: '0', label: context.t.modcpPages.threadOption)]
        : page.threadOptions;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: appFormMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  DropdownButtonFormField<String>(
                    key: const ValueKey('modcp-threads-option'),
                    initialValue: options.any((o) => o.value == _option) ? _option : options.first.value,
                    decoration: InputDecoration(labelText: context.t.modcpPages.threadOption),
                    items: [
                      for (final o in options)
                        DropdownMenuItem(value: o.value, child: Text(context.displayText(o.label))),
                    ],
                    onChanged: (v) => setState(() => _option = v ?? '0'),
                  ),
                  if (page.threadClasses.isNotEmpty)
                    DropdownButtonFormField<String>(
                      key: const ValueKey('modcp-threads-type'),
                      initialValue: page.threadClasses.any((o) => o.value == _type) ? _type : '',
                      decoration: InputDecoration(labelText: context.t.modcpPages.category),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('-')),
                        for (final o in page.threadClasses)
                          DropdownMenuItem(value: o.value, child: Text(context.displayText(o.label))),
                      ],
                      onChanged: (v) => setState(() => _type = v ?? ''),
                    ),
                  for (final k in _texts)
                    TextField(
                      key: ValueKey('modcp-threads-$k'),
                      controller: _fields[k],
                      decoration: InputDecoration(labelText: _label(k)),
                    ),
                  // Two fields a row, the same columns as the dates.
                  for (final row in [
                    [ModcpThreadQuery.startTime, ModcpThreadQuery.endTime],
                    for (var i = 0; i < _numbers.length; i += 2) _numbers.skip(i).take(2).toList(),
                  ])
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
                        for (final k in row) Expanded(child: _field(k)),
                        if (row.length == 1) const Spacer(),
                      ],
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: FilledButton.icon(
                      key: const ValueKey('modcp-threads-search-submit'),
                      icon: const Icon(Icons.search),
                      label: Text(context.t.modcp.search),
                      onPressed: () => Navigator.of(context).pop(<String, String>{
                        ModcpThreadQuery.threadOption: _option,
                        if (_type.isNotEmpty) ModcpThreadQuery.typeId: _type,
                        if (_start.isNotEmpty) ModcpThreadQuery.startTime: _start,
                        if (_end.isNotEmpty) ModcpThreadQuery.endTime: _end,
                        for (final MapEntry(:key, :value) in _fields.entries)
                          if (value.text.trim().isNotEmpty) key: value.text.trim(),
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

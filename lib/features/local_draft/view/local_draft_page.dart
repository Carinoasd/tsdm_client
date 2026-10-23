import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_text.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The local drafts of the current account ([LocalDraftStore]): what each one is for, what it says, when it was
/// written; a tap opens its target (where the editor offers it), copying and deleting from here.
///
/// The drafts of another account are never listed: switch to it to see them.
class LocalDraftPage extends StatefulWidget {
  /// Constructor.
  const LocalDraftPage({super.key});

  @override
  State<LocalDraftPage> createState() => _LocalDraftPageState();
}

class _LocalDraftPageState extends State<LocalDraftPage> {
  int? _uid;
  List<LocalDraft>? _drafts;

  /// Titles of the threads the account visited, by tid: the name of a reply's thread.
  Map<String, String> _threadTitles = const {};

  StreamSubscription<int>? _changes;
  StreamSubscription<AuthStatus>? _auth;

  LocalDraftStore? get _store => LocalDraftStore.app;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthenticationRepository>();
    _uid = auth.effectiveCurrentUid;
    // Another account in use: its drafts, never the previous one's.
    _auth = auth.status.listen((_) {
      final uid = auth.effectiveCurrentUid;
      if (uid == _uid || !mounted) {
        return;
      }
      setState(() {
        _uid = uid;
        _drafts = null;
        _threadTitles = const {};
      });
      unawaited(_load());
      unawaited(_loadThreadTitles());
    });
    _changes = _store?.changes.listen((uid) {
      if (uid == _uid) {
        unawaited(_load());
      }
    });
    unawaited(_load());
    unawaited(_loadThreadTitles());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_auth?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final uid = _uid;
    final store = _store;
    final drafts = uid == null || store == null ? const <LocalDraft>[] : await store.list(uid);
    if (mounted) {
      setState(() => _drafts = drafts);
    }
  }

  Future<void> _loadThreadTitles() async {
    final uid = _uid;
    if (uid == null || !getIt.isRegistered<StorageProvider>()) {
      return;
    }
    final history = await getIt.get<StorageProvider>().fetchThreadVisitHistoryByUid(uid).run();
    final titles = history.match(
      (_) => const <String, String>{},
      (rows) => {for (final row in rows) '${row.tid}': row.threadTitle},
    );
    if (mounted && titles.isNotEmpty) {
      setState(() => _threadTitles = titles);
    }
  }

  IconData _iconOf(LocalDraftKind kind) => switch (kind) {
    LocalDraftKind.threadReply => Icons.reply_outlined,
    LocalDraftKind.floorReply => Icons.reply_all_outlined,
    LocalDraftKind.message => Icons.mail_outline,
    LocalDraftKind.newThread => Icons.post_add_outlined,
    LocalDraftKind.edit => Icons.edit_note_outlined,
  };

  /// What the draft is for, in words: the kind, and the thread, forum or member when known.
  String _targetOf(BuildContext context, LocalDraft draft) {
    final tr = context.t.localDraft;
    final key = draft.key;
    final kind = switch (key.kind) {
      LocalDraftKind.threadReply => tr.kind.threadReply,
      LocalDraftKind.floorReply => tr.kind.floorReply,
      LocalDraftKind.message => tr.kind.message,
      LocalDraftKind.newThread => tr.kind.newThread,
      LocalDraftKind.edit => tr.kind.edit,
    };
    final name = switch (key.kind) {
      LocalDraftKind.threadReply ||
      LocalDraftKind.floorReply => draft.title ?? _threadTitles[key.tid] ?? tr.thread(tid: key.tid!),
      LocalDraftKind.message => draft.title ?? tr.member(uid: key.peerUid!),
      LocalDraftKind.newThread => draft.title ?? tr.forum(fid: key.fid!),
      LocalDraftKind.edit =>
        draft.title ?? (draft.tid != null ? _threadTitles[draft.tid] : null) ?? tr.post(pid: key.pid!),
    };
    final hint = key.kind == LocalDraftKind.floorReply ? draft.hint : null;
    return [kind, name, if (hint != null && hint.isNotEmpty) hint].join(' · ');
  }

  /// Open the page the draft was written on: its editor offers the draft there.
  Future<void> _open(BuildContext context, LocalDraft draft) async {
    final key = draft.key;
    // The editor of the target offers this very draft, also one kept aside.
    final uid = _uid;
    if (uid != null) {
      _store?.preferNext(uid, key);
    }
    switch (key.kind) {
      case LocalDraftKind.threadReply:
        await context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': key.tid});
      case LocalDraftKind.floorReply:
        await context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': key.tid, 'pid': key.pid});
      case LocalDraftKind.message:
        await context.pushNamed(ScreenPaths.chatHistory, pathParameters: {'uid': '${key.peerUid}'});
      case LocalDraftKind.newThread:
        await context.pushNamed(
          ScreenPaths.editPost,
          pathParameters: {'editType': '${PostEditType.newThread.index}', 'fid': '${key.fid}'},
        );
      case LocalDraftKind.edit:
        final fid = draft.fid;
        final tid = draft.tid;
        if (fid == null || tid == null) {
          showSnackBar(context: context, message: context.t.draftBox.openFailed);
          return;
        }
        await context.pushNamed(
          ScreenPaths.editPost,
          pathParameters: {'editType': '${PostEditType.editPost.index}', 'fid': fid},
          queryParameters: {'tid': tid, 'pid': key.pid},
        );
    }
  }

  Future<void> _copy(BuildContext context, LocalDraft draft) async {
    final subject = draft.subject?.trim() ?? '';
    await Clipboard.setData(ClipboardData(text: [if (subject.isNotEmpty) subject, draft.body].join('\n\n')));
    if (context.mounted) {
      showSnackBar(context: context, message: context.t.general.copiedToClipboard);
    }
  }

  void _delete(BuildContext context, LocalDraft draft) {
    final uid = _uid;
    if (uid == null) {
      return;
    }
    _store?.delete(uid, draft.key);
    setState(() => _drafts = _drafts?.where((e) => e.key != draft.key).toList());
    showSnackBar(context: context, message: context.t.localDraft.deleted, clearPrevious: true);
  }

  Future<void> _deleteAll(BuildContext context) async {
    final uid = _uid;
    if (uid == null) {
      return;
    }
    final tr = context.t.localDraft;
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.deleteAll,
      message: tr.deleteAllConfirm,
      dangerous: true,
    );
    if (!(confirmed ?? false) || !context.mounted) {
      return;
    }
    _store?.deleteAll(uid);
    setState(() => _drafts = const []);
  }

  Widget _buildItem(BuildContext context, LocalDraft draft) {
    final tr = context.t.localDraft;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final subject = draft.subject?.trim() ?? '';
    final snippet = draftSnippet(draft.body, emoji: tr.emoji, max: 120);
    return AppSurface(
      key: ValueKey('local-draft-${draft.key.value}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      onTap: () async => _open(context, draft),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(_iconOf(draft.key.kind), color: colorScheme.primary),
          ),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _targetOf(context, draft),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall,
                ),
                if (subject.isNotEmpty) ...[
                  sizedBoxW4H4,
                  Text(subject, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                ],
                if (snippet.isNotEmpty) ...[
                  sizedBoxW4H4,
                  Text(
                    snippet,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
                sizedBoxW4H4,
                Text(
                  [
                    tr.savedAt(time: draft.updatedAt.yyyyMMDDHHMM()),
                    if (draft.key.isBackup) tr.older,
                    if (draft.maybeSent) tr.maybeSent,
                  ].join(' · '),
                  style: textTheme.labelSmall?.copyWith(
                    color: draft.maybeSent ? colorScheme.error : colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: tr.copy,
            icon: const Icon(Icons.copy_outlined),
            onPressed: () async => _copy(context, draft),
          ),
          IconButton(
            key: ValueKey('local-draft-delete-${draft.key.value}'),
            tooltip: tr.delete,
            icon: Icon(Icons.delete_outline, color: colorScheme.error),
            onPressed: () => _delete(context, draft),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.localDraft;
    final drafts = _drafts;
    final Widget body;
    if (_uid == null) {
      body = AppStateView(icon: Icons.login_outlined, message: tr.needLogin);
    } else if (drafts == null) {
      body = const CenteredCircularIndicator();
    } else if (drafts.isEmpty) {
      body = AppStateView(icon: Icons.history_edu_outlined, message: tr.empty);
    } else {
      body = AppCenteredList(
        builder: (context, side, _) => ListView.separated(
          padding: side.copyWith(top: 12, bottom: 12),
          itemCount: drafts.length,
          separatorBuilder: (_, _) => appListSeparator,
          itemBuilder: (context, index) => _buildItem(context, drafts[index]),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          if (drafts != null && drafts.isNotEmpty)
            IconButton(
              key: const ValueKey('local-draft-delete-all'),
              tooltip: tr.deleteAll,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async => _deleteAll(context),
            ),
        ],
      ),
      body: SafeArea(bottom: false, child: body),
    );
  }
}

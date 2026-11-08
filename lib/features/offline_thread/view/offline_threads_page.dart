import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_cubit.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_dialog.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

/// One thread kept for reading without network, as the list shows it.
typedef OfflineThreadItem = ({int tid, String title, int pageCount, int size, DateTime savedAt});

/// The threads kept for the account in use, most recently used first: title (read from a saved page), pages, size and
/// when they were loaded. The update of all of them is in the app bar.
class OfflineThreadsPage extends StatefulWidget {
  /// Constructor.
  const OfflineThreadsPage({super.key});

  @override
  State<OfflineThreadsPage> createState() => _OfflineThreadsPageState();
}

class _OfflineThreadsPageState extends State<OfflineThreadsPage> {
  List<OfflineThreadItem>? _items;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) {
      return;
    }
    _loading = true;
    final offline = appOfflineThreads;
    final uid = offline.currentUid();
    final items = <OfflineThreadItem>[];
    if (uid != null) {
      final threads = ThreadRepository();
      for (final copy in await offline.copies(uid)) {
        // The title is not stored apart: it is read from a saved page, which the list does not mark as used.
        String? title;
        if (copy.defaultPages.isNotEmpty) {
          final saved = await offline.peek(
            OfflineThreadKey(uid: uid, tid: copy.tid, page: copy.defaultPages.first, orderType: 0, authorId: 0),
          );
          title = saved == null ? null : threads.summaryOfSaved(saved.body)?.title;
          // A page of HTML takes a moment to read: let the page draw in between.
          await Future<void>.delayed(Duration.zero);
        }
        items.add((
          tid: copy.tid,
          title: title == null || title.isEmpty ? '#${copy.tid}' : title,
          pageCount: copy.pageCount,
          size: copy.size,
          savedAt: copy.savedAt,
        ));
      }
    }
    _loading = false;
    if (mounted) {
      setState(() => _items = items);
    }
  }

  Future<void> _updateAll() async {
    final items = _items ?? const [];
    await showOfflineBatchDialog(
      context: context,
      mode: OfflineBatchMode.update,
      jobs: (_) async => (jobs: [for (final e in items) (tid: e.tid, title: e.title)], failure: null),
    );
    await _load();
  }

  Future<void> _remove(OfflineThreadItem item) async {
    final uid = appOfflineThreads.currentUid();
    if (uid == null) {
      return;
    }
    await appOfflineThreads.remove(uid: uid, tid: item.tid);
    if (mounted) {
      setState(() => _items = _items?.where((e) => e.tid != item.tid).toList());
    }
  }

  static String _size(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).ceil()} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.offlineBatch;
    final items = _items;
    return TwoPaneLayout(
      list: Scaffold(
        appBar: AppBar(
          title: Text(tr.copies),
          actions: [
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: tr.updateAll,
              onPressed: items == null || items.isEmpty ? null : _updateAll,
            ),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: switch (items) {
            null => const Center(child: CircularProgressIndicator()),
            [] => AppStateView(icon: Icons.offline_pin_outlined, message: tr.empty),
            _ => AppCenteredList(
              builder: (context, side, _) => ListView.separated(
                padding: side.copyWith(top: 8).add(context.safePadding()),
                itemCount: items.length,
                itemBuilder: (context, index) => _OfflineThreadCard(
                  items[index],
                  size: _size(items[index].size),
                  onRemove: () async => _remove(items[index]),
                ),
                separatorBuilder: (context, index) => appListSeparator,
              ),
            ),
          },
        ),
      ),
    );
  }
}

class _OfflineThreadCard extends StatelessWidget {
  const _OfflineThreadCard(this.item, {required this.size, required this.onRemove});

  final OfflineThreadItem item;
  final String size;
  final VoidCallback onRemove;

  Map<String, String> get _query => {'tid': '${item.tid}', 'appBarTitle': item.title};

  Future<void> _open(BuildContext context) async {
    final query = _query;
    if (openThreadInPane(context, query)) {
      return;
    }
    await context.pushNamed(ScreenPaths.threadV1, queryParameters: query);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.offlineBatch;
    final theme = Theme.of(context);
    return TwoPaneMiddleClickOpener(
      query: _query,
      child: AppSurface(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
        onTap: () async => _open(context),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppIconTile(Icons.offline_pin_outlined, size: 36),
            sizedBoxW12H12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  sizedBoxW8H8,
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      AppInfoPill(icon: Icons.access_time_outlined, label: item.savedAt.yyyyMMDDHHMM()),
                      AppInfoPill(
                        icon: Icons.layers_outlined,
                        label: tr.pages(count: item.pageCount),
                      ),
                      AppInfoPill(icon: Icons.sd_storage_outlined, label: size),
                    ],
                  ),
                ],
              ),
            ),
            sizedBoxW4H4,
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: tr.remove, onPressed: onRemove),
          ],
        ),
      ),
    );
  }
}

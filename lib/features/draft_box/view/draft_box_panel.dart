import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/draft_box/cubit/draft_cubit.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/draft_box/repository/draft_repository.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// The drafts tab of My threads. Its loading failures do not affect other tabs.
class DraftBoxPanel extends StatefulWidget {
  /// An injected controller remains owned by its caller.
  const DraftBoxPanel({super.key, this.controller});

  /// Optional test seam.
  final DraftCubit? controller;
  @override
  State<DraftBoxPanel> createState() => _DraftBoxPanelState();
}

class _DraftBoxPanelState extends State<DraftBoxPanel> {
  late final DraftCubit _cubit;
  StreamSubscription<AuthStatus>? _subscription;

  @override
  void initState() {
    super.initState();
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = DraftCubit(
        currentUid: () => auth.effectiveCurrentUid,
        repository: () => DraftRepository.network(getIt.get<NetClientProvider>()),
      );
      _subscription = auth.status.listen((status) {
        if (status is AuthStatusAuthed &&
            status.userInfo.uid == _cubit.state.uid &&
            status.userInfo.uid == auth.effectiveCurrentUid) {
          return;
        }
        if (status is AuthStatusLoading && _cubit.state.uid == auth.effectiveCurrentUid) return;
        _cubit.invalidate();
        if (status is! AuthStatusLoading) unawaited(_cubit.load());
      });
    }
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  Future<void> _open(DraftEntry entry) async {
    final uid = _cubit.state.uid;
    final target = await _cubit.open(entry);
    if (!mounted || uid != _cubit.currentUid()) return;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t.draftBox.openFailed)));
      return;
    }
    await context.pushNamed<bool>(
      ScreenPaths.editPost,
      pathParameters: {'editType': '${PostEditType.editDraft.index}', 'fid': target.fid},
      queryParameters: {'tid': target.tid, 'pid': target.pid},
    );
    if (mounted) await _cubit.load();
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<DraftCubit, DraftState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.draftBox;
      return RefreshIndicator(
        onRefresh: _cubit.load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (state.loginRequired)
              Text(tr.loginRequired)
            else ...[
              if (state.loading) const LinearProgressIndicator(),
              if (state.failed) Padding(padding: const EdgeInsets.all(16), child: Text(tr.loadFailed)),
              if (!state.loading && state.entries.isEmpty && !state.failed)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(tr.empty, textAlign: TextAlign.center),
                ),
              for (final entry in state.entries)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.edit_note),
                    title: Text(entry.title),
                    subtitle: Text(entry.forumName),
                    trailing: state.opening == entry.tid
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.chevron_right),
                    onTap: state.loading || state.opening != null ? null : () => _open(entry),
                  ),
                ),
              if (!state.loading && state.nextPage != null)
                TextButton(onPressed: () => _cubit.load(more: true), child: Text(tr.loadMore))
              else if (!state.loading)
                TextButton(onPressed: _cubit.load, child: Text(tr.refresh)),
            ],
          ],
        ),
      );
    },
  );
}

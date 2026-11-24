import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
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
import 'package:tsdm_client/widgets/app_surface.dart';

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
      final colorScheme = Theme.of(context).colorScheme;
      final textTheme = Theme.of(context).textTheme;
      return RefreshIndicator(
        onRefresh: _cubit.load,
        child: AppCenteredList(
          builder: (context, horizontal, width) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: horizontal.add(const EdgeInsets.symmetric(vertical: 12)).add(context.safePadding()),
            children: [
              if (state.loginRequired)
                AppStateView(icon: Icons.login_outlined, message: tr.loginRequired, scrollable: false)
              else ...[
                if (state.loading) ...[
                  ClipRRect(borderRadius: BorderRadius.circular(2), child: const LinearProgressIndicator()),
                  sizedBoxW8H8,
                ],
                if (state.failed) ...[
                  AppNoticeBanner(tone: AppNoticeTone.error, message: tr.loadFailed),
                  sizedBoxW8H8,
                ],
                if (!state.loading && state.entries.isEmpty && !state.failed)
                  AppStateView(icon: Icons.edit_note_outlined, message: tr.empty, scrollable: false),
                for (final entry in state.entries) ...[
                  AppSurface(
                    onTap: state.loading || state.opening != null ? null : () => _open(entry),
                    child: Row(
                      children: [
                        const AppIconTile(Icons.edit_note),
                        sizedBoxW12H12,
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              if (entry.forumName.isNotEmpty) ...[
                                sizedBoxW4H4,
                                Wrap(
                                  children: [AppInfoPill(icon: Icons.forum_outlined, label: entry.forumName)],
                                ),
                              ],
                            ],
                          ),
                        ),
                        sizedBoxW8H8,
                        if (state.opening == entry.tid)
                          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                  appListSeparator,
                ],
                if (!state.loading && state.nextPage != null)
                  Center(
                    child: TextButton.icon(
                      icon: const Icon(Icons.expand_more),
                      onPressed: () => _cubit.load(more: true),
                      label: Text(tr.loadMore),
                    ),
                  )
                else if (!state.loading)
                  Center(
                    child: TextButton.icon(
                      icon: const Icon(Icons.refresh_outlined),
                      onPressed: _cubit.load,
                      label: Text(tr.refresh),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

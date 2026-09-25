import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/medal_center/cubit/medal_center_cubit.dart';
import 'package:tsdm_client/features/medal_center/models/medal_catalog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Category browsing and acquisition details; all transactions stay on the website.
class MedalCenterPage extends StatefulWidget {
  /// Optional controller/image renderer for deterministic tests.
  const MedalCenterPage({super.key, this.controller, this.imageBuilder});

  /// Caller-owned controller when provided.
  final MedalCenterCubit? controller;

  /// Optional image renderer; production reuses [CachedImage].
  final Widget Function(String? url)? imageBuilder;
  @override
  State<MedalCenterPage> createState() => _MedalCenterPageState();
}

class _MedalCenterPageState extends State<MedalCenterPage> {
  late final MedalCenterCubit _cubit;
  StreamSubscription<AuthStatus>? _authSubscription;
  bool _actionInProgress = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = MedalCenterCubit(
        currentUid: () => auth.effectiveCurrentUid,
        fetchPage: (url) async {
          final result = await getIt.get<NetClientProvider>().get(url).run();
          return switch (result) {
            Right(:final value) => value.data as String,
            Left(:final value) => throw value,
          };
        },
        submitForm: (url, data) async {
          final result = await getIt.get<NetClientProvider>().postForm(url, data: data).run();
          return switch (result) {
            Right(:final value) => value.data as String,
            Left(:final value) => throw value,
          };
        },
      );
      _authSubscription = auth.status.listen((status) {
        _cubit.invalidate();
        if (status is! AuthStatusLoading) unawaited(_cubit.load());
      });
    }
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  Widget _image(String? url) => SizedBox(
    width: 64,
    height: 56,
    child:
        widget.imageBuilder?.call(url) ??
        (url == null
            ? const Icon(Icons.image_not_supported_outlined)
            : CachedImage(url, width: 64, height: 56, fit: BoxFit.contain)),
  );

  Future<void> _runAction(CatalogMedal medal, CatalogMedalAction action) async {
    if (_actionInProgress) return;
    setState(() => _actionInProgress = true);
    final tr = context.t.medalCenter;
    try {
      String? reason;
      if (action.type == MedalActionType.manualReview) {
        reason = await showDialog<String>(
          context: context,
          builder: (context) {
            final controller = TextEditingController();
            return AlertDialog(
              title: Text(tr.applicationTitle),
              content: TextField(
                controller: controller,
                autofocus: true,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(labelText: tr.applicationReason),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(controller.text.trim()),
                  child: Text(tr.submit),
                ),
              ],
            );
          },
        );
        if (!mounted || reason == null) return;
      }
      var confirmed = true;
      if (action.type == MedalActionType.purchase) {
        // Prefer the server's own confirmation sentence: it carries the exact price.
        final confirmText = action.confirmText;
        confirmed =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(tr.purchaseTitle),
                content: Text(
                  confirmText?.isNotEmpty ?? false ? confirmText! : tr.purchaseConfirm(name: medal.name),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(context.t.general.cancel),
                  ),
                  FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(tr.purchase)),
                ],
              ),
            ) ??
            false;
      }
      if (!confirmed || !mounted) return;
      final result = await _cubit.performAction(action, reason: reason);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message ?? (result.success ? tr.actionSuccess : tr.actionFailed))));
      if (result.success) await _cubit.load();
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  /// One acquisition button; the server disables ineligible actions and labels the reason on the control.
  Widget _actionButton(CatalogMedal medal, CatalogMedalAction action, TranslationsMedalCenterEn tr) {
    final button = FilledButton.tonalIcon(
      onPressed: _actionInProgress || action.disabledReason != null ? null : () => _runAction(medal, action),
      icon: Icon(switch (action.type) {
        MedalActionType.purchase => Icons.shopping_cart_outlined,
        MedalActionType.manualReview => Icons.rate_review_outlined,
        MedalActionType.signIn => Icons.event_available_outlined,
        MedalActionType.apply => Icons.assignment_outlined,
      }),
      label: Text(switch (action.type) {
        MedalActionType.purchase => tr.purchase,
        MedalActionType.manualReview => tr.manualReview,
        MedalActionType.signIn => tr.signIn,
        MedalActionType.apply => tr.apply,
      }),
    );
    if (action.disabledReason?.isNotEmpty ?? false) {
      return Tooltip(message: action.disabledReason, triggerMode: TooltipTriggerMode.tap, child: button);
    }
    return button;
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<MedalCenterCubit, MedalCenterState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.medalCenter;
      final catalog = state.catalog;
      final type = Uri.parse(state.url).queryParameters['typeid'];
      final selected = catalog?.categories.where((c) => Uri.parse(c.url).queryParameters['typeid'] == type).firstOrNull;
      final Widget body;
      if (state.loading) {
        body = const CenteredCircularIndicator();
      } else if (state.needLogin) {
        body = Center(
          child: TextButton(
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (mounted) await _cubit.load();
            },
            child: Text(tr.loginRequired),
          ),
        );
      } else if (state.failed) {
        body = buildRetryButton(context, () => unawaited(_cubit.load()), message: context.t.general.failedToLoad);
      } else {
        body = RefreshIndicator(
          onRefresh: _cubit.load,
          child: ListView(
            key: ValueKey(state.url),
            padding: const EdgeInsets.all(12),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Text(tr.browserNotice),
              if (catalog?.categories.isNotEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('category-${state.url}'),
                    initialValue: selected?.url,
                    isExpanded: true,
                    menuMaxHeight: 400,
                    decoration: InputDecoration(labelText: tr.category),
                    items: [
                      for (final category in catalog!.categories)
                        DropdownMenuItem(
                          value: category.url,
                          child: Text(category.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (url) {
                      if (url != null) unawaited(_cubit.load(url));
                    },
                  ),
                ),
              if (catalog?.supported == false)
                Text(catalog!.message?.isNotEmpty ?? false ? catalog.message! : tr.unsupported)
              else if (catalog?.medals.isEmpty ?? true)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(catalog?.message?.isNotEmpty ?? false ? catalog!.message! : tr.empty),
                ),
              for (final medal in catalog?.medals ?? <CatalogMedal>[])
                Card(
                  child: ExpansionTile(
                    key: ValueKey('${state.url}-${medal.id}'),
                    collapsedShape: const Border(),
                    shape: const Border(),
                    leading: _image(medal.imageUrl),
                    title: Text(medal.name),
                    subtitle: Text(medal.method.isEmpty ? tr.notProvided : medal.method),
                    childrenPadding: const EdgeInsets.all(16),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (medal.description.isNotEmpty) Text(medal.description),
                      if (medal.accountStatus != null) Text(medal.accountStatus!),
                      if (medal.details.isEmpty) Text(tr.noDetails),
                      for (final detail in medal.details)
                        Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(detail)),
                      if (medal.actions.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final action in medal.actions) _actionButton(medal, action, tr),
                          ],
                        ),
                    ],
                  ),
                ),
              if (catalog != null && catalog.supported)
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: catalog.previousUrl == null ? null : () => _cubit.load(catalog.previousUrl),
                      child: Text(tr.previous),
                    ),
                    Text(tr.page(number: catalog.page)),
                    TextButton(
                      onPressed: catalog.nextUrl == null ? null : () => _cubit.load(catalog.nextUrl),
                      child: Text(tr.next),
                    ),
                  ],
                ),
            ],
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(tr.title),
          actions: [
            IconButton(
              tooltip: tr.refresh,
              icon: const Icon(Icons.refresh),
              onPressed: state.loading ? null : _cubit.load,
            ),
            IconButton(
              tooltip: tr.openBrowser,
              icon: const Icon(Icons.open_in_browser_outlined),
              onPressed: () async => context.dispatchAsUrl(state.url, external: true),
            ),
          ],
        ),
        body: SafeArea(child: body),
      );
    },
  );
}

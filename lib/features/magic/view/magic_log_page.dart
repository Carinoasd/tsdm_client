import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/magic/cubit/magic_log_cubit.dart';
import 'package:tsdm_client/features/magic/models/magic_log.dart';
import 'package:tsdm_client/features/magic/repository/magic_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The account's magic item log: what it used, bought, gave and received.
class MagicLogPage extends StatefulWidget {
  /// An injected [controller] is owned by its caller.
  const MagicLogPage({super.key, this.controller});

  /// Optional controller for deterministic tests.
  final MagicLogCubit? controller;

  @override
  State<MagicLogPage> createState() => _MagicLogPageState();
}

class _MagicLogPageState extends State<MagicLogPage> with SingleTickerProviderStateMixin {
  late final MagicLogCubit _cubit;
  late final TabController _tabs;
  StreamSubscription<AuthStatus>? _authSubscription;

  MagicLogTab get _tab => MagicLogTab.values[_tabs.index];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: MagicLogTab.values.length, vsync: this)
      ..addListener(() {
        if (_tabs.indexIsChanging) return;
        setState(() {});
        unawaited(_cubit.ensureLoaded(_tab));
      });
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = MagicLogCubit(
        currentUid: () => auth.effectiveCurrentUid,
        repository: () => MagicRepository.network(getIt.get<NetClientProvider>()),
      );
      _authSubscription = listenAccountChanges(
        auth,
        onLoggingIn: _cubit.invalidate,
        onChanged: () {
          _cubit.invalidate();
          unawaited(_cubit.load(_tab));
        },
      );
    }
    unawaited(_cubit.load(_tab));
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _tabs.dispose();
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  Widget _link(String text, Future<void> Function() onPressed, Key key) => TextButton(
    key: key,
    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
    onPressed: () => unawaited(onPressed()),
    child: Text(text),
  );

  Widget _entry(MagicLogEntry entry, MagicLogTab tab, int index, TranslationsMagicCenterEn tr) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final words = tr.forumWords;
    Future<void> profile() async {
      if (entry.userId case final uid?) {
        await context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '$uid'});
      }
    }

    final figures = <Widget>[
      if (entry.amount case final amount?)
        Text(
          tr.owned(count: amount),
          style: textTheme.titleSmall?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
        ),
      if (entry.price case final price?)
        Text(context.displayText('$price ${entry.creditUnit}${entry.creditTitle}'), style: textTheme.bodyMedium),
      if (entry.target case final target?)
        switch (target.kind) {
          MagicLogTargetKind.sold => Text(words.sold, style: textTheme.bodyMedium),
          MagicLogTargetKind.dropped => Text(words.dropped, style: textTheme.bodyMedium),
          _ => _link(
            words.target,
            () async => context.dispatchAsUrl(target.url!),
            ValueKey('magic-log-target-$index'),
          ),
        },
      if (tab == MagicLogTab.give && entry.username.isNotEmpty)
        _link(
          words.givenTo(name: context.displayText(entry.username)),
          profile,
          ValueKey('magic-log-user-$index'),
        ),
      if (tab == MagicLogTab.receive && entry.username.isNotEmpty)
        _link(
          words.givenBy(name: context.displayText(entry.username)),
          profile,
          ValueKey('magic-log-user-$index'),
        ),
    ];
    return AppSurface(
      key: ValueKey('magic-log-${tab.operation}-$index'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  context.displayText(entry.name),
                  style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (entry.time case final time?)
                Text(
                  time.yyyyMMDDHHMM(),
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
            ],
          ),
          if (figures.isNotEmpty) ...[
            sizedBoxW4H4,
            Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: figures),
          ],
        ],
      ),
    );
  }

  Widget _pager(MagicLogTabState tabState, MagicLogList page, TranslationsMagicCenterEn tr) {
    if (page.pages <= 1 && page.page <= 1) return const SizedBox.shrink();
    void go(int n) => unawaited(_cubit.load(page.tab, page: n));
    return Padding(
      padding: const EdgeInsets.only(top: appSurfaceGap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: tr.previous,
            onPressed: page.page <= 1 || tabState.loading ? null : () => go(page.page - 1),
            icon: const Icon(Icons.chevron_left),
          ),
          Text('${page.page}/${page.pages}'),
          IconButton(
            tooltip: tr.next,
            onPressed: page.page >= page.pages || tabState.loading ? null : () => go(page.page + 1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _list(MagicLogState state, MagicLogTab tab, TranslationsMagicCenterEn tr) {
    final tabState = state.tab(tab);
    final page = tabState.page;
    if (page == null) {
      if (tabState.failed) {
        return buildRetryButton(context, () => unawaited(_cubit.load(tab)), message: context.t.general.failedToLoad);
      }
      return const CenteredCircularIndicator();
    }
    final entries = page.entries;
    return RefreshIndicator(
      onRefresh: () => _cubit.load(tab),
      child: AppCenteredList(
        builder: (context, padding, width) {
          final columns = appColumnsFor(width);
          final gap = width < 600 ? appSurfaceGapCompact : appSurfaceGap;
          return ListView(
            padding: padding.copyWith(top: 12, bottom: 12),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (tabState.failed)
                Padding(
                  padding: const EdgeInsets.only(bottom: appSurfaceGap),
                  child: AppNoticeBanner(
                    tone: AppNoticeTone.error,
                    message: context.t.general.failedToLoad,
                    actions: [
                      TextButton(onPressed: () => unawaited(_cubit.load(tab)), child: Text(context.t.general.retry)),
                    ],
                  ),
                ),
              if (entries.isEmpty) AppStateView(icon: Icons.history, message: tr.logEmpty, scrollable: false),
              for (var row = 0; row < appRowCount(entries.length, columns); row++)
                Padding(
                  padding: EdgeInsets.only(top: row == 0 ? 0 : gap),
                  child: AppColumnsRow(
                    row: row,
                    columns: columns,
                    count: entries.length,
                    gap: gap,
                    itemBuilder: (context, index) => _entry(entries[index], tab, index, tr),
                  ),
                ),
              _pager(tabState, page, tr),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<MagicLogCubit, MagicLogState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.magicCenter;
      final words = tr.forumWords;
      final Widget body;
      if (state.loginRequired) {
        body = AppStateView(
          icon: Icons.login,
          message: tr.loginRequired,
          action: FilledButton.tonalIcon(
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (mounted) await _cubit.load(_tab);
            },
            icon: const Icon(Icons.login),
            label: Text(context.t.loginPage.login),
          ),
        );
      } else if (state.message case final message?) {
        body = AppStateView(icon: Icons.history, message: context.displayText(message));
      } else {
        body = TabBarView(
          controller: _tabs,
          children: [for (final tab in MagicLogTab.values) _list(state, tab, tr)],
        );
      }
      final loading = state.tab(_tab).loading && state.tab(_tab).page != null;
      return Scaffold(
        appBar: AppBar(
          title: Text(tr.log),
          actions: [
            IconButton(
              tooltip: tr.refresh,
              icon: const Icon(Icons.refresh),
              onPressed: state.tab(_tab).loading ? null : () => _cubit.load(_tab),
            ),
            IconButton(
              tooltip: tr.openBrowser,
              icon: const Icon(Icons.open_in_browser_outlined),
              onPressed: () async => context.dispatchAsUrl(_tab.url(), external: true),
            ),
          ],
          bottom: state.loginRequired || state.message != null
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(kTextTabBarHeight + 4),
                  child: Column(
                    children: [
                      TabBar(
                        controller: _tabs,
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        tabs: [
                          Tab(key: const ValueKey('magic-log-tab-use'), text: words.logUse),
                          Tab(key: const ValueKey('magic-log-tab-buy'), text: words.logBuy),
                          Tab(key: const ValueKey('magic-log-tab-give'), text: words.logGive),
                          Tab(key: const ValueKey('magic-log-tab-receive'), text: words.logReceive),
                        ],
                      ),
                      SizedBox(height: 4, child: loading ? const LinearProgressIndicator() : null),
                    ],
                  ),
                ),
        ),
        body: SafeArea(child: body),
      );
    },
  );
}

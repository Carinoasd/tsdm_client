import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/medal_title_tools/models/models.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

const _webUrl = '$baseUrl/plugin.php?id=tsdmtitle:tsdmtitle&action=exchange';

/// Titles got with medals (`titleexchange` of the app API): which medals each asks for, which the account has, and
/// the exchange itself, the title plugin's own form.
class TitleExchangePage extends StatefulWidget {
  /// Constructor.
  const TitleExchangePage({this.repository, super.key});

  /// Injected for tests; the account's network client otherwise.
  final MedalTitleToolsRepository? repository;

  @override
  State<TitleExchangePage> createState() => _TitleExchangePageState();
}

class _TitleExchangePageState extends State<TitleExchangePage> {
  late final MedalTitleToolsRepository _repo =
      widget.repository ?? MedalTitleToolsRepository.network(getIt.get<NetClientProvider>());
  final _search = TextEditingController();
  ExchangePage? _page;
  bool _failed = false;
  bool _unsupported = false;
  bool _busy = false;
  String _filter = 'all';
  int _pageNo = 1;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final page = await _repo.exchange(filter: _filter, q: _search.text.trim(), page: _pageNo);
      if (!mounted) return;
      setState(() {
        _page = page ?? _page;
        _unsupported = page == null;
      });
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _exchange(ExchangeTitle t) async {
    final tr = context.t.medalTitleTools;
    final form = _page?.form;
    if (form == null || _busy) return;
    final ok = await showToolsConfirm(
      context,
      title: tr.exchangeConfirmTitle,
      confirm: tr.exchangeButton,
      content: [
        Center(child: ToolsImage(t.imageUrl, width: 184, height: 100)),
        sizedBoxW12H12,
        Text(tr.exchangeConfirm(name: t.name)),
        if (t.consume) ...[
          sizedBoxW12H12,
          AppNoticeBanner(
            tone: AppNoticeTone.warning,
            message: tr.exchangeConsumeConfirm(medals: t.medals.map((m) => '「${m.name}」').join()),
          ),
        ],
        sizedBoxW12H12,
        AppNoticeBanner(message: tr.exchangeNotEquipped),
      ],
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    await showFormResult(context, () => _repo.submit(form, {'exchangeid': '${t.id}'}));
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  String _filterLabel(String key, TranslationsMedalTitleToolsEn tr) => switch (key) {
    'ready' => tr.exchangeFilterReady,
    'short' => tr.exchangeFilterShort,
    'owned' => tr.exchangeFilterOwned,
    _ => tr.exchangeFilterAll,
  };

  Widget _card(ExchangeTitle t, TranslationsMedalTitleToolsEn tr) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      key: ValueKey('exchange-${t.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppInsetBlock(padding: const EdgeInsets.all(6), child: ToolsImage(t.imageUrl, width: 110, height: 60)),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    sizedBoxW4H4,
                    Text(
                      tr.exchangeProgress(have: t.have, need: t.medals.length),
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    if (t.consume)
                      Text(tr.exchangeConsume, style: textTheme.bodySmall?.copyWith(color: colorScheme.error)),
                  ],
                ),
              ),
            ],
          ),
          sizedBoxW8H8,
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final m in t.medals)
                Tooltip(
                  message: m.name,
                  child: Opacity(
                    opacity: m.owned ? 1 : 0.35,
                    child: ToolsImage(m.imageUrl, width: 22, height: 36),
                  ),
                ),
            ],
          ),
          sizedBoxW8H8,
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: t.owned
                ? Text(tr.exchangeOwned, style: textTheme.labelLarge?.copyWith(color: colorScheme.primary))
                : FilledButton.tonal(
                    onPressed: t.ready && !_busy && _page?.form != null ? () => _exchange(t) : null,
                    child: Text(tr.exchangeButton),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.medalTitleTools;
    final page = _page;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.exchangeTitle),
        actions: [
          IconButton(
            tooltip: context.t.general.openInBrowser,
            icon: const Icon(Icons.open_in_browser_outlined),
            onPressed: () async => context.dispatchAsUrl(_webUrl, external: true),
          ),
        ],
      ),
      body: page == null
          ? ToolsStateView(
              onRetry: _load,
              failed: _failed,
              message: _unsupported ? tr.unsupported : null,
              webUrl: _webUrl,
            )
          : ToolsBody(
              onRefresh: _load,
              children: [
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: tr.search,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    _pageNo = 1;
                    unawaited(_load());
                  },
                ),
                sizedBoxW8H8,
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final f in page.filters)
                      ChoiceChip(
                        label: Text('${_filterLabel(f.key, tr)} ${f.count}'),
                        selected: f.key == page.filter,
                        onSelected: (_) {
                          _filter = f.key;
                          _pageNo = 1;
                          unawaited(_load());
                        },
                      ),
                  ],
                ),
                sizedBoxW12H12,
                if (page.items.isEmpty)
                  AppStateView(message: tr.exchangeEmpty, scrollable: false)
                else
                  for (final t in page.items) ...[_card(t, tr), const SizedBox(height: appSurfaceGap)],
                ToolsPager(
                  paging: page.paging,
                  enabled: !_busy,
                  onPage: (n) {
                    _pageNo = n;
                    unawaited(_load());
                  },
                ),
              ],
            ),
    );
  }
}

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

const _webUrl = '$baseUrl/plugin.php?id=dsu_medalCenter:memcp&action=mymedal';

/// My medals (`mymedals` of the app API): which ones posts show, with the medal centre's warning before hiding, and
/// the medal record. Saving posts the medal centre's own hide form with the medals changed here.
class MyMedalsPage extends StatefulWidget {
  /// Constructor.
  const MyMedalsPage({this.repository, super.key});

  /// Injected for tests; the account's network client otherwise.
  final MedalTitleToolsRepository? repository;

  @override
  State<MyMedalsPage> createState() => _MyMedalsPageState();
}

class _MyMedalsPageState extends State<MyMedalsPage> {
  late final MedalTitleToolsRepository _repo =
      widget.repository ?? MedalTitleToolsRepository.network(getIt.get<NetClientProvider>());
  MyMedalsData? _page;
  bool _failed = false;
  bool _unsupported = false;
  bool _busy = false;
  int _logPage = 1;

  /// Medal id → hidden, for the medals changed here and not saved yet.
  final _changed = <int, bool>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final page = await _repo.myMedals(page: _logPage);
      if (!mounted) return;
      setState(() {
        _page = page ?? _page;
        _unsupported = page == null;
        if (page != null) _changed.clear();
      });
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  bool _hidden(MyMedal m) => _changed[m.id] ?? m.hidden;

  void _toggle(MyMedal m) => setState(() {
    final next = !_hidden(m);
    if (next == m.hidden) {
      _changed.remove(m.id);
    } else {
      _changed[m.id] = next;
    }
  });

  Future<void> _save() async {
    final page = _page;
    final form = page?.hideForm;
    if (page == null || form == null || _changed.isEmpty || _busy) return;
    final tr = context.t.medalTitleTools;
    final newlyHidden = page.medals.where((m) => !m.hidden && (_changed[m.id] ?? false)).toList();
    if (newlyHidden.isNotEmpty) {
      final ok = await showToolsConfirm(
        context,
        title: tr.myMedalsHideConfirmTitle,
        confirm: tr.myMedalsSave,
        destructive: true,
        content: [
          AppNoticeBanner(tone: AppNoticeTone.warning, message: page.hideWarning),
          sizedBoxW12H12,
          Text(tr.myMedalsHideConfirm(names: newlyHidden.take(10).map((m) => '「${m.name}」').join())),
        ],
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    await showFormResult(
      context,
      () => _repo.submit(form, {for (final e in _changed.entries) 'myMedalHide[${e.key}]': e.value ? '1' : '2'}),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  String _kind(String kind, TranslationsMedalTitleToolsEn tr) => switch (kind) {
    'grant' => tr.kindGrant,
    'claim' => tr.kindClaim,
    'pending' => tr.kindPending,
    'denied' => tr.kindDenied,
    'exchanged' => tr.kindExchanged,
    'bought' => tr.kindBought,
    'sign' => tr.kindSign,
    'revoked' => tr.kindRevoked,
    _ => tr.kindOther,
  };

  Widget _medal(MyMedal m, TranslationsMedalTitleToolsEn tr) {
    final hidden = _hidden(m);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      key: ValueKey('medal-${m.id}'),
      padding: edgeInsetsL12T8R12B8,
      onTap: _busy ? null : () => _toggle(m),
      child: Row(
        children: [
          Opacity(opacity: hidden ? 0.4 : 1, child: ToolsImage(m.imageUrl, width: 34, height: 55)),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.name, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                Text(
                  m.expiration > 0 ? tr.expiresOn(date: toolsDate(m.expiration)) : tr.permanent,
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Text(
            hidden ? tr.myMedalsHidden : tr.myMedalsShown,
            style: textTheme.labelMedium?.copyWith(color: hidden ? colorScheme.outline : colorScheme.primary),
          ),
          Switch(value: !hidden, onChanged: _busy ? null : (_) => _toggle(m)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.medalTitleTools;
    final page = _page;
    final textTheme = Theme.of(context).textTheme;
    final hiddenCount = page?.medals.where(_hidden).length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.myMedalsTitle),
        actions: [
          IconButton(
            tooltip: context.t.general.openInBrowser,
            icon: const Icon(Icons.open_in_browser_outlined),
            onPressed: () async => context.dispatchAsUrl(_webUrl, external: true),
          ),
        ],
      ),
      floatingActionButton: _changed.isEmpty || page?.hideForm == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(tr.myMedalsSave),
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
                if (page.hideWarning.isNotEmpty) ...[
                  AppNoticeBanner(tone: AppNoticeTone.warning, message: page.hideWarning),
                  sizedBoxW12H12,
                ],
                if (page.previewLimit case final n?)
                  Text(n > 0 ? tr.myMedalsPreview(n: n) : tr.myMedalsPreviewAll, style: textTheme.bodySmall),
                sizedBoxW4H4,
                Text(
                  tr.myMedalsCounts(shown: page.medals.length - hiddenCount, hidden: hiddenCount),
                  style: textTheme.titleSmall,
                ),
                sizedBoxW8H8,
                if (page.medals.isEmpty)
                  AppStateView(message: tr.myMedalsEmpty, scrollable: false)
                else
                  for (final m in page.medals) ...[_medal(m, tr), const SizedBox(height: 6)],
                sizedBoxW16H16,
                Text(tr.myMedalsRecord, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                sizedBoxW8H8,
                if (page.log.isEmpty)
                  Text(tr.myMedalsRecordEmpty)
                else
                  AppSurface(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final l in page.log)
                          ListTile(
                            dense: true,
                            leading: ToolsImage(l.imageUrl, width: 22, height: 36),
                            title: Text(l.name.isEmpty ? '#${l.medalId}' : l.name),
                            subtitle: Text(toolsDateTime(l.dateline)),
                            trailing: Text(_kind(l.kind, tr)),
                          ),
                      ],
                    ),
                  ),
                ToolsPager(
                  paging: page.logPaging,
                  enabled: !_busy && _changed.isEmpty,
                  onPage: (n) {
                    _logPage = n;
                    unawaited(_load());
                  },
                ),
                const SizedBox(height: 72),
              ],
            ),
    );
  }
}

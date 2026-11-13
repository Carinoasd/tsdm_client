import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/background_grant/models/background_grant.dart';
import 'package:tsdm_client/features/background_grant/repository/background_grant_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/models/models.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Sending backgrounds (`bggrant` of the app API, plugin 3.9.0): a background of the shop's catalogue (searched and
/// paged) or an image URL, the members' UIDs, the expiry and the notice; the background plugin's own form, checked by
/// the plugin, whose message is shown as it is.
class BackgroundGrantPage extends StatefulWidget {
  /// Constructor.
  const BackgroundGrantPage({this.repository, this.initialMembers, this.today, super.key});

  /// Injected for tests; the account's network client otherwise.
  final BackgroundGrantRepository? repository;

  /// Members the list starts with (a UID).
  final String? initialMembers;

  /// Today, for the expiry shortcuts by months (tests); the device's date otherwise.
  final DateTime Function()? today;

  @override
  State<BackgroundGrantPage> createState() => _BackgroundGrantPageState();
}

class _BackgroundGrantPageState extends State<BackgroundGrantPage> {
  late final BackgroundGrantRepository _repo =
      widget.repository ?? BackgroundGrantRepository.network(getIt.get<NetClientProvider>());
  late final _members = TextEditingController(text: widget.initialMembers ?? '');
  final _image = TextEditingController();
  final _expiry = TextEditingController();
  final _keyword = TextEditingController();
  BackgroundGrantInfo? _info;
  bool _failed = false;
  bool _accountChanged = false;
  bool _loading = false;
  bool _busy = false;
  bool _notify = true;
  int _generation = 0;

  DateTime get _today => widget.today?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _image.addListener(() => setState(() {}));
    _expiry.addListener(() => setState(() {}));
    // The first page the entry was checked with, when it was read a moment ago.
    final kept = widget.repository == null ? PanelToolsAccess.takeFirstPage(currentLoginUid()) : null;
    if (kept != null) {
      _info = kept;
      _expiry.text = kept.defaultExpiry;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _members.dispose();
    _image.dispose();
    _expiry.dispose();
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _load({String? keyword, int page = 1}) async {
    final generation = ++_generation;
    final first = _info == null;
    setState(() {
      _loading = true;
      _failed = false;
      _accountChanged = false;
    });
    try {
      final info = await _repo.load(keyword: (keyword ?? _info?.keyword ?? '').trim(), page: page);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        if (info == null) {
          _failed = first;
          if (!first) showSnackBar(context: context, message: context.t.general.failedToLoad);
          return;
        }
        _info = info;
        if (first) _expiry.text = info.defaultExpiry;
      });
    } on IdentityChangedException {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _accountChanged = true;
        });
      }
    } on Exception {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _failed = first;
        });
        if (!first) showSnackBar(context: context, message: context.t.general.failedToLoad);
      }
    }
  }

  String _expiryText(String value) =>
      value.trim() == '0' || value.trim().isEmpty ? context.t.medalTitleTools.permanent : value.trim();

  Future<void> _submit(BackgroundGrantInfo info) async {
    final tr = context.t.backgroundGrant;
    final image = _image.text.trim();
    final members = splitUids(_members.text);
    if (image.isEmpty) {
      showSnackBar(context: context, message: tr.needImage);
      return;
    }
    if (members.bad.isNotEmpty) {
      showSnackBar(
        context: context,
        message: tr.badMembers(list: members.bad.join(context.t.general.listSeparator)),
      );
      return;
    }
    if (members.uids.isEmpty) {
      showSnackBar(context: context, message: tr.needMembers);
      return;
    }
    final expiry = _expiry.text.trim().isEmpty ? '0' : _expiry.text.trim();
    final picked = info.items.where((b) => b.file == image).firstOrNull;
    final ok = await showToolsConfirm(
      context,
      title: tr.title,
      confirm: tr.send,
      content: [
        if (picked != null) ...[ToolsImage(picked.imageUrl, width: 160, height: 90), sizedBoxW8H8],
        Text(picked == null ? image : '${context.displayText(picked.name)} · ${picked.file}'),
        sizedBoxW8H8,
        Text('UID ${members.uids.join(context.t.general.listSeparator)}'),
        sizedBoxW8H8,
        Text(_expiryText(expiry)),
      ],
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final tools = context.t.medalTitleTools;
    final changed = context.t.general.accountChangedRetry;
    String message;
    var success = false;
    try {
      final result = await _repo.submit(
        info,
        image: image,
        uids: members.uids,
        expiry: expiry,
        notify: _notify,
      );
      success = result.success;
      message = result.message.isEmpty ? tools.unconfirmed : result.message;
    } on IdentityChangedException {
      message = changed;
    } on Exception {
      message = tools.unconfirmed;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Sent: the members go, so a second tap does not send them the same again; the background and the expiry stay
      // for the next members.
      if (success) _members.clear();
    });
    showSnackBar(context: context, message: context.displayText(message), showCloseIcon: true);
  }

  Widget _catalogue(BackgroundGrantInfo info) {
    final tr = context.t.backgroundGrant;
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('bggrant-search'),
            controller: _keyword,
            textInputAction: TextInputAction.search,
            onSubmitted: (v) => _load(keyword: v),
            decoration: InputDecoration(
              hintText: tr.search,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          sizedBoxW12H12,
          if (info.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(tr.empty, textAlign: TextAlign.center),
            )
          else
            GridView.extent(
              key: const ValueKey('bggrant-grid'),
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.25,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final b in info.items)
                  Material(
                    key: ValueKey('bggrant-item-${b.id}'),
                    color: colorScheme.surfaceContainerHigh,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(appInnerRadius),
                      side: _image.text.trim() == b.file
                          ? BorderSide(color: colorScheme.primary, width: 2)
                          : BorderSide.none,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _busy ? null : () => _image.text = b.file,
                      child: Column(
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, c) => ToolsImage(b.imageUrl, width: c.maxWidth, height: c.maxHeight),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Text(
                              context.displayText(b.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ToolsPager(
            paging: info.paging,
            enabled: !_loading && !_busy,
            onPage: (page) => _load(page: page),
          ),
        ],
      ),
    );
  }

  Widget _form(BackgroundGrantInfo info) {
    final tr = context.t.backgroundGrant;
    final today = _today;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('bggrant-image'),
            controller: _image,
            maxLength: info.maxUrl,
            decoration: InputDecoration(labelText: tr.image, border: const OutlineInputBorder()),
          ),
          sizedBoxW8H8,
          TextField(
            key: const ValueKey('bggrant-members'),
            controller: _members,
            decoration: InputDecoration(labelText: tr.members, border: const OutlineInputBorder()),
          ),
          sizedBoxW12H12,
          if (info.presets.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (i, p) in info.presets.indexed)
                  ChoiceChip(
                    key: ValueKey('bggrant-preset-$i'),
                    label: Text(context.displayText(p.label)),
                    selected: _expiry.text.trim() == p.value(today),
                    onSelected: _busy ? null : (_) => _expiry.text = p.value(today),
                  ),
              ],
            ),
            sizedBoxW12H12,
          ],
          TextField(
            key: const ValueKey('bggrant-expiry'),
            controller: _expiry,
            decoration: InputDecoration(labelText: tr.expiry, border: const OutlineInputBorder()),
          ),
          SwitchListTile(
            key: const ValueKey('bggrant-notify'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr.notify),
            value: _notify,
            onChanged: _busy ? null : (v) => setState(() => _notify = v),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(
              key: const ValueKey('bggrant-send'),
              onPressed: _busy ? null : () => _submit(info),
              child: Text(tr.send),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tools = context.t.medalTitleTools;
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: Text(context.t.backgroundGrant.title)),
      body: info == null || !info.usable
          ? ToolsStateView(
              onRetry: _load,
              failed: _failed,
              message: _accountChanged
                  ? context.t.general.accountChangedRetry
                  : info == null
                  ? null
                  : info.supported
                  ? tools.noPermission
                  : tools.unsupported,
            )
          : ToolsBody(
              onRefresh: () => _load(page: info.paging.page),
              children: [_catalogue(info), sizedBoxW12H12, _form(info)],
            ),
    );
  }
}

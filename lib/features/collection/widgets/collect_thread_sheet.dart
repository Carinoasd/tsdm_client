import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:tsdm_client/features/collection/repository/collection_repository.dart';
import 'package:tsdm_client/features/collection/utils/collection_answer.dart';
import 'package:tsdm_client/features/collection/widgets/collection_dialogs.dart';
import 'package:tsdm_client/features/collection/widgets/collection_tiles.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Put thread [tid] in collections of the account, as the forum's "淘帖" window does: the collections holding it
/// already (each opens), the account's collections that can take it (several may be picked), a new one created on
/// the spot by its name, and the reason.
Future<void> showCollectThreadSheet(BuildContext context, {required int tid, CollectionRepository? repository}) =>
    showCustomBottomSheet<void>(
      context: context,
      title: context.t.collection.collectTitle,
      builder: (context) => CollectThreadSheet(tid: tid, repository: repository ?? CollectionRepository.network()),
    );

/// The content of [showCollectThreadSheet].
class CollectThreadSheet extends StatefulWidget {
  /// Constructor.
  const CollectThreadSheet({required this.tid, required this.repository, super.key});

  /// The thread.
  final int tid;

  /// The repository.
  final CollectionRepository repository;

  @override
  State<CollectThreadSheet> createState() => _CollectThreadSheetState();
}

class _CollectThreadSheetState extends State<CollectThreadSheet> {
  final _reason = TextEditingController();
  final _newName = TextEditingController();
  final _picked = <int>{};
  bool _loading = true;
  bool _sending = false;
  CollectThreadForm? _form;
  String? _refusal;
  List<CollectionSummary> _related = const [];

  @override
  void initState() {
    super.initState();
    _newName.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    _reason.dispose();
    _newName.dispose();
    super.dispose();
  }

  Future<void> _load({int? pick}) async {
    setState(() => _loading = true);
    final (form, related) = await (
      widget.repository.fetchCollectForm(widget.tid),
      widget.repository.fetchRelated(widget.tid).run(),
    ).wait;
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      if (related case Right(:final value)) {
        _related = value.items;
      }
      switch (form) {
        case Right(:final value):
          _form = value;
          _refusal = null;
          _picked.retainAll(value.choices.map((e) => e.ctid));
          if (pick != null && value.choices.any((e) => e.ctid == pick)) {
            _picked.add(pick);
          }
        case Left(:final value):
          _form = null;
          _refusal = switch (value) {
            CollectionRefused(:final message) => message,
            CollectionAccountChanged() => context.t.collection.accountChanged,
            _ => context.t.collection.unknown,
          };
      }
    });
    if (form case Left(value: CollectionNeedLogin())) {
      await _toLogin();
    }
  }

  Future<void> _toLogin() async {
    final router = GoRouter.of(context);
    await Navigator.of(context).maybePop();
    await router.pushNamed(ScreenPaths.login);
  }

  Future<void> _create(CollectThreadForm form) async {
    setState(() => _sending = true);
    final outcome = await widget.repository.create(
      viewerUid: form.viewerUid,
      formHash: form.formHash,
      title: _newName.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    final name = _newName.text.trim();
    if (await reportCollectionOutcome(context, outcome)) {
      collectionChanges.value++;
      _newName.clear();
    }
    // The window of the forum lists the new collection: read it again, never create it twice.
    await _load(pick: createdCtid(outcome));
    // No verdict (the answer was lost): the forum may have created it all the same. Its window tells: the one of that
    // name is picked, and the name is not offered to be created again.
    if (mounted && outcome is CollectionUnknown) {
      final created = _form?.choices.where((e) => e.name == name).lastOrNull;
      if (created != null) {
        setState(() {
          _picked.add(created.ctid);
          _newName.clear();
        });
      }
    }
  }

  Future<void> _collect(CollectThreadForm form) async {
    setState(() => _sending = true);
    final outcome = await widget.repository.collect(form, _picked, _reason.text.trim());
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    if (await reportCollectionOutcome(context, outcome)) {
      collectionChanges.value++;
      if (mounted) {
        await Navigator.of(context).maybePop();
      }
      return;
    }
    if (outcome is! CollectionRefused) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.collection;
    final theme = Theme.of(context);
    if (_loading && _form == null && _refusal == null) {
      return const Padding(padding: edgeInsetsL16T16R16B16, child: CenteredCircularIndicator());
    }
    final form = _form;
    return ListView(
      shrinkWrap: true,
      padding: edgeInsetsL16R16B12.add(MediaQuery.viewInsetsOf(context)),
      children: [
        if (_related.isNotEmpty) ...[
          AppSectionHeader(tr.collectedIn, icon: Icons.collections_bookmark_outlined),
          for (final c in _related)
            ListTile(
              key: ValueKey('collect-related-${c.ctid}'),
              contentPadding: EdgeInsets.zero,
              title: Text(c.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async => openCollection(context, c.ctid),
            ),
          sizedBoxW8H8,
        ],
        if (_refusal case final refusal?)
          Padding(
            padding: edgeInsetsT4B4,
            child: Text(refusal, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
          ),
        if (form != null) ...[
          for (final choice in form.choices)
            CheckboxListTile(
              key: ValueKey('collect-choice-${choice.ctid}'),
              contentPadding: EdgeInsets.zero,
              value: _picked.contains(choice.ctid),
              title: Text(choice.name),
              onChanged: _sending
                  ? null
                  : (v) => setState(() => (v ?? false) ? _picked.add(choice.ctid) : _picked.remove(choice.ctid)),
            ),
          if (form.remainingCreate > 0)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('collect-new-name'),
                    controller: _newName,
                    enabled: !_sending,
                    maxLength: collectionNameLimit,
                    decoration: InputDecoration(labelText: tr.newCollection),
                  ),
                ),
                IconButton(
                  key: const ValueKey('collect-new-create'),
                  icon: const Icon(Icons.add),
                  tooltip: tr.create,
                  onPressed: _sending || _newName.text.trim().isEmpty ? null : () async => _create(form),
                ),
              ],
            ),
          TextField(
            key: const ValueKey('collect-reason'),
            controller: _reason,
            enabled: !_sending,
            minLines: 1,
            maxLines: 4,
            maxLength: collectionTextLimit,
            decoration: InputDecoration(labelText: tr.reasonField),
          ),
          sizedBoxW8H8,
          FilledButton(
            key: const ValueKey('collect-submit'),
            onPressed: _sending || _picked.isEmpty ? null : () async => _collect(form),
            child: Text(tr.collectSubmit),
          ),
        ],
      ],
    );
  }
}

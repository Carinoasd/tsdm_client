import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The rules of the forums the account moderates (the panel's 版块编辑 › 本版规则), as BBCode text: edited when the
/// panel opens its editor to the account, read only otherwise.
class ForumRulesPage extends StatefulWidget {
  /// Constructor.
  const ForumRulesPage({required this.repository, super.key});

  /// The panel.
  final ModcpRepository repository;

  @override
  State<ForumRulesPage> createState() => _ForumRulesPageState();
}

class _ForumRulesPageState extends State<ForumRulesPage> {
  bool _loading = true;
  bool _sending = false;
  Either<AppException, ModcpAnswer<ForumRules>>? _answer;

  /// The forum asked, 0 for the one the panel chooses.
  int _fid = 0;

  /// The forums the panel offered, last read.
  List<ModcpForum> _forums = const [];

  final _rules = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final answer = await widget.repository.fetchForumRules(fid: _fid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
      if (answer case Right(value: ModcpReady(:final value))) {
        if (value.forums.isNotEmpty) {
          _forums = value.forums;
        }
        _rules.text = value.rules;
      }
    });
  }

  Future<void> _pick(int fid) async {
    _fid = fid;
    await _load();
  }

  Future<void> _switchForum(int current) async {
    final picked = await showModalBottomSheet<ModcpForum>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final forum in _forums)
              ListTile(
                key: ValueKey('modcp-switch-forum-${forum.fid}'),
                title: Text(forum.name),
                selected: forum.fid == current,
                trailing: forum.fid == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(forum),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted && picked.fid != current) {
      await _pick(picked.fid);
    }
  }

  Future<void> _save(ForumRules rules) async {
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    final outcome = await widget.repository.saveForumRules(rules, _rules.text).run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    showSnackBar(context: context, message: modcpOutcomeText(context, outcome));
    // What the forum keeps now (or its login when the session ended).
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    final rules = switch (_answer) {
      Right(value: ModcpReady(:final value)) when value.fid > 0 => value,
      _ => null,
    };
    final name = _forums.where((e) => e.fid == rules?.fid).firstOrNull?.name;
    return PopScope(
      canPop: !_sending,
      child: Scaffold(
        appBar: AppBar(
          title: Text(name == null ? tr.rules : '${tr.rules} · $name'),
          actions: [
            if (rules != null && _forums.length > 1)
              IconButton(
                key: const ValueKey('modcp-switch-forum'),
                tooltip: tr.switchForum,
                icon: const Icon(Icons.swap_horiz),
                onPressed: _sending ? null : () => _switchForum(rules.fid),
              ),
          ],
        ),
        body: ModcpAnswerView<ForumRules>(
          repository: widget.repository,
          loading: _loading,
          answer: _answer,
          onReload: _load,
          builder: (context, rules) => rules.fid > 0 ? _editor(context, rules) : _chooser(context, rules),
        ),
      ),
    );
  }

  /// The forum asked is not one the account moderates (any more): the forums the panel offers.
  Widget _chooser(BuildContext context, ForumRules rules) {
    final forums = rules.forums.isNotEmpty ? rules.forums : _forums;
    if (forums.isEmpty) {
      return AppStateView(icon: Icons.forum_outlined, message: context.t.modcp.noForums);
    }
    return AppCenteredList(
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 8, bottom: 8),
        children: [
          AppSurface(
            child: Column(
              children: [
                for (final forum in forums)
                  ListTile(
                    key: ValueKey('modcp-forum-${forum.fid}'),
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(forum.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pick(forum.fid),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context, ForumRules rules) {
    final theme = Theme.of(context);
    return AppCenteredList(
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 12, bottom: 24),
        children: [
          TextField(
            key: const ValueKey('modcp-rules'),
            controller: _rules,
            readOnly: !rules.editable || _sending,
            minLines: 8,
            maxLines: 20,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          if (!rules.editable && rules.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(rules.note, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (rules.editable) ...[
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('modcp-rules-save'),
              onPressed: _sending ? null : () => _save(rules),
              child: _sending
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(context.t.modcp.save),
            ),
          ],
        ],
      ),
    );
  }
}

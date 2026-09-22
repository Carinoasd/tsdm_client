import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/widgets/notice_ignore_actions.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_button.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Manage the local block list and the forum's notice ignore rules of the current account.
///
/// The two are shown apart on purpose: the local list never touches the forum, the rules live on the forum.
///
/// Forum rules belong to the account they were loaded for: when the current account changes they are cleared, and
/// an answer that arrives for the previous account is dropped.
class UserBlockPage extends StatefulWidget {
  /// Constructor.
  const UserBlockPage({this.noticeIgnoreRepository = const NoticeIgnoreRepository(), this.clientFactory, super.key});

  /// Repository of the forum rules, replaceable in tests.
  final NoticeIgnoreRepository noticeIgnoreRepository;

  /// Builds the client bound to the current account, replaceable in tests.
  final BoundClientFactory? clientFactory;

  @override
  State<UserBlockPage> createState() => _UserBlockPageState();
}

class _UserBlockPageState extends State<UserBlockPage> {
  /// Account the shown rules belong to.
  int? _rulesOwner;

  /// Rules loaded from the forum for [_rulesOwner], null before the user loads them.
  List<NoticeIgnoreRule>? _rules;
  NoticeIgnoreFailure? _rulesFailure;

  /// Increased on every account change and every request, answers of an older generation are dropped.
  int _generation = 0;
  bool _busy = false;

  StreamSubscription<Object?>? _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = context.read<AuthenticationRepository>().status.listen((_) => _onAccountMaybeChanged());
  }

  @override
  void dispose() {
    unawaited(_authSub?.cancel());
    super.dispose();
  }

  int? get _currentUid => context.read<AuthenticationRepository>().currentUser?.uid;

  void _onAccountMaybeChanged() {
    if (!mounted || _rulesOwner == null || _rulesOwner == _currentUid) {
      return;
    }
    setState(() {
      _generation++;
      _rulesOwner = null;
      _rules = null;
      _rulesFailure = null;
      _busy = false;
    });
  }

  Future<void> _loadRules() async {
    if (_busy) {
      return;
    }
    final bound = boundClientOfCurrentUser(context, clientFactory: widget.clientFactory);
    if (bound == null) {
      setState(() {
        _rulesOwner = null;
        _rules = null;
        _rulesFailure = NoticeIgnoreFailure.notLoggedIn;
      });
      return;
    }
    final (uid, client) = bound;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      if (_rulesOwner != uid) {
        _rules = null;
      }
      _rulesOwner = uid;
      _rulesFailure = null;
    });
    final result = await widget.noticeIgnoreRepository.fetchRules(client, uid: uid);
    if (!mounted || generation != _generation || _currentUid != uid) {
      return;
    }
    setState(() {
      _busy = false;
      _rules = result.rules ?? (result.isSuccess ? const [] : _rules);
      _rulesFailure = result.failure;
    });
  }

  Future<void> _removeRule(NoticeIgnoreRule rule, String label) async {
    if (_busy) {
      return;
    }
    final tr = context.t.userBlock.serverRules;
    // Bind the account before asking: a choice made for one account is never applied to another one.
    final owner = _rulesOwner;
    final bound = boundClientOfCurrentUser(context, clientFactory: widget.clientFactory);
    if (bound == null || bound.$1 != owner) {
      showSnackBar(context: context, message: bound == null ? tr.failure.notLoggedIn : tr.failure.accountMismatch);
      _onAccountMaybeChanged();
      return;
    }
    final (uid, client) = bound;
    final generation = _generation;
    // Nothing else may start while the dialog is open.
    setState(() => _busy = true);
    final ok = await showQuestionDialog(
      context: context,
      title: tr.confirmTitle,
      message: tr.removeConfirmContent(rule: label),
      dangerous: true,
    );
    if (!mounted) {
      return;
    }
    if (!(ok ?? false) || generation != _generation || _currentUid != uid) {
      if (generation == _generation) {
        setState(() => _busy = false);
      }
      if (ok ?? false) {
        showSnackBar(context: context, message: tr.failure.accountMismatch);
      }
      return;
    }
    final result = await widget.noticeIgnoreRepository.removeRule(client, uid: uid, rule: rule);
    if (!mounted || generation != _generation || _currentUid != uid) {
      return;
    }
    setState(() {
      _busy = false;
      _rules = result.rules ?? _rules;
      _rulesFailure = result.failure;
    });
    showSnackBar(
      context: context,
      message: result.isSuccess ? tr.success : noticeIgnoreFailureText(context, result.failure!),
    );
  }

  Widget _buildLocalList(BuildContext context, UserBlockList list) {
    final tr = context.t.userBlock;
    switch (list.status) {
      case UserBlockListStatus.loading when list.ownerUid != null:
        return const ListTile(title: LinearProgressIndicator());
      case UserBlockListStatus.failed:
        return ListTile(
          leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          title: Text(tr.loadFailed),
          trailing: TextButton(
            onPressed: () async => context.read<UserBlockCubit>().reload(),
            child: Text(context.t.general.retry),
          ),
        );
      case UserBlockListStatus.loading || UserBlockListStatus.ready:
        break;
    }
    if (list.ownerUid == null) {
      return ListTile(title: Text(tr.invalid));
    }
    if (list.users.isEmpty) {
      return ListTile(title: Text(tr.empty));
    }
    return Column(
      children: list.users
          .map(
            (u) => ListTile(
              key: ValueKey('blocked-${u.uid}'),
              leading: const Icon(Icons.block_outlined),
              title: Text(u.username),
              subtitle: Text('UID ${u.uid} · ${tr.blockedAt(time: u.blockedAt.yyyyMMDDHHMMSS())}'),
              onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${u.uid}'}),
              trailing: TextButton(
                onPressed: () async => unblockUser(context, uid: u.uid, username: u.username),
                child: Text(tr.unblock),
              ),
            ),
          )
          .toList(),
    );
  }

  /// The forum's own text of rule [r], null when it gives none.
  ///
  /// The privacy page names the types it knows and prints the bare type for the others (`at (Alice)`, `poke (Bob)`,
  /// Discuz `spacecp_privacy`); that code is replaced by the app's name of the type.
  String? _forumLabelOf(BuildContext context, NoticeIgnoreRule r) {
    final label = r.label?.trim();
    if (label == null || label.isEmpty) {
      return null;
    }
    if (label == r.type || label.startsWith('${r.type} ') || label.startsWith('${r.type}(')) {
      return '${noticeTypeName(context, r.type)}${label.substring(r.type.length)}';
    }
    return label;
  }

  Widget _buildRules(BuildContext context) {
    final tr = context.t.userBlock.serverRules;
    final rules = _rules;
    final String loadLabel;
    if (_rulesFailure != null) {
      loadLabel = context.t.general.retry;
    } else if (rules == null) {
      loadLabel = tr.load;
    } else {
      loadLabel = tr.reload;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(leading: const Icon(Icons.info_outline), title: Text(tr.entryHelp)),
        // Always visible and apart from the header, disabled while a request is running.
        Padding(
          padding: edgeInsetsL4R4,
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _loadRules,
              icon: const Icon(Icons.refresh),
              label: Text(loadLabel),
            ),
          ),
        ),
        // Rules are never reported as empty before the forum answered.
        if (rules == null && _rulesFailure == null && !_busy) ListTile(title: Text(tr.notLoaded)),
        if (_rulesFailure != null)
          ListTile(
            leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
            title: Text(noticeIgnoreFailureText(context, _rulesFailure!)),
          ),
        if (rules != null && rules.isEmpty) ListTile(title: Text(tr.empty)),
        if (rules != null)
          ...rules.map((r) {
            final who = r.everybody ? tr.everybody : tr.userUid(uid: '${r.authorId}');
            final label = '${noticeTypeName(context, r.type)} · $who';
            // The forum's own text when it gives one; the confirmation names the rule the way the list does.
            final title = _forumLabelOf(context, r) ?? label;
            return ListTile(
              key: ValueKey('rule-${r.key}'),
              leading: const Icon(Icons.notifications_off_outlined),
              title: Text(title),
              subtitle: Text(label),
              trailing: TextButton(
                onPressed: _busy ? null : () async => _removeRule(r, title),
                child: Text(tr.remove),
              ),
            );
          }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_sync_outlined),
            tooltip: tr.serverRules.title,
            onPressed: _busy ? null : _loadRules,
          ),
        ],
      ),
      body: ListView(
        padding: edgeInsetsL12T4R12.add(context.safePadding()),
        children: [
          Card(
            child: Padding(padding: edgeInsetsL12T12R12B12, child: Text(tr.localHint)),
          ),
          BlocBuilder<UserBlockCubit, UserBlockList>(builder: _buildLocalList),
          const Divider(),
          ListTile(
            title: Text(tr.serverRules.title, style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text(tr.serverRules.hint),
            trailing: _busy ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator()) : null,
            onTap: _busy ? null : _loadRules,
          ),
          _buildRules(context),
        ],
      ),
    );
  }
}

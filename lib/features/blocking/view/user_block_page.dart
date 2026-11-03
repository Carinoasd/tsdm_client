import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/keyword_block_cubit.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/keyword_block_repository.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/widgets/notice_ignore_actions.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_button.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Manage the local block list and the forum's notice ignore rules of the current account.
///
/// The two are shown apart on purpose: the local list never touches the forum, the rules live on the forum. The
/// forum's own blacklist (the `blockuser` plugin) is a third, separate list with its own page, linked from here.
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
        return const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator());
      case UserBlockListStatus.failed:
        return AppNoticeBanner(
          message: tr.loadFailed,
          tone: AppNoticeTone.error,
          actions: [
            TextButton.icon(
              onPressed: () async => context.read<UserBlockCubit>().reload(),
              icon: const Icon(Icons.refresh),
              label: Text(context.t.general.retry),
            ),
          ],
        );
      case UserBlockListStatus.loading || UserBlockListStatus.ready:
        break;
    }
    if (list.ownerUid == null) {
      return AppNoticeBanner(message: tr.invalid, icon: Icons.login);
    }
    if (list.users.isEmpty) {
      return _EmptyLine(icon: Icons.person_off_outlined, text: tr.empty);
    }
    return Column(
      children: [
        for (final (index, u) in list.users.indexed) ...[
          if (index > 0) sizedBoxW8H8,
          _BlockRow(
            key: ValueKey('blocked-${u.uid}'),
            icon: Icons.block_outlined,
            title: u.username,
            subtitle: 'UID ${u.uid} · ${tr.blockedAt(time: u.blockedAt.yyyyMMDDHHMMSS())}',
            onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${u.uid}'}),
            action: TextButton(
              onPressed: () async => unblockUser(context, uid: u.uid, username: u.username),
              child: Text(tr.unblock),
            ),
          ),
        ],
      ],
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 18, color: Theme.of(context).colorScheme.primary),
            sizedBoxW8H8,
            Expanded(child: Text(tr.entryHelp, style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
        sizedBoxW8H8,
        // Always visible and apart from the header, disabled while a request is running.
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _busy ? null : _loadRules,
            icon: const Icon(Icons.refresh),
            label: Text(loadLabel),
          ),
        ),
        // Rules are never reported as empty before the forum answered.
        if (rules == null && _rulesFailure == null && !_busy)
          _EmptyLine(icon: Icons.cloud_download_outlined, text: tr.notLoaded),
        if (_rulesFailure != null)
          AppNoticeBanner(message: noticeIgnoreFailureText(context, _rulesFailure!), tone: AppNoticeTone.error),
        if (rules != null && rules.isEmpty) _EmptyLine(icon: Icons.notifications_none_outlined, text: tr.empty),
        if (rules != null)
          for (final (index, r) in rules.indexed) ...[
            if (index > 0) sizedBoxW8H8,
            _buildRule(context, r),
          ],
      ],
    );
  }

  Widget _buildRule(BuildContext context, NoticeIgnoreRule r) {
    final tr = context.t.userBlock.serverRules;
    final who = r.everybody ? tr.everybody : tr.userUid(uid: '${r.authorId}');
    final label = '${noticeTypeName(context, r.type)} · $who';
    // The forum's own text when it gives one; the confirmation names the rule the way the list does.
    final title = _forumLabelOf(context, r) ?? label;
    return _BlockRow(
      key: ValueKey('rule-${r.key}'),
      icon: Icons.notifications_off_outlined,
      title: title,
      subtitle: label,
      action: TextButton(
        onPressed: _busy ? null : () async => _removeRule(r, title),
        child: Text(tr.remove),
      ),
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
      body: SafeArea(
        top: false,
        bottom: false,
        child: AppCenteredList(
          maxWidth: appFormMaxWidth,
          builder: (context, side, _) => ListView(
            padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
            children: [
              // 1. The list on this device.
              AppSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppSectionHeader(
                      tr.localTitle,
                      icon: Icons.phone_android_outlined,
                      padding: const EdgeInsets.only(bottom: 8),
                    ),
                    AppInsetBlock(
                      child: Text(
                        tr.localHint,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    sizedBoxW12H12,
                    BlocBuilder<UserBlockCubit, UserBlockList>(builder: _buildLocalList),
                  ],
                ),
              ),
              // 2. Keywords on this device.
              const _KeywordSection(),
              const SizedBox(height: appSurfaceGap),
              // 3. The forum's blacklist has its own page: it lives in the forum account, unlike the list above.
              AppSurface(
                key: const ValueKey('website-blocklist-entry'),
                onTap: () async => context.pushNamed(ScreenPaths.websiteBlocklist),
                child: Row(
                  children: [
                    const AppIconTile(Icons.public_outlined),
                    sizedBoxW12H12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr.website.entry,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            tr.website.entryHint,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
                  ],
                ),
              ),
              const SizedBox(height: appSurfaceGap),
              // 4. Notice rules saved in the forum account.
              AppSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppSectionHeader(
                      tr.serverRules.title,
                      icon: Icons.notifications_paused_outlined,
                      padding: const EdgeInsets.only(bottom: 4),
                      trailing: _busy ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator()) : null,
                    ),
                    Text(
                      tr.serverRules.hint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    sizedBoxW12H12,
                    _buildRules(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One blocked user or rule: icon tile, name, details and the action that undoes it.
///
/// The action moves under the text when the row is too narrow for both (small phones, large fonts).
class _BlockRow extends StatelessWidget {
  const _BlockRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        Text(subtitle, style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant)),
      ],
    );
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(appInnerRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: edgeInsetsL12T8R12B8,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 360 * MediaQuery.textScalerOf(context).scale(1);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIconTile(icon, size: 32),
                  sizedBoxW12H12,
                  Expanded(
                    child: wide
                        ? text
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              text,
                              Align(alignment: AlignmentDirectional.centerEnd, child: action),
                            ],
                          ),
                  ),
                  if (wide) ...[sizedBoxW8H8, action],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A list without entries yet: icon and message in the muted colors.
class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppInsetBlock(
      padding: edgeInsetsL12T12R12B12,
      child: Row(
        children: [
          Icon(icon, size: 20, color: colorScheme.outline),
          sizedBoxW12H12,
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// The local keyword list of the current account: add, remove, and whether each one also hides floors.
///
/// Not shown when no [KeywordBlockCubit] is provided (isolated widget tests of the page).
class _KeywordSection extends StatefulWidget {
  const _KeywordSection();

  @override
  State<_KeywordSection> createState() => _KeywordSectionState();
}

class _KeywordSectionState extends State<_KeywordSection> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _failureText(KeywordBlockResult result) {
    final tr = context.t.userBlock;
    return switch (result) {
      KeywordBlockResult.ok || KeywordBlockResult.empty || KeywordBlockResult.notFound => null,
      KeywordBlockResult.tooLong => tr.keyword.tooLong(max: KeywordBlockRepository.maxLength),
      KeywordBlockResult.duplicate => tr.keyword.duplicate,
      KeywordBlockResult.limitReached => tr.keyword.limitReached(max: KeywordBlockRepository.maxCount),
      KeywordBlockResult.invalid => tr.invalid,
      KeywordBlockResult.accountChanged => tr.accountChanged,
      KeywordBlockResult.storageError => tr.keyword.storageError,
    };
  }

  Future<void> _report(Future<KeywordBlockResult> change, {VoidCallback? onOk}) async {
    final result = await change;
    if (!mounted) {
      return;
    }
    if (result == KeywordBlockResult.ok) {
      onOk?.call();
    }
    final message = _failureText(result);
    if (message != null) {
      showSnackBar(context: context, message: message);
    }
  }

  Future<void> _add() async {
    final cubit = context.read<KeywordBlockCubit>();
    final text = _controller.text;
    if (normalizeBlockedKeyword(text).isEmpty) {
      return;
    }
    await _report(cubit.add(text, expectedOwner: cubit.owner), onOk: _controller.clear);
  }

  Widget _buildList(BuildContext context, KeywordBlockList list) {
    final tr = context.t.userBlock;
    switch (list.status) {
      case UserBlockListStatus.loading when list.ownerUid != null:
        return const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator());
      case UserBlockListStatus.failed:
        return AppNoticeBanner(
          message: tr.keyword.loadFailed,
          tone: AppNoticeTone.error,
          actions: [
            TextButton.icon(
              onPressed: () async => context.read<KeywordBlockCubit>().reload(),
              icon: const Icon(Icons.refresh),
              label: Text(context.t.general.retry),
            ),
          ],
        );
      case UserBlockListStatus.loading || UserBlockListStatus.ready:
        break;
    }
    if (list.ownerUid == null) {
      return AppNoticeBanner(message: tr.invalid, icon: Icons.login);
    }
    if (list.keywords.isEmpty) {
      return _EmptyLine(icon: Icons.filter_alt_off_outlined, text: tr.keyword.empty);
    }
    final cubit = context.read<KeywordBlockCubit>();
    return Column(
      children: [
        for (final (index, k) in list.keywords.indexed) ...[
          if (index > 0) sizedBoxW8H8,
          _KeywordRow(
            key: ValueKey('keyword-${k.key}'),
            keyword: k,
            onAppliesToPostsChanged: (value) async =>
                _report(cubit.setAppliesToPosts(k.keyword, value: value, expectedOwner: cubit.owner)),
            onRemove: () async => _report(cubit.remove(k.keyword, expectedOwner: cubit.owner)),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    try {
      context.read<KeywordBlockCubit>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    final tr = context.t.userBlock.keyword;
    final enabled = context.select<KeywordBlockCubit, bool>(
      (c) => c.state.ownerUid != null && c.state.status == UserBlockListStatus.ready,
    );
    return Padding(
      padding: const EdgeInsets.only(top: appSurfaceGap),
      child: AppSurface(
        key: const ValueKey('keyword-block-section'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSectionHeader(tr.title, icon: Icons.filter_alt_outlined, padding: const EdgeInsets.only(bottom: 8)),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('keyword-input'),
                    controller: _controller,
                    enabled: enabled,
                    inputFormatters: [LengthLimitingTextInputFormatter(KeywordBlockRepository.maxLength)],
                    decoration: InputDecoration(labelText: tr.inputLabel, isDense: true),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) async => _add(),
                  ),
                ),
                sizedBoxW8H8,
                FilledButton.tonal(
                  key: const ValueKey('keyword-add'),
                  onPressed: enabled ? _add : null,
                  child: Text(tr.add),
                ),
              ],
            ),
            sizedBoxW12H12,
            BlocBuilder<KeywordBlockCubit, KeywordBlockList>(builder: _buildList),
          ],
        ),
      ),
    );
  }
}

/// One blocked keyword: the keyword, whether it also hides floors, and its removal.
///
/// The switch moves under the keyword when the row is too narrow for everything (small phones, large fonts).
class _KeywordRow extends StatelessWidget {
  const _KeywordRow({
    required this.keyword,
    required this.onAppliesToPostsChanged,
    required this.onRemove,
    super.key,
  });

  final BlockedKeyword keyword;
  final ValueChanged<bool> onAppliesToPostsChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock.keyword;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final title = Text(keyword.keyword, style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600));
    final label = Text(tr.appliesToPosts, style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant));
    final toggle = Switch(value: keyword.appliesToPosts, onChanged: onAppliesToPostsChanged);
    final remove = IconButton(
      icon: const Icon(Icons.delete_outline),
      tooltip: tr.remove,
      onPressed: onRemove,
    );
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(appInnerRadius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 400 * MediaQuery.textScalerOf(context).scale(1);
            if (wide) {
              return Row(
                children: [
                  Expanded(child: title),
                  label,
                  sizedBoxW8H8,
                  toggle,
                  remove,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: title),
                    remove,
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: label),
                    toggle,
                    const SizedBox(width: 4),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

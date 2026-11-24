import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/cubit/website_blocklist_cubit.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/repository/website_blocklist_repository.dart';
import 'package:tsdm_client/features/blocking/widgets/notice_ignore_actions.dart' show BoundClientFactory;
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Localized text of [error].
String websiteBlocklistErrorText(BuildContext context, WebsiteBlocklistError error) {
  final tr = context.t.userBlock.website.failure;
  return switch (error.failure) {
    WebsiteBlocklistFailure.network => tr.network,
    WebsiteBlocklistFailure.notLoggedIn => tr.notLoggedIn,
    WebsiteBlocklistFailure.accountMismatch => tr.accountMismatch,
    WebsiteBlocklistFailure.challenge => tr.challenge,
    WebsiteBlocklistFailure.forumError when error.message != null => tr.forumErrorWith(message: error.message!),
    WebsiteBlocklistFailure.forumError => tr.forumError,
    WebsiteBlocklistFailure.unsupported => tr.unsupported,
    WebsiteBlocklistFailure.targetMismatch => tr.targetMismatch,
    WebsiteBlocklistFailure.notFound => tr.notFound,
    WebsiteBlocklistFailure.notListed => tr.notListed,
    WebsiteBlocklistFailure.unknownAfterSubmit => tr.unknownAfterSubmit,
  };
}

/// The website blacklist (the forum's `blockuser` plugin) of the current account: list, lookup, add, remove, and
/// explicit import of single users into the local block list.
///
/// Kept apart from the local list and the notice rules of the blocking page: this list lives in the forum account.
class WebsiteBlocklistPage extends StatelessWidget {
  /// Constructor.
  const WebsiteBlocklistPage({
    this.repository = const WebsiteBlocklistRepository(),
    this.clientFactory,
    this.openBrowser = openInExternalBrowser,
    super.key,
  });

  /// Forum access, replaceable in tests.
  final WebsiteBlocklistRepository repository;

  /// Builds the client bound to the current account, replaceable in tests.
  final BoundClientFactory? clientFactory;

  /// Opens the website page, replaceable in tests.
  final Future<bool> Function(Uri) openBrowser;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => WebsiteBlocklistCubit(
      auth: context.read<AuthenticationRepository>(),
      localBlocks: context.read<UserBlockCubit>(),
      repository: repository,
      clientFactory: clientFactory,
    ),
    child: _WebsiteBlocklistView(openBrowser: openBrowser),
  );
}

class _WebsiteBlocklistView extends StatefulWidget {
  const _WebsiteBlocklistView({required this.openBrowser});

  final Future<bool> Function(Uri) openBrowser;

  @override
  State<_WebsiteBlocklistView> createState() => _WebsiteBlocklistViewState();
}

class _WebsiteBlocklistViewState extends State<_WebsiteBlocklistView> {
  final _input = TextEditingController();

  /// A confirmation dialog is open: a second tap opens nothing.
  bool _confirming = false;

  /// Route of the confirmation dialog this page opened, while it is open.
  Route<Object?>? _dialog;

  /// Messages belong to this page, so account cleanup never removes another page's notices.
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  WebsiteBlocklistCubit get _cubit => context.read<WebsiteBlocklistCubit>();

  /// The latest result replaces older ones at once instead of queueing behind them.
  void _show(String message) {
    final messenger = _messenger.currentState;
    if (messenger == null) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)));
  }

  /// The account changed: close what this page shows about the old one (the open confirmation names its target, the
  /// last message may name a user). Routes and messages of other pages are left alone.
  void _dropOwnedPopups() {
    _input.clear();
    final route = _dialog;
    _dialog = null;
    final navigator = route?.navigator;
    if (route != null && route.isActive && navigator != null) {
      // Remove immediately: a reverse transition must not keep the old account's target on screen.
      navigator.removeRoute(route);
    }
    _messenger.currentState
      ?..clearSnackBars()
      ..removeCurrentSnackBar();
  }

  /// Ask the question of a write; the dialog is closed (answer null) when the account changes meanwhile.
  Future<bool?> _ask({required String title, required String message, required bool dangerous}) async {
    final cubit = _cubit;
    final generation = cubit.state.generation;
    final route = DialogRoute<bool>(
      context: context,
      // A popped route can still render its reverse animation. Erase its private content as well as removing an
      // active route, so switching accounts during that animation never exposes the previous account's target.
      builder: (dialogContext) => BlocBuilder<WebsiteBlocklistCubit, WebsiteBlocklistState>(
        bloc: cubit,
        builder: (_, state) => state.generation != generation
            ? const SizedBox.shrink()
            : RootPage(
                DialogPaths.question,
                AlertDialog(
                  scrollable: true,
                  title: Text(title),
                  content: SelectableText(message),
                  actions: [
                    TextButton(
                      child: Text(dialogContext.t.general.cancel),
                      onPressed: () => Navigator.pop(dialogContext, false),
                    ),
                    TextButton(
                      child: Text(
                        dialogContext.t.general.ok,
                        style: dangerous ? TextStyle(color: Theme.of(dialogContext).colorScheme.error) : null,
                      ),
                      onPressed: () => Navigator.pop(dialogContext, true),
                    ),
                  ],
                ),
              ),
      ),
    );
    _dialog = route;
    try {
      return await Navigator.of(context, rootNavigator: true).push(route);
    } finally {
      if (identical(_dialog, route)) _dialog = null;
    }
  }

  /// Message of a result that is the same for every action; null for the ones each action words itself.
  String? _commonText(WebsiteBlocklistActionResult result, {WebsiteBlocklistError? error}) {
    final tr = context.t.userBlock.website;
    return switch (result) {
      WebsiteBlocklistActionResult.busy => tr.busy,
      WebsiteBlocklistActionResult.stale => tr.stale,
      WebsiteBlocklistActionResult.staleUnconfirmed => tr.staleUnconfirmed,
      WebsiteBlocklistActionResult.invalidInput => tr.invalidInput,
      WebsiteBlocklistActionResult.selfTarget => tr.selfTarget,
      WebsiteBlocklistActionResult.importUnavailable => tr.importUnavailable,
      WebsiteBlocklistActionResult.alreadyApplied => tr.alreadyApplied,
      WebsiteBlocklistActionResult.failed when error != null => websiteBlocklistErrorText(context, error),
      WebsiteBlocklistActionResult.failed || WebsiteBlocklistActionResult.done => null,
    };
  }

  Future<void> _load() async {
    final result = await _cubit.load();
    if (!mounted) {
      return;
    }
    if (result == WebsiteBlocklistActionResult.stale) {
      _show(context.t.userBlock.invalid);
    }
  }

  Future<void> _lookup() async {
    final result = await _cubit.lookup(_input.text);
    if (!mounted) {
      return;
    }
    // Lookup failures are shown in place; only input problems need a message.
    switch (result) {
      case WebsiteBlocklistActionResult.invalidInput ||
          WebsiteBlocklistActionResult.selfTarget ||
          WebsiteBlocklistActionResult.busy:
        _show(_commonText(result)!);
      case _:
        break;
    }
  }

  Future<void> _openBrowser() async {
    var opened = false;
    try {
      opened = await widget.openBrowser(Uri.parse(websiteBlocklistUrl));
    } on Object catch (e) {
      talker.warning('website blacklist: browser not opened: ${e.runtimeType}');
    }
    if (!opened && mounted) {
      _show(context.t.userBlock.website.browserFailed);
    }
  }

  /// Ask, then run [action] only if the generation the question was asked in is still current.
  Future<void> _confirmThen({
    required String title,
    required String message,
    required bool dangerous,
    required Future<WebsiteBlocklistActionResult> Function(int generation) action,
    required String done,
  }) async {
    if (_confirming || _cubit.state.writing) {
      if (_cubit.state.writing) {
        _show(context.t.userBlock.website.busy);
      }
      return;
    }
    final generation = _cubit.state.generation;
    _confirming = true;
    final bool? ok;
    try {
      ok = await _ask(title: title, message: message, dangerous: dangerous);
    } finally {
      _confirming = false;
    }
    if (!mounted || ok != true || generation != _cubit.state.generation) {
      return;
    }
    final result = await action(generation);
    if (!mounted) {
      return;
    }
    _show(
      result == WebsiteBlocklistActionResult.done
          ? done
          : _commonText(result, error: _cubit.state.error) ?? context.t.userBlock.website.failure.unknownAfterSubmit,
    );
  }

  Future<void> _add(WebsiteBlocklistLookup found) {
    final tr = context.t.userBlock.website;
    return _confirmThen(
      title: tr.addConfirmTitle(name: found.displayName),
      message: tr.addConfirmContent,
      dangerous: false,
      action: (generation) => _cubit.add(found, generation: generation),
      done: tr.added(name: found.displayName),
    );
  }

  Future<void> _remove(WebsiteBlockedUser row) {
    final tr = context.t.userBlock.website;
    return _confirmThen(
      title: tr.removeConfirmTitle(name: row.displayName),
      message: tr.removeConfirmContent,
      dangerous: true,
      action: (generation) => _cubit.remove(row, generation: generation),
      done: tr.removed(name: row.displayName),
    );
  }

  Future<void> _import(WebsiteBlockedUser row) async {
    final tr = context.t.userBlock;
    final (result, local) = await _cubit.importRow(row, generation: _cubit.state.generation);
    if (!mounted) {
      return;
    }
    final String message;
    switch (result) {
      case WebsiteBlocklistActionResult.done:
        message = tr.website.imported(name: row.displayName);
      case WebsiteBlocklistActionResult.alreadyApplied:
        message = tr.website.alreadyLocal;
      case WebsiteBlocklistActionResult.failed:
        message = switch (local) {
          UserBlockResult.selfBlock => tr.selfBlock,
          UserBlockResult.invalid => tr.invalid,
          _ => tr.storageError,
        };
      case _:
        message = _commonText(result)!;
    }
    _show(message);
  }

  Widget _buildAddSection(BuildContext context, WebsiteBlocklistState state) {
    final tr = context.t.userBlock.website;
    final loading = state.lookupStatus == WebsiteLookupStatus.loading;
    final found = state.lookup;
    return AppFormSection(
      title: tr.addTitle,
      icon: Icons.person_add_disabled_outlined,
      children: [
        TextField(
          key: const ValueKey('website-lookup-input'),
          controller: _input,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: tr.inputLabel,
            hintText: tr.inputHint,
            prefixIcon: const Icon(Icons.search),
            filled: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
          ),
          // A result, or a pending answer, belongs to the input it was asked for.
          onChanged: (_) => _cubit.clearLookup(),
          onSubmitted: loading || state.writing ? null : (_) async => _lookup(),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonal(onPressed: loading || state.writing ? null : _lookup, child: Text(tr.lookup)),
            if (loading) const SizedBox.square(dimension: 24, child: CircularProgressIndicator()),
          ],
        ),
        if (state.lookupStatus == WebsiteLookupStatus.failed && state.lookupError != null)
          _ErrorLine(websiteBlocklistErrorText(context, state.lookupError!)),
        if (found != null)
          AppInsetBlock(
            outlined: true,
            padding: edgeInsetsL12T12R12B12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const AppIconTile(Icons.person_outline, size: 32),
                    sizedBoxW12H12,
                    Expanded(
                      child: Text(
                        tr.lookupResult(name: found.displayName, uid: '${found.uid}'),
                        key: const ValueKey('website-lookup-result'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                sizedBoxW8H8,
                if (found.alreadyListed)
                  Text(tr.alreadyListed)
                else if (found.canAdd)
                  FilledButton(
                    key: const ValueKey('website-add'),
                    onPressed: state.writing ? null : () async => _add(found),
                    child: Text(tr.add),
                  )
                else
                  Text(tr.cannotAdd),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    WebsiteBlocklistState state,
    WebsiteBlocklist list,
    WebsiteBlockedUser row,
    UserBlockList local,
    bool localKnown,
  ) {
    final tr = context.t.userBlock.website;
    final both = localKnown && local.isBlocked(row.uid);
    final label = localKnown ? (both ? tr.stateBoth : tr.stateWebsiteOnly) : null;
    final importing = state.importing.contains(row.uid);
    final canImport = localKnown && list.complete && !both;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return AppInsetBlock(
      key: ValueKey('website-row-${row.uid}'),
      outlined: true,
      padding: edgeInsetsL12T12R12B12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIconTile(
                both ? Icons.phone_android_outlined : Icons.public_outlined,
                size: 32,
              ),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.displayName, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    Text(
                      label == null ? 'UID ${row.uid}' : 'UID ${row.uid} · $label',
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          sizedBoxW8H8,
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (canImport)
                OutlinedButton.icon(
                  key: ValueKey('website-import-${row.uid}'),
                  onPressed: importing ? null : () async => _import(row),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(tr.import),
                ),
              if (row.removable)
                TextButton(
                  key: ValueKey('website-remove-${row.uid}'),
                  onPressed: state.writing ? null : () async => _remove(row),
                  child: Text(tr.remove),
                )
              else
                Text(tr.cannotRemove, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, WebsiteBlocklistState state, UserBlockList local) {
    final tr = context.t.userBlock.website;
    final list = state.list;
    final localKnown = local.ownerUid == state.owner && local.status == UserBlockListStatus.ready;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final children = <Widget>[
      AppSectionHeader(tr.title, icon: Icons.public_outlined, padding: EdgeInsets.zero),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton.icon(
            key: const ValueKey('website-load'),
            onPressed: state.status == WebsiteBlocklistStatus.loading || state.writing ? null : _load,
            icon: const Icon(Icons.refresh),
            label: Text(switch (state.status) {
              WebsiteBlocklistStatus.initial => tr.load,
              WebsiteBlocklistStatus.failed => context.t.general.retry,
              _ => tr.reload,
            }),
          ),
          TextButton.icon(
            onPressed: _openBrowser,
            icon: const Icon(Icons.open_in_browser),
            label: Text(tr.openInBrowser),
          ),
          if (state.status == WebsiteBlocklistStatus.loading || state.writing)
            const SizedBox.square(dimension: 24, child: CircularProgressIndicator()),
        ],
      ),
      // Never "empty" before the forum answered.
      if (state.status == WebsiteBlocklistStatus.initial) _NoteLine(tr.notLoaded, icon: Icons.cloud_download_outlined),
      if (state.error != null) _ErrorLine(websiteBlocklistErrorText(context, state.error!)),
      if (list != null) ...[
        AppInsetBlock(
          color: colorScheme.surfaceContainerHigh,
          padding: edgeInsetsL12T12R12B12,
          child: Row(
            children: [
              Icon(Icons.format_list_numbered_outlined, color: colorScheme.primary),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Only a complete list gives the total.
                    Text(
                      list.complete
                          ? tr.count(count: '${list.rows.length}')
                          : tr.countPartial(count: '${list.rows.length}'),
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      switch (list.quota) {
                        WebsiteBlocklistQuota(used: final used?, limit: final limit?) => tr.quotaUsed(
                          used: '$used',
                          limit: '$limit',
                        ),
                        WebsiteBlocklistQuota(limit: final limit?) => tr.quotaLimit(limit: '$limit'),
                        _ => tr.quotaUnknown,
                      },
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!list.complete) _NoteLine(tr.incomplete, warning: true),
        if (!localKnown) _NoteLine(tr.localUnknown),
        if (localKnown && list.complete)
          _NoteLine(
            tr.localOnly(count: '${local.uids.difference(list.uids).length}'),
            icon: Icons.phone_android_outlined,
          ),
        // No rows on a partial page is not an empty list.
        if (list.rows.isEmpty && list.complete) _NoteLine(tr.empty, icon: Icons.inbox_outlined),
        ...list.rows.map((row) => _buildRow(context, state, list, row, local, localKnown)),
      ],
    ];
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) sizedBoxW8H8, children[i]],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock.website;
    return BlocListener<WebsiteBlocklistCubit, WebsiteBlocklistState>(
      // Another account: nothing of the old one (typed uid, open confirmation, last message) is carried over.
      listenWhen: (a, b) => a.generation != b.generation,
      listener: (_, _) => _dropOwnedPopups(),
      child: ScaffoldMessenger(
        key: _messenger,
        child: Scaffold(
          appBar: AppBar(title: Text(tr.title)),
          body: SafeArea(
            top: false,
            bottom: false,
            child: BlocBuilder<WebsiteBlocklistCubit, WebsiteBlocklistState>(
              builder: (context, state) => BlocBuilder<UserBlockCubit, UserBlockList>(
                builder: (context, local) => AppCenteredList(
                  maxWidth: appFormMaxWidth,
                  builder: (context, side, _) => ListView(
                    padding: side.copyWith(top: 12, bottom: 12).add(context.safePadding()),
                    children: [
                      AppNoticeBanner(message: tr.hint),
                      const SizedBox(height: appSurfaceGap),
                      if (state.owner == null)
                        AppStateView(icon: Icons.login, message: context.t.userBlock.invalid, scrollable: false)
                      else ...[
                        _buildAddSection(context, state),
                        const SizedBox(height: appSurfaceGap),
                        _buildList(context, state, local),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => AppNoticeBanner(message: text, tone: AppNoticeTone.error);
}

/// A remark about the list (not loaded, incomplete, local only count); [warning] for a limit of the list.
class _NoteLine extends StatelessWidget {
  const _NoteLine(this.text, {this.icon = Icons.info_outline, this.warning = false});

  final String text;
  final IconData icon;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    if (warning) {
      return AppNoticeBanner(message: text, tone: AppNoticeTone.warning, icon: Icons.warning_amber_outlined);
    }
    final colorScheme = Theme.of(context).colorScheme;
    return AppInsetBlock(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
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

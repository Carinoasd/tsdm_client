import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/post/cubit/poll_create_cubit.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Upstream JS starts the website form with three choice rows.
const _initialOptionRows = 3;

/// Shown for a malformed route instead of requesting anything.
class PollCreateInvalidPage extends StatelessWidget {
  /// Constructor.
  const PollCreateInvalidPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.t.pollCreate.title)),
    body: AppStateView(icon: Icons.web_outlined, message: context.t.pollCreate.state.unsupported),
  );
}

/// Create an ordinary single or multiple choice poll thread in forum [fid].
///
/// The form, confirmation and result stay inside this page, so leaving it or changing account drops every private
/// value at once.
class PollCreatePage extends StatefulWidget {
  /// Constructor.
  const PollCreatePage({required this.fid, this.transfer, this.repositoryBuilder, this.authChanges, super.key});

  /// Forum id.
  final String fid;

  /// Test seam: account-bound repository instead of the global network client.
  @visibleForTesting
  final PollCreateRepository Function(int? Function() currentUid)? repositoryBuilder;

  /// Test seam: authentication stream instead of the repository's.
  @visibleForTesting
  final Stream<AuthStatus>? authChanges;

  /// Subject and body carried over from the ordinary editor.
  final ThreadModeTransfer? transfer;

  @override
  State<PollCreatePage> createState() => _PollCreatePageState();
}

class _PollCreatePageState extends State<PollCreatePage> {
  final _subject = TextEditingController();
  final _body = TextEditingController();
  final _maxChoices = TextEditingController(text: '1');
  final _expiry = TextEditingController();
  final _options = <TextEditingController>[for (var i = 0; i < _initialOptionRows; i++) TextEditingController()];

  bool _visibleAfterVote = false;
  bool _publicVoters = false;

  /// Selected positive thread type; null is "no type", which polls always allow.
  PostEditThreadType? _threadType;
  Map<String, PostEditContentOption> _extras = {};
  PollCreateForm? _appliedForm;
  PollValidation? _validation;

  late final PollCreateCubit _cubit;

  /// Route hosting this page; once it is popped, replaced or removed the session ends.
  ModalRoute<Object?>? _route;

  /// What the thread editor switched from handed over (for this account and forum), passed on when switching back.
  ThreadModeTransfer? _carried;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthenticationRepository>();
    final transfer = widget.transfer;
    if (transfer != null && transfer.appliesTo(uid: auth.effectiveCurrentUid, fid: widget.fid)) {
      _carried = transfer;
      _subject.text = transfer.subject;
      _body.text = transfer.body;
    }
    int? currentUid() => auth.effectiveCurrentUid;
    _cubit = PollCreateCubit(
      repository:
          widget.repositoryBuilder?.call(currentUid) ??
          PollCreateRepository(client: getIt.get<NetClientProvider>(), currentUid: currentUid),
      fid: widget.fid,
      authChanges: widget.authChanges ?? auth.status,
      // Checked before every operation and immediately before the POST: a route that left the navigator (pop,
      // replacement, programmatic removal) can no longer act, even from a callback captured earlier.
      isActive: () => _route?.isActive ?? true,
    );
    unawaited(_cubit.load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route = route;
      // End at the pop itself, not when the exit animation finishes and the page is disposed.
      unawaited(route?.popped.whenComplete(_cubit.endSession));
    }
  }

  @override
  void dispose() {
    unawaited(_cubit.close());
    _subject.dispose();
    _body.dispose();
    _maxChoices.dispose();
    _expiry.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  /// Removed rows are still attached to their fields until the next frame.
  static void _disposeLater(TextEditingController controller) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());

  /// Selectable thread types; the served neutral `0` entry is shown as "no type" instead.
  static List<PostEditThreadType> _positiveTypes(PollCreateForm form) => [
    for (final type in form.content.threadTypeList ?? const <PostEditThreadType>[])
      if ((int.tryParse(type.typeID ?? '') ?? 0) > 0) type,
  ];

  void _clearPrivateInput() {
    _subject.clear();
    _body.clear();
    _maxChoices.text = '1';
    _expiry.clear();
    for (final option in _options) {
      option.clear();
      _disposeLater(option);
    }
    _options
      ..clear()
      ..addAll([for (var i = 0; i < _initialOptionRows; i++) TextEditingController()]);
    _visibleAfterVote = false;
    _publicVoters = false;
    _threadType = null;
    _extras = {};
    _appliedForm = null;
    _validation = null;
  }

  /// A reloaded form keeps everything the user typed or chose.
  ///
  /// A choice the new form no longer offers (type, flag, bool option) stays selected and is reported by validation,
  /// so nothing the user confirmed disappears silently.
  void _applyForm(PollCreateForm form) {
    final first = _appliedForm == null;
    final previousExtras = _extras;
    final offered = {for (final option in form.extraOptions) option.name};
    _extras = {
      for (final option in form.extraOptions)
        option.name: first || !previousExtras.containsKey(option.name) || option.disabled
            ? option
            : option.copyWith(checked: previousExtras[option.name]!.checked),
      if (!first)
        for (final option in previousExtras.values)
          if (option.checked && !offered.contains(option.name)) option.name: option,
    };
    if (first) {
      _maxChoices.text = '${form.initialMaxChoices}';
      _expiry.text = form.initialExpiration;
      _visibleAfterVote = form.visibility?.initiallyChecked ?? false;
      _publicVoters = form.overt?.initiallyChecked ?? false;
      final selected = form.content.threadType;
      _threadType = _positiveTypes(form).where((e) => e.typeID == selected?.typeID).firstOrNull;
    }
    _appliedForm = form;
  }

  void _onState(BuildContext context, PollCreateState state) {
    if (state.status == PollCreateStatus.identityChanged) {
      setState(_clearPrivateInput);
      return;
    }
    final form = state.form;
    if (form != null && !identical(form, _appliedForm)) {
      setState(() => _applyForm(form));
    }
    if (form != null && state.status == PollCreateStatus.preflightFailed) {
      // Highlight what the changed form no longer accepts; this is local validation only.
      setState(() => _validation = validatePollDraft(_draft(), form));
    }
  }

  PollDraft _draft() => PollDraft(
    subject: _subject.text,
    message: _body.text,
    options: _options.map((e) => e.text).toList(),
    maxChoices: _maxChoices.text,
    expiry: _expiry.text,
    visibleAfterVote: _visibleAfterVote,
    publicVoters: _publicVoters,
    threadType: _threadType,
    extraOptions: _extras.values.toList(),
  );

  void _review(BuildContext context) {
    final validation = _cubit.review(_draft());
    setState(() => _validation = validation);
    if (validation != null && !validation.isValid) {
      showSnackBar(context: context, message: context.t.pollCreate.fixIssues);
    }
  }

  Future<void> _openBrowser(BuildContext context, String url) async {
    try {
      await openInExternalBrowser(Uri.parse(url));
    } on Object {
      if (context.mounted) showSnackBar(context: context, message: context.t.general.failedToLoad);
    }
  }

  void _switchToThread(BuildContext context) {
    if (!_cubit.canSwitchMode) return;
    final uid = context.read<AuthenticationRepository>().effectiveCurrentUid;
    context.pushReplacementNamed(
      ScreenPaths.editPost,
      pathParameters: {'editType': '${PostEditType.newThread.index}', 'fid': widget.fid},
      queryParameters: {'poll': '1'},
      extra: uid == null
          ? null
          : ThreadModeTransfer(
              uid: uid,
              fid: widget.fid,
              subject: _subject.text,
              body: _body.text,
              // The settings of the other kinds the member came with, for when they are back there.
              rewardPrice: _carried?.rewardPrice,
              hongbao: _carried?.hongbao,
              // Not the editor's document: the body was edited as text here.
              typeId: _carried?.typeId,
            ),
    );
  }

  String _issueText(BuildContext context, PollInputIssue issue, PollCreateForm form) {
    final tr = context.t.pollCreate.issues;
    return switch (issue) {
      PollInputIssue.subjectEmpty => tr.subjectEmpty,
      PollInputIssue.subjectTooLong => tr.subjectTooLong(limit: form.subjectLimit),
      PollInputIssue.threadTypeUnavailable => tr.threadTypeUnavailable,
      PollInputIssue.flagUnavailable => tr.flagUnavailable,
      PollInputIssue.extraOptionUnavailable => tr.extraOptionUnavailable,
      PollInputIssue.optionLineBreak => tr.optionLineBreak,
      PollInputIssue.optionTooLong => tr.optionTooLong,
      PollInputIssue.tooFewOptions => tr.tooFewOptions,
      PollInputIssue.tooManyOptions => tr.tooManyOptions(max: form.maxOptions),
      PollInputIssue.maxChoicesInvalid => tr.maxChoicesInvalid,
      PollInputIssue.expiryInvalid => tr.expiryInvalid,
    };
  }

  String? _fieldError(BuildContext context, PollCreateForm form, List<PollInputIssue> candidates) {
    final issues = _validation?.issues ?? const <PollInputIssue>{};
    final issue = candidates.where(issues.contains).firstOrNull;
    return issue == null ? null : _issueText(context, issue, form);
  }

  /// Centered form list: full width scroll view (scrollbar, drag anywhere), rows at most the form width.
  Widget _formList({required Key key, required List<Widget> children}) => AppCenteredList(
    maxWidth: appFormMaxWidth,
    builder: (context, horizontal, width) => ListView(
      key: key,
      padding: horizontal.add(const EdgeInsets.symmetric(vertical: 12)).add(context.safePadding()),
      children: children,
    ),
  );

  Widget _buildMessage(
    BuildContext context,
    String message,
    List<Widget> actions, {
    IconData icon = Icons.info_outline,
    bool error = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconTile(
                icon,
                size: 64,
                color: error ? colorScheme.errorContainer : colorScheme.secondaryContainer,
                foregroundColor: error ? colorScheme.onErrorContainer : colorScheme.onSecondaryContainer,
              ),
              sizedBoxW16H16,
              SelectableText(message, textAlign: TextAlign.center),
              sizedBoxW16H16,
              Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: actions),
            ],
          ),
        ),
      ),
    );
  }

  Widget _browserButton(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.open_in_browser_outlined),
    label: Text(context.t.pollCreate.openBrowser),
    onPressed: () async => _openBrowser(context, PollCreateRepository.formUrl(widget.fid)),
  );

  Widget _reloadButton(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.refresh_outlined),
    label: Text(context.t.pollCreate.reload),
    onPressed: () async => _cubit.load(),
  );

  Widget _banner(BuildContext context, String title, String message, List<Widget> actions) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: AppNoticeBanner(
      tone: AppNoticeTone.error,
      title: title,
      message: message,
      selectable: true,
      actions: actions,
    ),
  );

  /// Nothing was posted: the fresh form check stopped before sending.
  Widget _preflightBanner(BuildContext context, PollCreateState state) {
    final tr = context.t.pollCreate.preflight;
    final message = switch (state.preflight) {
      PollPreflightKind.changed => tr.changed,
      PollPreflightKind.denied =>
        (state.message?.isNotEmpty ?? false) ? '${state.message!}\n\n${tr.denied}' : tr.denied,
      PollPreflightKind.unsupported => tr.unsupported,
      PollPreflightKind.loginRequired => tr.loginRequired,
      _ => tr.failed,
    };
    return _banner(context, tr.title, message, [
      if (state.preflight == PollPreflightKind.loginRequired) _reloadButton(context),
      _browserButton(context),
    ]);
  }

  Widget _buildEditor(BuildContext context, PollCreateState state, PollCreateForm form) {
    final tr = context.t.pollCreate;
    final theme = Theme.of(context);
    final types = _positiveTypes(form);
    final typeOffered = types.any((e) => e.typeID == _threadType?.typeID);
    final filled = _options.where((e) => e.text.trim().isNotEmpty).length;
    final optionListError = _fieldError(context, form, const [
      PollInputIssue.tooFewOptions,
      PollInputIssue.tooManyOptions,
    ]);
    final flagError = _fieldError(context, form, const [PollInputIssue.flagUnavailable]);
    final offeredExtras = {for (final option in form.extraOptions) option.name};
    final shownExtras = _extras.values.where((e) => offeredExtras.contains(e.name) || e.checked).toList();

    return _formList(
      key: const ValueKey('poll-editor'),
      children: [
        if (state.status == PollCreateStatus.rejected)
          _banner(
            context,
            tr.result.rejectedTitle,
            (state.message?.isNotEmpty ?? false) ? state.message! : tr.result.rejectedFallback,
            [_reloadButton(context), _browserButton(context)],
          ),
        if (state.status == PollCreateStatus.preflightFailed) _preflightBanner(context, state),
        // Where the poll goes and what it is about.
        AppFormSection(
          children: [
            Row(
              children: [
                Icon(Icons.forum_outlined, size: 18, color: theme.colorScheme.primary),
                sizedBoxW8H8,
                Expanded(
                  child: Text(
                    tr.forum(forum: form.forumName ?? '#${form.fid}'),
                    style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
            // Optional for polls: upstream exempts special threads from a forum's required type.
            if (types.isNotEmpty || _threadType != null)
              InputDecorator(
                decoration: InputDecoration(
                  labelText: tr.threadType,
                  helperText: tr.threadTypeOptional,
                  helperMaxLines: 2,
                  errorMaxLines: 3,
                  errorText: _fieldError(context, form, const [PollInputIssue.threadTypeUnavailable]),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: typeOffered ? _threadType!.typeID : null,
                    isDense: true,
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(child: Text(tr.threadTypeNone)),
                      for (final type in types) DropdownMenuItem(value: type.typeID, child: Text(type.name)),
                    ],
                    onChanged: (id) => setState(() => _threadType = types.where((e) => e.typeID == id).firstOrNull),
                  ),
                ),
              ),
            TextField(
              controller: _subject,
              decoration: InputDecoration(
                labelText: tr.subject,
                suffixText: tr.subjectCounter(
                  used: discuzStrLen(discuzEscape(_subject.text.trim())),
                  limit: form.subjectLimit,
                ),
                errorText: _fieldError(context, form, const [
                  PollInputIssue.subjectEmpty,
                  PollInputIssue.subjectTooLong,
                ]),
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _body,
              minLines: 3,
              maxLines: 10,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(labelText: tr.body, hintText: tr.bodyHint, alignLabelWithHint: true),
            ),
          ],
        ),
        appListSeparator,
        // Choices: count and list problems in the header, one row per choice.
        AppFormSection(
          gap: 0,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.poll_outlined, size: 20, color: theme.colorScheme.primary),
                sizedBoxW8H8,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr.options, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                      Text(
                        tr.optionCount(count: filled, max: form.maxOptions),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: optionListError == null ? theme.colorScheme.outline : theme.colorScheme.error,
                        ),
                      ),
                      if (optionListError != null)
                        Text(
                          optionListError,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            for (var i = 0; i < _options.length; i++)
              Padding(
                key: ObjectKey(_options[i]),
                padding: edgeInsetsT8,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _options[i],
                        decoration: InputDecoration(
                          labelText: tr.optionLabel(index: i + 1),
                          errorText: _validation?.optionIssues[i] == null
                              ? null
                              : _issueText(context, _validation!.optionIssues[i]!, form),
                          errorMaxLines: 4,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    IconButton(
                      tooltip: tr.removeOption,
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: _options.length <= 2
                          ? null
                          : () => setState(() {
                              _disposeLater(_options.removeAt(i));
                              _validation = null;
                            }),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: Text(tr.addOption),
                onPressed: _options.length >= form.maxOptions
                    ? null
                    : () => setState(() => _options.add(TextEditingController())),
              ),
            ),
          ],
        ),
        appListSeparator,
        // Rules of the vote.
        AppFormSection(
          gap: 4,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // Side by side when both fit, otherwise one per row at the full width of the section.
                final fieldWidth = constraints.maxWidth >= 2 * 240 + 16
                    ? (constraints.maxWidth - 16) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: _maxChoices,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          labelText: tr.maxChoices,
                          helperText: tr.maxChoicesHelper,
                          helperMaxLines: 3,
                          errorMaxLines: 3,
                          errorText: _fieldError(context, form, const [PollInputIssue.maxChoicesInvalid]),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: _expiry,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: tr.expiry,
                          helperText: tr.expiryHelper,
                          helperMaxLines: 3,
                          errorMaxLines: 3,
                          errorText: _fieldError(context, form, const [PollInputIssue.expiryInvalid]),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            // A flag the form stopped offering stays visible while on, so the user decides instead of it vanishing.
            if (form.visibility != null || _visibleAfterVote)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.visibleAfterVote),
                subtitle: form.visibility == null && flagError != null
                    ? Text(flagError, style: TextStyle(color: theme.colorScheme.error))
                    : null,
                value: _visibleAfterVote,
                onChanged: (value) => setState(() => _visibleAfterVote = value),
              ),
            if (form.overt != null || _publicVoters)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.publicVoters),
                subtitle: form.overt == null && flagError != null
                    ? Text(flagError, style: TextStyle(color: theme.colorScheme.error))
                    : null,
                value: _publicVoters,
                onChanged: (value) => setState(() => _publicVoters = value),
              ),
          ],
        ),
        if (shownExtras.isNotEmpty) ...[
          appListSeparator,
          AppFormSection(
            title: tr.additionalOptions,
            icon: Icons.tune_outlined,
            gap: 0,
            children: [
              for (final option in shownExtras)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(option.readableName),
                  subtitle: offeredExtras.contains(option.name)
                      ? null
                      : Text(tr.issues.extraOptionUnavailable, style: TextStyle(color: theme.colorScheme.error)),
                  value: option.checked,
                  onChanged: option.disabled
                      ? null
                      : (value) => setState(() => _extras[option.name] = option.copyWith(checked: value)),
                ),
            ],
          ),
        ],
        sizedBoxW16H16,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: theme.colorScheme.outline),
            sizedBoxW8H8,
            Expanded(
              child: Text(
                tr.noDraft,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
        ),
        Align(alignment: Alignment.centerLeft, child: _browserButton(context)),
        sizedBoxW12H12,
        FilledButton.icon(
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(tr.review),
          onPressed: () => _review(context),
        ),
      ],
    );
  }

  Widget _buildReview(BuildContext context, PollCreateState state, PollCreateForm form, PollSubmission poll) {
    final tr = context.t.pollCreate.confirm;
    final theme = Theme.of(context);
    final submitting = state.status == PollCreateStatus.submitting;
    final checking = state.status == PollCreateStatus.checking;

    Widget row(String label, Widget value) => Padding(
      padding: edgeInsetsT8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
          sizedBoxW2H2,
          value,
        ],
      ),
    );

    return _formList(
      key: const ValueKey('poll-review'),
      children: [
        Row(
          children: [
            const AppIconTile(Icons.fact_check_outlined),
            sizedBoxW12H12,
            Expanded(child: Text(tr.title, style: theme.textTheme.titleLarge)),
          ],
        ),
        sizedBoxW12H12,
        // Everything that will be sent, in one surface.
        AppSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row(tr.forum, Text(form.forumName ?? '#${form.fid}')),
              if (poll.threadType != null) row(tr.threadType, Text(poll.threadType!.name)),
              row(tr.subject, SelectableText(poll.subject)),
              row(
                tr.body,
                poll.message.trim().isEmpty
                    ? Text(tr.bodyEmpty)
                    : Text(poll.message, maxLines: 6, overflow: TextOverflow.ellipsis),
              ),
              row(
                tr.options(count: poll.options.length),
                AppInsetBlock(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < poll.options.length; i++) SelectableText('${i + 1}. ${poll.options[i]}'),
                    ],
                  ),
                ),
              ),
              row(tr.choices, Text(poll.maxChoices == 1 ? tr.single : tr.multiple(count: poll.maxChoices))),
              row(tr.expiry, Text(poll.expiryDays == 0 ? tr.unlimited : tr.days(days: poll.expiryDays))),
              if (form.visibility != null) row(tr.visibleAfterVote, Text(poll.visibleAfterVote ? tr.yes : tr.no)),
              if (form.overt != null) row(tr.publicVoters, Text(poll.publicVoters ? tr.yes : tr.no)),
              if (poll.extraOptions.isNotEmpty)
                row(tr.additionalOptions, Text(poll.extraOptions.map((e) => e.readableName).join(', '))),
            ],
          ),
        ),
        sizedBoxW12H12,
        AppNoticeBanner(tone: AppNoticeTone.error, icon: Icons.warning_amber_outlined, message: tr.warning),
        if (checking) ...[sizedBoxW8H8, Text(context.t.pollCreate.checking)],
        if (submitting) ...[sizedBoxW8H8, Text(context.t.pollCreate.submitting)],
        sizedBoxW16H16,
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          runSpacing: 8,
          children: [
            // Going back while checking cancels the check; nothing has been sent yet.
            OutlinedButton(onPressed: submitting ? null : _cubit.cancelReview, child: Text(tr.back)),
            FilledButton.icon(
              icon: submitting || checking ? sizedCircularProgressIndicator : const Icon(Icons.send),
              label: Text(tr.submit),
              onPressed: _cubit.canConfirm ? () async => _cubit.confirm() : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context, PollCreateState state) {
    final tr = context.t.pollCreate.result;
    final tid = state.tid;
    final (IconData icon, String title, String message) = switch (state.status) {
      PollCreateStatus.published => (Icons.check_circle_outline, tr.publishedTitle, tr.published),
      PollCreateStatus.moderated => (Icons.hourglass_top_outlined, tr.moderatedTitle, tr.moderated),
      _ => (Icons.help_outline, tr.unconfirmedTitle, tr.unconfirmed),
    };
    final unconfirmed = state.status == PollCreateStatus.unconfirmed;

    return _buildMessage(context, '$title\n\n$message', icon: icon, error: unconfirmed, [
      if (tid != null)
        FilledButton(
          onPressed: () => context.pushReplacementNamed(ScreenPaths.threadV1, queryParameters: {'tid': tid}),
          child: Text(tr.openThread),
        ),
      if (unconfirmed) ...[
        OutlinedButton(
          onPressed: () async => context.pushNamed(ScreenPaths.forum, pathParameters: {'fid': widget.fid}),
          child: Text(tr.openForum),
        ),
        OutlinedButton(
          onPressed: () async => _openBrowser(context, '$baseUrl/forum.php?mod=forumdisplay&fid=${widget.fid}'),
          child: Text(tr.openForumBrowser),
        ),
        TextButton(onPressed: _cubit.resolveUnconfirmed, child: Text(tr.resolve)),
      ] else
        TextButton(onPressed: () => context.pop(), child: Text(tr.back)),
    ]);
  }

  Widget _buildBody(BuildContext context, PollCreateState state) {
    final tr = context.t.pollCreate;
    final form = state.form;
    return switch (state.status) {
      PollCreateStatus.loading => const CenteredCircularIndicator(),
      PollCreateStatus.loadFailed => _buildMessage(
        context,
        tr.state.loadFailed,
        icon: Icons.error_outline,
        error: true,
        [
          _reloadButton(context),
          _browserButton(context),
        ],
      ),
      PollCreateStatus.loginRequired => _buildMessage(context, tr.state.loginRequired, icon: Icons.login_outlined, [
        _reloadButton(context),
        _browserButton(context),
      ]),
      PollCreateStatus.denied => _buildMessage(
        context,
        (state.message?.isNotEmpty ?? false) ? state.message! : tr.state.denied,
        icon: Icons.block_outlined,
        error: true,
        [_browserButton(context)],
      ),
      PollCreateStatus.unsupported => _buildMessage(context, tr.state.unsupported, icon: Icons.web_outlined, [
        _browserButton(context),
      ]),
      PollCreateStatus.identityChanged => _buildMessage(
        context,
        state.interruptedSubmit ? tr.state.accountChangedDuringSubmit : tr.state.accountChanged,
        icon: Icons.manage_accounts_outlined,
        const [],
      ),
      PollCreateStatus.editing ||
      PollCreateStatus.rejected ||
      PollCreateStatus.preflightFailed when form != null => _buildEditor(context, state, form),
      PollCreateStatus.reviewing || PollCreateStatus.checking || PollCreateStatus.submitting
          when form != null && state.submission != null =>
        _buildReview(context, state, form, state.submission!),
      PollCreateStatus.unconfirmed || PollCreateStatus.published || PollCreateStatus.moderated => _buildResult(
        context,
        state,
      ),
      _ => const CenteredCircularIndicator(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<PollCreateCubit, PollCreateState>(
        listener: _onState,
        builder: (context, state) {
          final canSwitch = const {
            PollCreateStatus.editing,
            PollCreateStatus.rejected,
            PollCreateStatus.preflightFailed,
            PollCreateStatus.loadFailed,
            PollCreateStatus.loginRequired,
            PollCreateStatus.denied,
            PollCreateStatus.unsupported,
          }.contains(state.status);
          // Only the POST blocks leaving; leaving during the fresh form check cancels it before any POST.
          return PopScope(
            canPop: state.status != PollCreateStatus.submitting,
            child: Scaffold(
              appBar: AppBar(
                title: Text(context.t.pollCreate.title),
                // The account the poll is posted as, like the thread editor (#184).
                bottom: postingAsBarOf(context),
                actions: [
                  if (canSwitch)
                    IconButton(
                      tooltip: context.t.pollCreate.switchToThread,
                      icon: const Icon(Icons.article_outlined),
                      onPressed: () => _switchToThread(context),
                    ),
                ],
              ),
              body: SafeArea(bottom: false, child: _buildBody(context, state)),
            ),
          );
        },
      ),
    );
  }
}

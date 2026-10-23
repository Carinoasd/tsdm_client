import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/utils/offline_floor.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// Ordinary poll embedded in the first post, shared by both thread readers.
///
/// The page holding the post already holds the poll form ([fromPage]): the card shows it and asks the forum for the
/// post's page only when it has to, which is when the form is not there, is there for another account than the
/// current one or as for a guest while an account is in use, or was read before a vote of the account (see
/// [PollCubit.adopt]), on refresh, once after a vote for the results, and once after a login of the account in use
/// while the card asks to log in, from its button or elsewhere. In the thread page the card does not follow the
/// account: the page reloads for a new one and builds its floors, this card included, afresh (every card asked for
/// the whole thread page again on each account status, twice when created); only a card such a reload left on screen
/// with the poll of the account before asks for the poll itself, once. Elsewhere (the post of a notice) nothing
/// reloads the post, the card loads again itself when the account changed.
///
/// With the forum's app API 2.8.0 the page gives the poll as fields ([fromSpecial], the thread's `special`), shown the
/// same way instead of the form. A vote the forum's result says was taken calls [onVoted] (the thread page reloads
/// and builds the card again with the poll as the forum now has it) instead of asking for the results; a refused vote
/// shows the forum's message.
class PollCard extends StatefulWidget {
  /// [controller] permits deterministic UI tests; production creates its own.
  const PollCard(this.pid, {super.key, this.fromPage, this.fromSpecial, this.onVoted, this.controller});

  /// First post identifier used by the forum redirect route.
  final String pid;

  /// The poll form of the page the post was read from, null when not known.
  final PostPoll? fromPage;

  /// The poll of the page the post was read from as the forum's app API gives it (plugin 2.8.0); preferred over
  /// [fromPage].
  final PollSpecial? fromSpecial;

  /// Reload the thread page after a vote the forum took; null where nothing reloads.
  final VoidCallback? onVoted;

  /// Optional test controller, owned by its caller.
  final PollCubit? controller;
  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  late PollCubit _cubit;
  StreamSubscription<AuthStatus>? _authSubscription;

  /// The states of the thread page holding the card, for [_followThreadLoads]; null elsewhere.
  StreamSubscription<ThreadState>? _threadSubscription;

  /// A check of [_followThreadLoads] waits for the end of the frame.
  bool _threadLoadCheck = false;

  /// The states of [_cubit], for [_followLogins].
  StreamSubscription<PollState>? _stateSubscription;

  /// Logins of the account [_loginUid], while the card asks it to log in (see [_followLogins]).
  StreamSubscription<AuthStatus>? _loginSubscription;
  int? _loginUid;

  /// The card asked the forum since its last answer ([PollState.busy]), the latest account status when it last began
  /// to ([AuthenticationRepository.latestStatus]); see [_followLogins].
  bool _asked = false;
  AuthStatus? _statusWhenAsked;

  /// Login pages opened from the card ([_login]) and not closed yet.
  int _loginPages = 0;

  /// The thread page's memory of its floors: the choices made and not sent yet stay when the card is built again
  /// (floors are not kept alive).
  MunchCache? _memory;
  String get _memoryKey => 'poll:${widget.pid}';
  StreamSubscription<PollState>? _restoreSubscription;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    if (widget.controller case final controller?) {
      _cubit = controller;
      unawaited(_cubit.load());
      return;
    }
    final auth = context.read<AuthenticationRepository>();
    _cubit = PollCubit(
      url: '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=${Uri.encodeQueryComponent(widget.pid)}',
      currentUid: () => auth.effectiveCurrentUid,
      repository: () => PollRepository.network(getIt.get<NetClientProvider>()),
      onVoted: widget.onVoted,
    );
    _stateSubscription = _cubit.stream.listen((state) => _followLogins(auth, state));
    final special = widget.fromSpecial;
    final page = widget.fromPage;
    final adopted = special != null
        ? _cubit.adoptSpecial(special)
        : page != null && _cubit.adopt(page.form, servedUid: page.viewerUid);
    if (!adopted) {
      unawaited(_cubit.load());
    }
    _memory = MunchCacheScope.find(context);
    if (_memory?.recall(_memoryKey) case final Set<String> choices) {
      void restore() {
        for (final id in choices) {
          _cubit.select(id, selected: true);
        }
      }

      if (_cubit.state.poll != null) {
        restore();
      } else {
        _restoreSubscription = _cubit.stream.listen((state) {
          if (state.poll != null || state.failed) {
            unawaited(_restoreSubscription?.cancel());
            _restoreSubscription = null;
            if (state.poll != null) {
              restore();
            }
          }
        });
      }
    }
    final thread = context.readOrNull<ThreadBloc>();
    if (thread == null) {
      // No thread above: the notice page, which does not reload for another account.
      _authSubscription = listenAccountChanges(
        auth,
        onLoggingIn: _cubit.invalidate,
        onChanged: () => unawaited(_cubit.load()),
      );
    } else {
      _threadSubscription = thread.stream.listen((state) => _followThreadLoads(auth, state));
    }
  }

  /// Load once for the account in use when a load of the thread page ended and left this card on screen with the poll
  /// of another account ([PollState.uid]).
  ///
  /// The thread page reloads for a new account and builds its floors afresh, this card with the form of the new page.
  /// A reload that fails puts the floors read before back on screen (see ThreadBloc), built again: their card asks for
  /// the poll ([PollCubit.adopt]). One failing at once (no connection) ends before the frame that would show the page
  /// loading, and those floors are not built again: the card kept the poll of the account before, options that did
  /// nothing for the account in use ([PollCubit.select]). Checked once the frame showing the end of the load is built,
  /// by then a card built again shows the form of its page. Nothing is asked while the card shows or asks for the poll
  /// of the account in use, as after any load without an account change, and nothing for a reload still to come: the
  /// thread page reloads only when on top (a page or the menu of a switch above it waits), its states come then.
  void _followThreadLoads(AuthenticationRepository auth, ThreadState state) {
    if (state.status == ThreadStatus.initial || state.status == ThreadStatus.loading || _threadLoadCheck) {
      return;
    }
    _threadLoadCheck = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _threadLoadCheck = false;
      // A vote reloads the thread page ([PollCubit.onVoted]): a reload that failed at once left this card waiting.
      if (mounted && (_cubit.state.uid != auth.effectiveCurrentUid || _cubit.awaitsReload)) {
        unawaited(_cubit.load());
      }
    });
  }

  /// Load once after a login of the account in use while the card asks that account to log in ([state]).
  ///
  /// The forum served the post as to a guest although an account is in use: the session of that account had expired
  /// (issue #25). Logging that account in again elsewhere (manage accounts, for example) is no change of the account in
  /// use, for which neither the thread page nor a card of a notice ([listenAccountChanges]) reload, and the card kept
  /// asking to log in. Only in that state: a card showing its form asks nothing on a status (every card asked for the
  /// whole thread page again on each). A login from the button of the card loads once its page closes ([_login]).
  ///
  /// The logins are not followed while the card asks the forum. A login ending meanwhile does not help the request
  /// already sent: it went out with the session the forum dropped and is answered with the page of a guest, and the
  /// listener of that answer took the login for the status replayed to it ([listenLoginsOf]): the card stayed asking to
  /// log in. It loads once more at once instead when the account logged in since the card last began to ask
  /// ([loggedInSince]); a request sent after the login is answered for the new session, as asked.
  void _followLogins(AuthenticationRepository auth, PollState state) {
    if (state.busy) {
      _asked = true;
      _statusWhenAsked = auth.latestStatus;
      _stopFollowingLogins();
      return;
    }
    final asked = _asked;
    final statusWhenAsked = _statusWhenAsked;
    _asked = false;
    _statusWhenAsked = null;
    final uid = state.uid;
    if (uid == null || state.poll?.availability != PollAvailability.loginRequired) {
      _stopFollowingLogins();
      return;
    }
    if (asked && _loginPages == 0 && loggedInSince(auth, statusWhenAsked, uid)) {
      unawaited(_cubit.load());
      return;
    }
    if (_loginSubscription != null && _loginUid == uid) {
      return;
    }
    _stopFollowingLogins();
    _loginUid = uid;
    _loginSubscription = listenLoginsOf(
      auth,
      uid,
      onLogin: () {
        final current = _cubit.state;
        if (_loginPages == 0 && current.uid == uid && current.poll?.availability == PollAvailability.loginRequired) {
          unawaited(_cubit.load());
        }
      },
    );
  }

  void _stopFollowingLogins() {
    unawaited(_loginSubscription?.cancel());
    _loginSubscription = null;
    _loginUid = null;
  }

  /// Stop following what [_start] follows for [_cubit].
  void _stop() {
    unawaited(_authSubscription?.cancel());
    _authSubscription = null;
    unawaited(_threadSubscription?.cancel());
    _threadSubscription = null;
    unawaited(_stateSubscription?.cancel());
    _stateSubscription = null;
    _stopFollowingLogins();
    _asked = false;
    _statusWhenAsked = null;
  }

  @override
  void didUpdateWidget(PollCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pid != widget.pid ||
        oldWidget.controller != widget.controller ||
        oldWidget.fromPage != widget.fromPage ||
        oldWidget.fromSpecial != widget.fromSpecial) {
      _stop();
      if (oldWidget.controller == null) unawaited(_cubit.close());
      _start();
    }
  }

  @override
  void dispose() {
    unawaited(_restoreSubscription?.cancel());
    if (widget.controller == null) {
      final choices = _cubit.state.choices;
      _memory?.remember(_memoryKey, choices.isEmpty ? null : choices);
    }
    _stop();
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  /// Open the login page, then load the poll when the account in use is still the same one.
  ///
  /// A login of another account changes the account: the thread page reloads with its floors once it shows again, a
  /// card elsewhere loads by itself (see [PollCard]), loading here as well asked for the same page twice. A login of
  /// the same account is no change for them, yet the card asked to log in because the forum served the page as to a
  /// guest: the session of that account had expired (issue #25), after the login it can vote. The card does not load
  /// for that login before its page closes ([_followLogins]): once is enough. Back without a login, the card asks once
  /// as well, as it always did.
  Future<void> _login() async {
    final auth = context.read<AuthenticationRepository>();
    final uid = auth.effectiveCurrentUid;
    _loginPages++;
    try {
      await context.pushNamed(ScreenPaths.login);
    } finally {
      _loginPages--;
    }
    if (mounted && auth.effectiveCurrentUid == uid) await _cubit.load();
  }

  /// The image of a choice of an image poll, small; tapping opens it.
  Widget? _optionImage(PollOption option) {
    final image = option.image;
    if (image == null) {
      return null;
    }
    return GestureDetector(
      onTap: () async => context.dispatchAsUrl(image, external: true),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(appInnerRadius),
        child: CachedImage(image, width: 56, height: 56, fit: BoxFit.cover),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<PollCubit, PollState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.pollVoting;
      final poll = state.poll;
      // Read back from an offline copy of the thread: the results only, no vote, login or refresh.
      final offline = isOfflineFloor(context);
      final canVote = !offline && poll?.availability == PollAvailability.available;
      final colorScheme = Theme.of(context).colorScheme;
      final textTheme = Theme.of(context).textTheme;
      // Header: title, deadline under it, a spinner while busy. Status lines are banners, choices in the middle,
      // actions at the bottom.
      return AppEmbedCard(
        icon: Icons.poll_outlined,
        title: context.t.pollCard.title,
        subtitle: (poll?.deadline.isNotEmpty ?? false) ? poll!.deadline : null,
        trailing: state.busy ? const SizedBox(width: 20, height: 20, child: CircularIndicator()) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.submissionUnconfirmed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AppNoticeBanner(tone: AppNoticeTone.warning, icon: Icons.help_outline, message: tr.unconfirmed),
              ),
            if (state.refusal case final refusal?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AppNoticeBanner(tone: AppNoticeTone.error, message: refusal, selectable: true),
              ),
            if (state.failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AppNoticeBanner(tone: AppNoticeTone.error, message: context.t.general.failedToLoad),
              ),
            if (poll != null) ...[
              if (poll.summary.isNotEmpty) Text(poll.summary, style: textTheme.bodyMedium),
              if (canVote)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    tr.selection(count: state.choices.length, max: poll.maxChoices!),
                    style: textTheme.labelMedium?.copyWith(color: colorScheme.primary),
                  ),
                ),
              if (canVote && poll.maxChoices == 1)
                RadioGroup<String>(
                  groupValue: state.choices.firstOrNull,
                  onChanged: (value) {
                    if (value != null) _cubit.select(value, selected: true);
                  },
                  child: Column(
                    children: [
                      for (final option in poll.options)
                        RadioListTile<String>(
                          value: option.id!,
                          enabled: !state.busy,
                          contentPadding: EdgeInsets.zero,
                          title: Text(option.label),
                          subtitle: option.result == null ? null : Text(option.result!),
                          secondary: _optionImage(option),
                        ),
                    ],
                  ),
                )
              else ...[
                for (final option in poll.options)
                  if (canVote && option.id != null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(option.label),
                      subtitle: option.result == null ? null : Text(option.result!),
                      secondary: _optionImage(option),
                      value: state.choices.contains(option.id),
                      onChanged:
                          state.busy ||
                              (poll.maxChoices != 1 &&
                                  !state.choices.contains(option.id) &&
                                  state.choices.length >= poll.maxChoices!)
                          ? null
                          : (value) => _cubit.select(option.id!, selected: value ?? false),
                    )
                  else
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(option.label),
                      subtitle: option.result == null ? null : Text(option.result!),
                      trailing: _optionImage(option),
                    ),
              ],
              if (poll.notice.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: AppNoticeBanner(message: poll.notice),
                ),
              if (poll.availability != PollAvailability.available)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: AppNoticeBanner(
                    icon: switch (poll.availability) {
                      PollAvailability.voted => Icons.how_to_vote_outlined,
                      PollAvailability.closed => Icons.lock_outline,
                      PollAvailability.loginRequired => Icons.login_outlined,
                      _ => Icons.info_outline,
                    },
                    message: switch (poll.availability) {
                      PollAvailability.voted => tr.voted,
                      PollAvailability.closed => tr.closed,
                      PollAvailability.loginRequired => tr.loginRequired,
                      PollAvailability.denied => tr.denied,
                      _ => tr.unsupported,
                    },
                  ),
                ),
            ],
            sizedBoxW8H8,
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (canVote)
                  // Plain constructor on purpose: the only FilledButton of the card (widget tests look it up by type).
                  FilledButton(
                    onPressed: state.busy || !poll!.accepts(state.choices) ? null : _cubit.submit,
                    child: Text(tr.submit),
                  ),
                if (!offline && poll?.availability == PollAvailability.loginRequired)
                  TextButton(onPressed: _login, child: Text(tr.loginRequired)),
                if (!offline)
                  if (poll?.votersUrl case final voters?)
                    TextButton.icon(
                      icon: const Icon(Icons.groups_outlined),
                      label: Text(context.t.specialThread.poll.viewVoters),
                      onPressed: () async => context.dispatchAsUrl(voters, external: true),
                    ),
                if (!offline)
                  TextButton.icon(
                    onPressed: state.busy ? null : _cubit.load,
                    icon: const Icon(Icons.refresh),
                    label: Text(tr.refresh),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_browser_outlined),
                  label: Text(context.t.pollCard.openInBrowser),
                  onPressed: () async => context.dispatchAsUrl(_cubit.url, external: true),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/follow/models/follow_models.dart';
import 'package:tsdm_client/features/follow/repository/follow_repository.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/features/space/widgets/space_social_widgets.dart';
import 'package:tsdm_client/features/space/widgets/space_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// The repository of the account in use of [context].
FollowWriteRepository followWriteRepositoryOf(BuildContext context) {
  final auth = context.read<AuthenticationRepository>();
  return FollowWriteRepository(client: getIt.get<NetClientProvider>(), currentUid: () => auth.effectiveCurrentUid);
}

/// The avatar of a member, opening their profile.
class FollowAvatar extends StatelessWidget {
  /// Constructor.
  const FollowAvatar({required this.uid, required this.username, this.avatarUrl, super.key});

  /// The member.
  final int uid;

  /// Their name.
  final String username;

  /// Their avatar; the one the forum serves for [uid] without it.
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) => InkWell(
    customBorder: const CircleBorder(),
    onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '$uid'}),
    // Lists show the same member many times: no hero.
    child: HeroUserAvatar(
      username: username,
      avatarUrl: avatarUrl ?? avatarUrlOfUid('$uid'),
      maxRadius: 18,
      disableHero: true,
    ),
  );
}

/// Ask for one line of text, [initial] filled in; pops it trimmed (empty when [allowEmpty]), null when cancelled.
Future<String?> showFollowTextDialog(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String label,
  String initial = '',
  bool allowEmpty = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(icon: icon, title: title, label: label, initial: initial, allowEmpty: allowEmpty),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.icon,
    required this.title,
    required this.label,
    required this.initial,
    required this.allowEmpty,
  });

  final IconData icon;
  final String title;
  final String label;
  final String initial;
  final bool allowEmpty;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _valid => widget.allowEmpty || _text.text.trim().isNotEmpty;

  void _submit() {
    if (_valid) Navigator.of(context).pop(_text.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          AppIconTile(widget.icon, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(widget.title)),
        ],
      ),
      content: TextField(
        controller: _text,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton(onPressed: _valid ? _submit : null, child: Text(context.t.general.ok)),
      ],
    );
  }
}

/// Note a name for the followed member [uid] with the [session] of a page ([current] filled in), sent once.
///
/// The name the forum kept when it took one (empty once removed); null when nothing changed.
Future<String?> editFollowRemark(
  BuildContext context, {
  required SpaceSession session,
  required int uid,
  required String username,
  String? current,
}) async {
  final tr = context.t.spacePage.follow;
  final name = await showFollowTextDialog(
    context,
    icon: Icons.edit_outlined,
    title: username,
    label: tr.remark,
    initial: current ?? '',
    allowEmpty: true,
  );
  if (name == null || name == (current ?? '') || !context.mounted) return null;
  final answer = await followWriteRepositoryOf(context).remark(session, uid, name);
  if (!context.mounted) return null;
  showSpaceWriteResult(context, answer.result, done: tr.remarkSaved);
  return answer.remark;
}

/// Follow [uid], or no longer follow them ([unfollow], once the user confirmed: following again does not bring back
/// what was lost, the name noted and being followed back at once), with the [session] of a page; sent once.
///
/// True when the forum did it.
Future<bool> sendFollow(
  BuildContext context, {
  required SpaceSession session,
  required int uid,
  required String username,
  required bool unfollow,
}) async {
  final tr = context.t.spacePage.follow;
  if (unfollow) {
    final confirmed = await showQuestionDialog(context: context, title: tr.unfollow, message: username);
    if (!(confirmed ?? false) || !context.mounted) return false;
  }
  final repository = followWriteRepositoryOf(context);
  final result = await (unfollow ? repository.unfollow(session, uid) : repository.follow(session, uid));
  if (!context.mounted) return false;
  if (spaceModuleSwitchedOff(result.message)) markSpaceModuleOff(SpaceModule.follow);
  showSpaceWriteResult(context, result, done: unfollow ? tr.unfollowed : tr.followed);
  return result.outcome == SpaceWriteOutcome.done;
}

/// What the account in use is to the member [uid], and what it may do about it: follow or no longer follow them, note
/// a name for a member followed. The forum's page is read first: it refuses here already with the module off.
Future<void> showFollowDialog(BuildContext context, {required int uid, String? username}) async {
  final tr = context.t.spacePage.follow;
  final load = await followWriteRepositoryOf(context).loadRelation(uid);
  if (!context.mounted) return;
  switch (load.kind) {
    case SpaceFormLoadKind.ready:
      break;
    case SpaceFormLoadKind.denied:
      if (spaceModuleSwitchedOff(load.message)) markSpaceModuleOff(SpaceModule.follow);
      showSnackBar(context: context, message: load.message!);
      return;
    case SpaceFormLoadKind.loginRequired:
      showSnackBar(context: context, message: context.t.general.needLogin);
      return;
    case SpaceFormLoadKind.identityChanged:
      showSnackBar(context: context, message: context.t.spacePage.identityChanged);
      return;
    case SpaceFormLoadKind.failed:
      showSnackBar(context: context, message: tr.loadFailed);
      return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _FollowDialog(relation: load.form!, username: username ?? load.form!.username ?? '$uid'),
  );
}

/// The relation to a member: their numbers, each opening its list; the name noted; follow or no longer follow.
class _FollowDialog extends StatefulWidget {
  const _FollowDialog({required this.relation, required this.username});

  final FollowRelation relation;
  final String username;

  @override
  State<_FollowDialog> createState() => _FollowDialogState();
}

class _FollowDialogState extends State<_FollowDialog> {
  late FollowRelation _relation = widget.relation;
  bool _sending = false;

  Future<void> _toggle() async {
    final unfollow = _relation.following;
    setState(() => _sending = true);
    final done = await sendFollow(
      context,
      session: _relation.session,
      uid: _relation.uid,
      username: widget.username,
      unfollow: unfollow,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (done) {
        final followers = _relation.followerCount;
        _relation = _relation.copyWith(
          following: !unfollow,
          followerCount: followers == null ? null : (followers + (unfollow ? -1 : 1)).clamp(0, 1 << 31),
        );
      }
    });
  }

  Future<void> _remark() async {
    final kept = await editFollowRemark(
      context,
      session: _relation.session,
      uid: _relation.uid,
      username: widget.username,
      current: _relation.remark,
    );
    if (kept != null && mounted) setState(() => _relation = _relation.copyWith(remark: kept));
  }

  void _open(String path, Map<String, String> query) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    unawaited(
      router.pushNamed(path, queryParameters: {'uid': '${_relation.uid}', 'username': widget.username, ...query}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.follow;
    final theme = Theme.of(context);
    final off = spaceModulesOff.value;
    final remark = _relation.remark;
    final status = _relation.followsViewer ? (_relation.following ? tr.mutual : tr.followsYou) : null;
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          // Their profile is where the dialog was opened from: the avatar is no link here.
          HeroUserAvatar(
            username: widget.username,
            avatarUrl: avatarUrlOfUid('${_relation.uid}'),
            maxRadius: 18,
            disableHero: true,
          ),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.username, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (remark != null && remark.isNotEmpty)
                  Text(remark, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
          if (status != null) Chip(label: Text(status), visualDensity: VisualDensity.compact),
        ],
      ),
      content: Row(
        children: [
          if (!off.contains(SpaceModule.broadcast))
            _Stat(
              count: _relation.feedCount,
              label: tr.broadcasts,
              onTap: () => _open(ScreenPaths.followFeed, const {}),
            ),
          _Stat(
            count: _relation.followingCount,
            label: tr.following,
            onTap: () => _open(ScreenPaths.followMembers, const {}),
          ),
          _Stat(
            count: _relation.followerCount,
            label: tr.followers,
            onTap: () => _open(ScreenPaths.followMembers, const {'tab': 'follower'}),
          ),
        ],
      ),
      actions: [
        if (_relation.following) TextButton(onPressed: _sending ? null : _remark, child: Text(tr.remark)),
        if (_relation.following)
          OutlinedButton(onPressed: _sending ? null : _toggle, child: Text(tr.unfollow))
        else
          FilledButton.icon(
            onPressed: _sending ? null : _toggle,
            icon: const Icon(Icons.person_add_alt_outlined),
            label: Text(tr.follow),
          ),
      ],
    );
  }
}

/// A number of a member over what it counts, opening its list.
class _Stat extends StatelessWidget {
  const _Stat({required this.count, required this.label, required this.onTap});

  final int? count;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(appInnerRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Text(count == null ? '-' : '$count', style: theme.textTheme.titleMedium),
              Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A member of a list of the followed or of the followers: who, the name noted, what they did last, their numbers;
/// the forum's own follow link as a button, the remark in a menu.
class FollowUserTile extends StatelessWidget {
  /// Constructor.
  const FollowUserTile(this.user, {this.onToggleFollow, this.onRemark, super.key});

  /// The member.
  final FollowUser user;

  /// Follow or no longer follow them; null when the forum printed no link, or the page has no session.
  final VoidCallback? onToggleFollow;

  /// Note a name for them; null when the forum printed no link.
  final VoidCallback? onRemark;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.follow;
    final theme = Theme.of(context);
    final outline = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline);
    final following = user.following;
    return AppSurface(
      onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${user.uid}'}),
      child: Row(
        children: [
          FollowAvatar(uid: user.uid, username: user.username, avatarUrl: user.avatarUrl),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(user.username, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                    ),
                    if (user.remark case final String remark) ...[
                      sizedBoxW8H8,
                      Flexible(
                        child: Text(remark, style: outline, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                    if (user.mutual) ...[
                      sizedBoxW8H8,
                      Tooltip(
                        message: tr.mutual,
                        child: Icon(Icons.sync_alt_outlined, size: 14, color: theme.colorScheme.primary),
                      ),
                    ],
                  ],
                ),
                if (user.recentNote case final String note)
                  Text(note, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (user.followerCount != null && user.followingCount != null)
                  Text(
                    tr.counts(followers: user.followerCount!, following: user.followingCount!),
                    style: outline,
                  ),
              ],
            ),
          ),
          if (following != null && onToggleFollow != null) ...[
            sizedBoxW8H8,
            if (following)
              OutlinedButton(onPressed: onToggleFollow, child: Text(tr.unfollow))
            else
              FilledButton.tonal(onPressed: onToggleFollow, child: Text(tr.follow)),
          ],
          if (onRemark != null)
            IconButton(icon: const Icon(Icons.edit_outlined), tooltip: tr.remark, onPressed: onRemark),
        ],
      ),
    );
  }
}

/// What can be done with a broadcast, as the forum printed its links.
enum _FeedAction { relay, delete }

/// A broadcast: who and when, what they said, and the thread it is about (its title, how it begins, its forum and
/// counts); a tap opens the thread.
class FollowFeedCard extends StatelessWidget {
  /// Constructor.
  const FollowFeedCard(this.feed, {this.onRelay, this.onDelete, super.key});

  /// The broadcast.
  final FollowFeed feed;

  /// Relay its thread; null when the forum printed no link, or the page has no session.
  final VoidCallback? onRelay;

  /// Delete it; null when the forum printed no link, or the page has no session.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.follow;
    final theme = Theme.of(context);
    final outline = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline);
    final actions = [if (onRelay != null) _FeedAction.relay, if (onDelete != null) _FeedAction.delete];
    final tid = feed.threadId;
    final thread = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (feed.threadTitle case final String title) Text(title, style: theme.textTheme.titleSmall),
        if (feed.content case final content?) ...[
          sizedBoxW4H4,
          // The beginning of the thread only: a long one is cut, the thread itself is a tap away.
          ClipRect(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: munchElement(context, content),
              ),
            ),
          ),
        ],
        if (!feed.threadMissing) ...[
          sizedBoxW8H8,
          Row(
            children: [
              Expanded(
                child: Text(
                  [?feed.origin, if (feed.forumName != null) '#${feed.forumName}'].join(' '),
                  style: outline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (feed.relayCount case final int count) ...[sizedBoxW8H8, SpaceCount(Icons.repeat_outlined, count)],
              if (feed.replyCount case final int count) ...[
                sizedBoxW8H8,
                SpaceCount(Icons.mode_comment_outlined, count),
              ],
            ],
          ),
        ],
      ],
    );
    return AppSurface(
      onTap: tid == null || feed.threadMissing
          ? null
          : () async => context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '$tid'}),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FollowAvatar(uid: feed.uid, username: feed.username),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              feed.username,
                              style: theme.textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (feed.time != null) ...[sizedBoxW8H8, Text(feed.time!, style: outline)],
                        ],
                      ),
                    ),
                    if (actions.isNotEmpty)
                      SizedBox.square(
                        dimension: 24,
                        child: PopupMenuButton<_FeedAction>(
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          // The action runs once the menu is closed: a dialog opened from the item itself would be
                          // closed with the menu.
                          onSelected: (action) => switch (action) {
                            _FeedAction.relay => onRelay?.call(),
                            _FeedAction.delete => onDelete?.call(),
                          },
                          itemBuilder: (_) => [
                            for (final action in actions)
                              PopupMenuItem(
                                value: action,
                                child: Row(
                                  children: [
                                    Icon(switch (action) {
                                      _FeedAction.relay => Icons.repeat_outlined,
                                      _FeedAction.delete => Icons.delete_outline,
                                    }),
                                    sizedBoxPopupMenuItemIconSpacing,
                                    Text(switch (action) {
                                      _FeedAction.relay => tr.relay,
                                      _FeedAction.delete => tr.deleteFeed,
                                    }),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
                sizedBoxW4H4,
                if (feed.note case final note?) ...[
                  munchElement(context, note),
                  sizedBoxW8H8,
                  // The thread a note is about, set apart as the forum quotes it.
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(appInnerRadius),
                    ),
                    child: thread,
                  ),
                ] else
                  thread,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Relay the thread of [feed] with the [session] of its page: a note, and whether it is posted as a reply too; sent
/// once.
///
/// True when the list is to be read again.
Future<bool> showRelayDialog(BuildContext context, {required SpaceSession session, required FollowFeed feed}) async {
  final tr = context.t.spacePage.follow;
  final tid = feed.threadId;
  if (tid == null) return false;
  final choice = await showDialog<({String note, bool reply})>(
    context: context,
    builder: (_) => _RelayDialog(title: feed.threadTitle ?? tr.relay),
  );
  if (choice == null || !context.mounted) return false;
  final result = await followWriteRepositoryOf(context).relay(session, tid, choice.note, reply: choice.reply);
  if (!context.mounted) return false;
  return showSpaceWriteResult(context, result, done: tr.relayed);
}

class _RelayDialog extends StatefulWidget {
  const _RelayDialog({required this.title});

  final String title;

  @override
  State<_RelayDialog> createState() => _RelayDialogState();
}

class _RelayDialogState extends State<_RelayDialog> {
  final _note = TextEditingController();
  // As the forum's own form has it checked.
  bool _reply = true;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.follow;
    final note = _note.text.trim();
    final bytes = utf8.encode(note).length;
    // The forum counts the bytes of the note; a reply is its note, so it needs one.
    final valid = bytes <= FollowWriteRepository.relayNoteMaxBytes && (note.isNotEmpty || !_reply);
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          const AppIconTile(Icons.repeat_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _note,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: tr.relayNote,
              counterText: '$bytes / ${FollowWriteRepository.relayNoteMaxBytes}',
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
            ),
            onChanged: (_) => setState(() {}),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _reply,
            title: Text(tr.relayReply),
            onChanged: (value) => setState(() => _reply = value ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton.icon(
          onPressed: valid ? () => Navigator.of(context).pop((note: note, reply: _reply)) : null,
          icon: const Icon(Icons.repeat_outlined),
          label: Text(tr.relay),
        ),
      ],
    );
  }
}

/// Delete the broadcast [feed] with the [session] of its page, once the user confirmed; sent once.
///
/// True when the list is to be read again.
Future<bool> deleteFollowFeed(BuildContext context, {required SpaceSession session, required FollowFeed feed}) async {
  final tr = context.t.spacePage.follow;
  final confirmed = await showQuestionDialog(
    context: context,
    title: tr.deleteFeed,
    message: feed.note?.text?.trim() ?? feed.threadTitle ?? '',
    dangerous: true,
  );
  if (!(confirmed ?? false) || !context.mounted) return false;
  final result = await followWriteRepositoryOf(context).deleteFeed(session, feed.feedId);
  if (!context.mounted) return false;
  return showSpaceWriteResult(context, result, done: tr.deleted);
}

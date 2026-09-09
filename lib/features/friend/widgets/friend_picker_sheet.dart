import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/editor/widgets/mention_picker.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// Let the user pick one of their friends; returns null when dismissed (GitHub #23).
///
/// Friends come from the same cached list the mention picker uses. [repository] overrides the shared one (tests).
Future<Friend?> showFriendPicker(BuildContext context, {MentionRepository? repository}) async {
  final selfUid = context.read<AuthenticationRepository?>()?.effectiveCurrentUid?.toString();
  return showCustomBottomSheet<Friend>(
    context: context,
    title: context.t.threadPage.shareToFriend.pickTitle,
    builder: (_) => RootPage(
      DialogPaths.friendPicker,
      FriendPickerSheet(repository: repository ?? sharedMentionRepository(), selfUid: selfUid),
    ),
  );
}

/// Body of the friend picker: a filter field and the friends list; pops the enclosing route with the picked friend.
class FriendPickerSheet extends StatefulWidget {
  /// Constructor.
  const FriendPickerSheet({required this.repository, required this.selfUid, super.key});

  /// Source of the friends list.
  final MentionRepository repository;

  /// Uid of the current user, null when nobody is logged in.
  final String? selfUid;

  @override
  State<FriendPickerSheet> createState() => _FriendPickerSheetState();
}

class _FriendPickerSheetState extends State<FriendPickerSheet> {
  List<Friend>? _friends;
  String? _message;
  var _failed = false;
  var _keyword = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _friends = null;
      _failed = false;
      _message = null;
    });
    final result = await widget.repository.loadCandidates(selfUid: widget.selfUid, force: force).run();
    if (!mounted) {
      return;
    }
    setState(() {
      switch (result) {
        case Left():
          _failed = true;
        case Right(:final value):
          _friends = value.friends;
          _message = value.friendsMessage;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bbcodeEditor.userMention;
    final friends = _friends;
    final visible = friends?.where((e) => e.username.toLowerCase().contains(_keyword.toLowerCase())).toList();
    final Widget body;
    if (_failed) {
      body = Center(
        child: TextButton(onPressed: _load, child: Text(context.t.general.failedToLoad)),
      );
    } else if (friends == null) {
      body = const LinearProgressIndicator();
    } else if (friends.isEmpty) {
      body = Padding(
        padding: edgeInsetsL12T12R12B12,
        child: Text(_message != null ? tr.friendsUnavailable(message: _message!) : tr.noFriends),
      );
    } else if (visible!.isEmpty) {
      body = Padding(padding: edgeInsetsL12T12R12B12, child: Text(tr.noMatch));
    } else {
      body = ListView.builder(
        shrinkWrap: true,
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final friend = visible[index];
          return ListTile(
            leading: HeroUserAvatar(username: friend.username, avatarUrl: friend.avatarUrl, disableHero: true),
            title: Text(friend.username),
            subtitle: friend.groupName == null ? null : Text(friend.groupName!),
            onTap: () => Navigator.of(context).pop(friend),
          );
        },
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: edgeInsetsL12T4R12,
          child: TextField(
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search_outlined), hintText: tr.filterHint),
            onChanged: (v) => setState(() => _keyword = v.trim()),
          ),
        ),
        sizedBoxW4H4,
        Flexible(child: body),
      ],
    );
  }
}

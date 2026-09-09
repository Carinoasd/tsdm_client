import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/bloc/user_mention_cubit.dart';
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/html/adaptive_color.dart';
import 'package:tsdm_client/utils/html/css_parser.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// Candidates shared by every picker in the app, so reopening it does not fetch the lists again.
///
/// Keyed by uid inside, refreshed by the sheet's reload button.
MentionRepository? _sharedRepository;

/// Show the mention picker as a bottom sheet and return the picked username, null when dismissed.
///
/// Used by the toolbar `@` button, by tapping an existing mention chip ([username] then prefills the filter) and by
/// the typed `@` trigger. Friends come from the current user's own friends list, other names from the official `@`
/// list; any name can be typed when nothing matches. [repository] overrides the shared one (tests).
Future<String?> showMentionPicker(BuildContext context, {String? username, MentionRepository? repository}) async {
  final selfUid = context.read<AuthenticationRepository?>()?.currentUser?.uid?.toString();
  final repo = repository ?? (_sharedRepository ??= MentionRepository());
  return showCustomBottomSheet<String>(
    context: context,
    title: context.t.bbcodeEditor.userMention.title,
    builder: (_) => RootPage(
      DialogPaths.usernamePicker,
      MentionPickerSheet(repository: repo, selfUid: selfUid, initialKeyword: username),
    ),
  );
}

/// Body of the mention picker: a filter field, the friends, the other names on the `@` list, and a row to use the
/// typed keyword as is.
///
/// Pops the enclosing route with the picked username.
class MentionPickerSheet extends StatefulWidget {
  /// Constructor.
  const MentionPickerSheet({required this.repository, required this.selfUid, this.initialKeyword, super.key});

  /// Where the candidates come from.
  final MentionRepository repository;

  /// Uid of the current user, null when nobody is logged in.
  final String? selfUid;

  /// Text to start the filter with.
  final String? initialKeyword;

  /// Debounce of the filter field.
  static const filterDebounce = Duration(milliseconds: 150);

  @override
  State<MentionPickerSheet> createState() => _MentionPickerSheetState();
}

class _MentionPickerSheetState extends State<MentionPickerSheet> {
  static const _maxHeight = 460.0;
  static const _avatarRadius = 18.0;

  late final TextEditingController _filter;
  late final UserMentionCubit _cubit;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _filter = TextEditingController(text: widget.initialKeyword);
    _cubit = UserMentionCubit(widget.repository, selfUid: widget.selfUid)..setKeyword(widget.initialKeyword ?? '');
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _filter.dispose();
    unawaited(_cubit.close());
    super.dispose();
  }

  void _onFilterChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(MentionPickerSheet.filterDebounce, () {
      if (mounted) {
        _cubit.setKeyword(value);
      }
    });
  }

  void _pickName(String name) => Navigator.of(context).pop(name);

  Future<void> _openProfile(Map<String, String> queryParameters) async =>
      context.pushNamed(ScreenPaths.profile, queryParameters: queryParameters);

  /// Forum colors are chosen for the light web page; adapt them in dark mode like the friend card does.
  Color? _color(String? cssColor) {
    final color = cssColor == null ? null : parseCssString('color:$cssColor')?.color;
    if (color == null) {
      return null;
    }
    return Theme.of(context).brightness == Brightness.dark ? color.adaptiveDark() : color;
  }

  Widget _header(String text, {Widget? trailing}) => Padding(
    padding: edgeInsetsL16R16.add(edgeInsetsT4B4),
    child: Row(
      children: [
        Expanded(child: Text(text, style: Theme.of(context).textTheme.labelLarge)),
        ?trailing,
      ],
    ),
  );

  Widget _note(String text) => Padding(
    padding: edgeInsetsL16R16.add(edgeInsetsT4B4),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );

  Widget _friendTile(Friend friend) {
    final tr = context.t.bbcodeEditor.userMention;
    final groupName = friend.groupName;
    return ListTile(
      leading: HeroUserAvatar(
        username: friend.username,
        avatarUrl: friend.avatarUrl,
        minRadius: _avatarRadius,
        maxRadius: _avatarRadius,
        disableHero: true,
      ),
      title: Text(
        friend.username,
        style: TextStyle(color: _color(friend.nameColor)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: groupName == null ? null : Text(groupName, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        icon: const Icon(Icons.open_in_new),
        tooltip: tr.viewUserSpaceTip,
        onPressed: () async => _openProfile({'uid': friend.uid}),
      ),
      onTap: () => _pickName(friend.username),
    );
  }

  Widget _nameTile(String name) {
    final tr = context.t.bbcodeEditor.userMention;
    return ListTile(
      leading: const CircleAvatar(radius: _avatarRadius, child: Icon(Icons.person_outline)),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        icon: const Icon(Icons.open_in_new),
        tooltip: tr.viewUserSpaceTip,
        onPressed: () async => _openProfile({'username': name}),
      ),
      onTap: () => _pickName(name),
    );
  }

  List<Widget> _friendsSection(UserMentionState state) {
    final tr = context.t.bbcodeEditor.userMention;
    final message = state.friendsMessage;
    final visible = state.visibleFriends;
    return [
      _header(
        tr.randomFriend,
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: tr.refreshRecommendTip,
          onPressed: state.recommendStatus == UserMentionStatus.loading ? null : () async => _cubit.load(force: true),
        ),
      ),
      switch (state.recommendStatus) {
        UserMentionStatus.initial || UserMentionStatus.loading => const LinearProgressIndicator(),
        UserMentionStatus.failure => _note(context.t.general.failedToLoad),
        UserMentionStatus.success when message != null => _note(tr.friendsUnavailable(message: message)),
        UserMentionStatus.success when state.friends.isEmpty => _note(tr.noFriends),
        UserMentionStatus.success when visible.isEmpty => _note(tr.noMatch),
        UserMentionStatus.success => Column(
          mainAxisSize: MainAxisSize.min,
          children: visible.map(_friendTile).toList(),
        ),
      },
    ];
  }

  List<Widget> _othersSection(UserMentionState state) {
    final visible = state.visibleOthers;
    if (visible.isEmpty) {
      return const [];
    }
    return [_header(context.t.bbcodeEditor.userMention.others), ...visible.map(_nameTile)];
  }

  Widget _useTypedRow(UserMentionState state) {
    final keyword = state.keyword;
    return ListTile(
      leading: const CircleAvatar(radius: _avatarRadius, child: Icon(Icons.alternate_email)),
      title: Text(context.t.bbcodeEditor.userMention.useTyped(name: keyword)),
      onTap: () => _pickName(keyword),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bbcodeEditor.userMention;
    return BlocProvider.value(
      value: _cubit,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _maxHeight),
        child: Column(
          children: [
            Padding(
              padding: edgeInsetsL16R16.add(edgeInsetsT4B4),
              child: TextField(
                controller: _filter,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: tr.filterHint,
                  prefixIcon: const Icon(Icons.alternate_email),
                  isDense: true,
                ),
                onChanged: _onFilterChanged,
                onSubmitted: (v) {
                  final name = v.trim();
                  if (name.isNotEmpty) {
                    _pickName(name);
                  }
                },
              ),
            ),
            Expanded(
              child: BlocBuilder<UserMentionCubit, UserMentionState>(
                builder: (context, state) => ListView(
                  padding: edgeInsetsT4B4,
                  children: [
                    ..._friendsSection(state),
                    ..._othersSection(state),
                    if (state.keyword.isNotEmpty && !state.hasExactMatch) _useTypedRow(state),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

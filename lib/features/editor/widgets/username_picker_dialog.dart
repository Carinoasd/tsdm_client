import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/list.dart';
import 'package:tsdm_client/features/editor/bloc/user_mention_cubit.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Small text to show username.
class _UsernameText extends StatelessWidget {
  const _UsernameText(this.controller, this.username);

  final TextEditingController controller;

  final String username;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          controller.text = username;
          context.pop(username);
        },
        child: Text(username, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
      ),
    );
  }
}

/// Show a dialog to let user pick a user and return the username picked.
///
/// This dialog wraps the plain one in the editor package: it lists the users the current user may mention (the
/// official `@` list of Discuz! X5, friends only) and searches inside that list. Any username can still be typed.
Future<String?> showUsernamePickerDialog(BuildContext context, {String? username}) async => showDialog<String>(
  context: context,
  builder: (_) => RootPage(DialogPaths.usernamePicker, _UsernamePickerDialog(username)),
);

/// A dialog to let user pick user to mention.
///
/// With the official `@` user list and a local search in it.
class _UsernamePickerDialog extends StatefulWidget {
  const _UsernamePickerDialog(this.initialName);

  /// Optional initial username;
  final String? initialName;

  @override
  State<_UsernamePickerDialog> createState() => _UsernamePickerDialogState();
}

class _UsernamePickerDialogState extends State<_UsernamePickerDialog> with LoggerMixin {
  final formKey = GlobalKey<FormState>();

  late TextEditingController controller;

  bool userNameNotEmpty = false;

  void onUsernameChanged() {
    if (controller.text.isEmpty && userNameNotEmpty) {
      setState(() {
        userNameNotEmpty = false;
      });
    } else if (controller.text.isNotEmpty && !userNameNotEmpty) {
      setState(() {
        userNameNotEmpty = true;
      });
    }
  }

  Widget _buildSearch(BuildContext context, UserMentionState state) {
    final tr = context.t.bbcodeEditor.userMention;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr.username,
                  suffixIcon: userNameNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.open_in_new),
                          tooltip: tr.viewUserSpaceTip,
                          onPressed: () async => context.pushNamed(
                            ScreenPaths.profile,
                            queryParameters: {'username': controller.text.trim()},
                          ),
                        )
                      : null,
                ),
                validator: (v) => v == null || v.isEmpty ? tr.errorEmpty : null,
              ),
            ),
            sizedBoxW4H4,
            TextButton(
              onPressed: userNameNotEmpty && state.searchStatus != UserMentionStatus.loading
                  ? () async => context.read<UserMentionCubit>().searchUserByName(keyword: controller.text.trim())
                  : null,
              child: Text(tr.search),
            ),
          ],
        ),
        sizedBoxW8H8,
        Text(tr.searchResult, style: Theme.of(context).textTheme.labelLarge),
        sizedBoxW4H4,
        switch (state.searchStatus) {
          UserMentionStatus.initial => sizedBoxW8H8,
          UserMentionStatus.loading => const LinearProgressIndicator(),
          UserMentionStatus.success when state.searchResult.isEmpty => Text(tr.noMatch),
          UserMentionStatus.success => Wrap(
            children: state.searchResult
                .map((e) => _UsernameText(controller, e) as Widget)
                .toList()
                .insertBetween(sizedBoxW8H8),
          ),
          UserMentionStatus.failure => Text(context.t.general.failedToLoad),
        },
      ],
    );
  }

  Widget _buildFriends(BuildContext context, UserMentionState state) {
    final tr = context.t.bbcodeEditor.userMention;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(tr.randomFriend, style: Theme.of(context).textTheme.labelLarge),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: tr.refreshRecommendTip,
              onPressed: state.recommendStatus == UserMentionStatus.loading
                  ? null
                  : () async => context.read<UserMentionCubit>().loadFriends(),
            ),
          ],
        ),
        sizedBoxW4H4,
        switch (state.recommendStatus) {
          UserMentionStatus.initial || UserMentionStatus.loading => const LinearProgressIndicator(),
          UserMentionStatus.success when state.randomFriend.isEmpty => Text(tr.noFriends),
          UserMentionStatus.success => Wrap(
            children: state.randomFriend
                .map((e) => _UsernameText(controller, e) as Widget)
                .toList()
                .insertBetween(sizedBoxW8H8),
          ),
          UserMentionStatus.failure => Text(context.t.general.failedToLoad),
        },
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.initialName)..addListener(onUsernameChanged);
  }

  @override
  void dispose() {
    controller
      ..removeListener(onUsernameChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.bbcodeEditor.userMention;
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => EditorRepository()),
        BlocProvider(
          create: (context) {
            final cubit = UserMentionCubit(context.repo());
            // TODO: Make it sync.
            unawaited(cubit.loadFriends());
            return cubit;
          },
        ),
      ],
      child: BlocBuilder<UserMentionCubit, UserMentionState>(
        builder: (context, state) => CustomAlertDialog.sync(
          title: Text(tr.title),
          content: Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                sizedBoxW8H8,
                _buildSearch(context, state),
                sizedBoxW16H16,
                _buildFriends(context, state),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) {
                  return;
                }
                context.pop(controller.text);
              },
              child: Text(context.t.general.ok),
            ),
          ],
        ),
      ),
    );
  }
}

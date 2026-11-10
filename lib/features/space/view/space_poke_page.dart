import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/space/cubit/space_list_cubit.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/features/space/view/space_page.dart';
import 'package:tsdm_client/features/space/widgets/space_social_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

/// The greetings received (`home.php?mod=spacecp&ac=poke`), the latest of each member: greet back, ignore one,
/// ignore all.
class SpacePokePage extends StatefulWidget {
  /// Constructor.
  const SpacePokePage({super.key});

  @override
  State<SpacePokePage> createState() => _SpacePokePageState();
}

class _SpacePokePageState extends State<SpacePokePage> {
  late final SpaceListCubit<ReceivedPoke> _pokes;

  @override
  void initState() {
    super.initState();
    _pokes = SpaceListCubit<ReceivedPoke>(
      firstPageUrl: spacePokeListUrl,
      fetch: const SpaceRepository().fetchPokes,
      keyOf: (e) => e.uid,
    );
    unawaited(_pokes.load());
  }

  @override
  void dispose() {
    unawaited(_pokes.close());
    super.dispose();
  }

  Future<void> _greetBack(ReceivedPoke poke) async {
    if (await showPokeDialog(context, uid: poke.uid, username: poke.username, reply: true) && mounted) {
      unawaited(_pokes.refresh());
    }
  }

  Future<void> _ignore(SpaceSession session, {ReceivedPoke? poke}) async {
    final tr = context.t.spacePage.poke;
    if (poke == null) {
      final confirmed = await showQuestionDialog(
        context: context,
        title: tr.ignoreAll,
        message: tr.ignoreAllConfirm,
        dangerous: true,
      );
      if (!(confirmed ?? false) || !mounted) return;
    }
    final result = await spaceSocialRepositoryOf(context).ignorePokes(session, uid: poke?.uid);
    if (!mounted) return;
    if (showSpaceWriteResult(context, result, done: tr.ignored)) {
      unawaited(_pokes.refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.poke;
    return BlocProvider.value(
      value: _pokes,
      child: BlocConsumer<SpaceListCubit<ReceivedPoke>, SpaceListState<ReceivedPoke>>(
        listenWhen: (prev, curr) => curr.status == SpaceLoadStatus.notice && prev.status != curr.status,
        listener: (context, state) {
          if (spaceModuleSwitchedOff(state.message)) markSpaceModuleOff(SpaceModule.poke);
        },
        builder: (context, state) => Scaffold(
          appBar: AppBar(
            title: Text(tr.received),
            actions: [
              if (state.session case final session? when state.items.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_all_outlined),
                  tooltip: tr.ignoreAll,
                  onPressed: () async => _ignore(session),
                ),
            ],
          ),
          body: SafeArea(
            bottom: false,
            child: SpaceListView<ReceivedPoke>(
              emptyIcon: Icons.waving_hand_outlined,
              emptyMessage: tr.empty,
              itemBuilder: (context, poke) => _PokeTile(
                poke,
                onGreetBack: () async => _greetBack(poke),
                onIgnore: switch (state.session) {
                  final session? => () async => _ignore(session, poke: poke),
                  null => null,
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A greeting received: who, the greeting as the forum rendered it, when; greet back, ignore.
class _PokeTile extends StatelessWidget {
  const _PokeTile(this.poke, {required this.onGreetBack, required this.onIgnore});

  final ReceivedPoke poke;
  final VoidCallback onGreetBack;
  final VoidCallback? onIgnore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tr = context.t.spacePage.poke;
    Future<void> openProfile() async => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${poke.uid}'});
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                customBorder: const CircleBorder(),
                onTap: openProfile,
                child: CircleAvatar(
                  radius: 18,
                  backgroundImage: poke.avatarUrl == null ? null : CachedImageProvider(poke.avatarUrl!),
                  child: poke.avatarUrl == null ? Text(poke.username.characters.first) : null,
                ),
              ),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            poke.username,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (poke.time != null) ...[
                          sizedBoxW8H8,
                          Text(
                            poke.time!,
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ],
                      ],
                    ),
                    sizedBoxW4H4,
                    munchElement(context, poke.content),
                  ],
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onIgnore, child: Text(tr.ignore)),
              sizedBoxW8H8,
              FilledButton.tonalIcon(
                onPressed: onGreetBack,
                icon: const Icon(Icons.waving_hand_outlined),
                label: Text(tr.greetBack),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

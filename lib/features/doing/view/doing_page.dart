import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/doing/models/doing_models.dart';
import 'package:tsdm_client/features/doing/repository/doing_repository.dart';
import 'package:tsdm_client/features/doing/utils/parse_doing.dart';
import 'package:tsdm_client/features/doing/widgets/doing_widgets.dart';
import 'package:tsdm_client/features/space/cubit/space_list_cubit.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/features/space/view/space_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// The records (`home.php?mod=space&do=doing`): everyone's, of the members followed, of the friends and the
/// account's own, a tab each; or those of the member [uid] alone; or the one record [doid] (the link of a notice).
///
/// The account's own lists offer to post a record; a record shows its replies in a sheet, where they are replied to
/// and deleted as the forum printed its links.
class DoingPage extends StatefulWidget {
  /// Constructor.
  const DoingPage({this.uid, this.username, this.doid, super.key});

  /// The member whose records are shown; the lists of the account in use without one.
  final int? uid;

  /// Their name, for the title.
  final String? username;

  /// The one record shown.
  final int? doid;

  @override
  State<DoingPage> createState() => _DoingPageState();
}

class _DoingPageState extends State<DoingPage> with SingleTickerProviderStateMixin {
  /// One list only: a member's records, or one record.
  late final bool _single = (widget.uid ?? 0) > 0 || (widget.doid ?? 0) > 0;
  late final List<SpaceListCubit<Doing>> _lists = [
    if ((widget.doid ?? 0) > 0)
      _cubit(doingUrl(widget.doid!))
    else if (_single)
      _cubit(doingListUrl(uid: widget.uid))
    else
      for (final view in DoingView.values) _cubit(doingListUrl(view: view)),
  ];
  late final TabController _tabController = TabController(length: _lists.length, vsync: this)
    ..addListener(() => setState(() {}));

  static SpaceListCubit<Doing> _cubit(String url) => SpaceListCubit<Doing>(
    firstPageUrl: url,
    fetch: const DoingRepository().fetchList,
    keyOf: (e) => e.doid,
  );

  @override
  void initState() {
    super.initState();
    for (final list in _lists) {
      unawaited(list.load());
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final list in _lists) {
      unawaited(list.close());
    }
    super.dispose();
  }

  void _refreshAll() {
    for (final list in _lists) {
      unawaited(list.refresh());
    }
  }

  Future<void> _post(SpaceSession session) async {
    if (await postDoing(context, session: session) && mounted) _refreshAll();
  }

  Future<void> _delete(SpaceSession session, Doing doing) async {
    if (await deleteDoing(context, session: session, doing: doing) && mounted) _refreshAll();
  }

  Widget _list(SpaceListCubit<Doing> cubit) {
    final tr = context.t.spacePage.doing;
    return BlocProvider.value(
      value: cubit,
      child: BlocListener<SpaceListCubit<Doing>, SpaceListState<Doing>>(
        listenWhen: (prev, curr) => curr.status == SpaceLoadStatus.notice && prev.status != curr.status,
        listener: (context, state) {
          if (spaceModuleSwitchedOff(state.message)) markSpaceModuleOff(SpaceModule.doing);
        },
        child: SpaceListView<Doing>(
          emptyIcon: Icons.edit_note_outlined,
          emptyMessage: tr.empty,
          itemBuilder: (context, doing) {
            final session = context.read<SpaceListCubit<Doing>>().state.session;
            return DoingCard(
              doing,
              // The forum shows the replies to members only.
              onReplies: () async => session == null
                  ? showSnackBar(context: context, message: context.t.general.needLogin)
                  : showDoingReplies(context, doing: doing, session: session, onChanged: _refreshAll),
              onDelete: session != null && doing.canDelete ? () async => _delete(session, doing) : null,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.doing;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.username ?? tr.title),
        bottom: _single
            ? null
            : TabBar(
                controller: _tabController,
                tabs: [
                  for (final view in DoingView.values)
                    Tab(
                      text: switch (view) {
                        DoingView.all => tr.all,
                        DoingView.follow => tr.follow,
                        DoingView.friends => tr.friends,
                        DoingView.mine => tr.mine,
                      },
                    ),
                ],
              ),
      ),
      // To whom the forum printed its form on the list shown, on the account that list was served to.
      floatingActionButton: BlocBuilder<SpaceListCubit<Doing>, SpaceListState<Doing>>(
        bloc: _lists[_tabController.index],
        builder: (context, state) => switch (state.session) {
          final session? when state.canPost && state.status == SpaceLoadStatus.success => FloatingActionButton(
            tooltip: tr.post,
            onPressed: () async => _post(session),
            child: const Icon(Icons.edit_note_outlined),
          ),
          _ => const SizedBox.shrink(),
        },
      ),
      body: SafeArea(
        bottom: false,
        child: _single
            ? _list(_lists.single)
            : TabBarView(controller: _tabController, children: [for (final list in _lists) _list(list)]),
      ),
    );
  }
}

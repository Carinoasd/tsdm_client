import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/models/poll_voters.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Show who voted for [initial], with the other options of [poll] one tap away. Only for a poll whose voters the
/// forum shows to this account ([ForumPoll.votersUrl]).
Future<void> showPollVoters(BuildContext context, PollCubit cubit, ForumPoll poll, PollOption initial) =>
    showCustomBottomSheet<void>(
      context: context,
      title: context.t.specialThread.poll.viewVoters,
      builder: (context) => PollVotersList(cubit: cubit, options: poll.options, initial: initial),
    );

/// The voters of one option at a time, [initial] first.
class PollVotersList extends StatefulWidget {
  /// Constructor.
  const PollVotersList({required this.cubit, required this.options, required this.initial, super.key});

  /// Loads the lists.
  final PollCubit cubit;

  /// Options that can be chosen.
  final List<PollOption> options;

  /// Option shown first.
  final PollOption initial;

  @override
  State<PollVotersList> createState() => _PollVotersListState();
}

class _PollVotersListState extends State<PollVotersList> {
  late PollOption _option = widget.initial;
  final _voters = <PollVoter>[];
  var _page = 0;
  var _hasNext = false;
  var _loading = false;
  var _failed = false;

  /// Bumped when the option changes, so an answer for the option left is dropped.
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    final id = _option.id;
    if (id == null || _loading) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.cubit.loadVoters(id, page: _page + 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _page++;
        _voters.addAll(page.voters);
        _hasNext = page.hasNext;
        _loading = false;
      });
    } on Exception {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _choose(PollOption option) {
    if (option == _option) return;
    setState(() {
      _generation++;
      _option = option;
      _voters.clear();
      _page = 0;
      _hasNext = false;
      _loading = false;
      _failed = false;
    });
    unawaited(_more());
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.general;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        DropdownButton<PollOption>(
          isExpanded: true,
          value: _option,
          items: [
            for (final option in widget.options)
              if (option.id != null)
                DropdownMenuItem(
                  value: option,
                  child: Text(option.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
          ],
          onChanged: (option) {
            if (option != null) _choose(option);
          },
        ),
        for (final voter in _voters)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text(voter.name),
            onTap: () async {
              // Close the sheet first: the profile page opens on the page below it.
              final router = GoRouter.of(context);
              context.pop();
              await router.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '${voter.uid}'});
            },
          ),
        if (_loading)
          const Center(
            child: Padding(padding: EdgeInsets.all(16), child: CircularIndicator()),
          ),
        if (_failed)
          Wrap(
            spacing: 8,
            children: [
              TextButton(onPressed: _more, child: Text(tr.retry)),
              if (widget.cubit.state.poll?.votersUrl case final url?)
                TextButton(
                  onPressed: () async => context.dispatchAsUrl(url, external: true),
                  child: Text(tr.openInBrowser),
                ),
            ],
          ),
        if (!_loading && !_failed && _hasNext) TextButton(onPressed: _more, child: Text(tr.more)),
        if (!_loading && !_failed && _voters.isEmpty && _page > 0) Center(child: Text(tr.noData)),
      ],
    );
  }
}

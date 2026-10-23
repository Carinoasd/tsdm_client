part of 'widgets.dart';

/// Rows of one pinned thread group, the same in the cards of [PinSection] and the tabs of [PinTabSection].
///
/// Rows whose author link names a user blocked locally are left out; the uid only comes from the forum's profile
/// link of the row, never from the name. The posting rank ([PinnedThreadGroup.isRank]) lists users with their post
/// count instead of threads with their author.
class PinnedThreadList extends StatelessWidget with LoggerMixin {
  /// Constructor.
  const PinnedThreadList(this.group, {super.key});

  /// The group to list.
  final PinnedThreadGroup group;

  Widget _sectionThreadBuilder(BuildContext context, PinnedThread pinnedThread, {bool isRank = false}) {
    final String username;
    final String threadTitle;
    if (isRank) {
      username = pinnedThread.threadTitle;
      threadTitle = pinnedThread.authorName;
    } else {
      username = pinnedThread.authorName;
      threadTitle = pinnedThread.threadTitle;
    }

    return ListTile(
      // 72 is the height when thread title is not null.
      // Set this value to make every group of section has the same height.
      minTileHeight: 72,
      leading: GestureDetector(
        child: HeroUserAvatar(username: username, avatarUrl: null, disableHero: true),
        onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'username': username}),
      ),
      title: GestureDetector(
        child: Row(children: [SingleLineText(username)]),
        onTap: () async => context.pushNamed(ScreenPaths.profile, queryParameters: {'username': username}),
      ),
      subtitle: isRank ? null : SingleLineText(threadTitle, overflow: TextOverflow.ellipsis),
      trailing: isRank ? SingleLineText(threadTitle) : null,
      onTap: () async {
        final target = pinnedThread.threadUrl.parseUrlToRoute();
        if (target == null) {
          error('invalid pinned thread url: ${pinnedThread.threadUrl}');
          return;
        }
        await context.pushNamed(
          target.screenPath,
          pathParameters: target.pathParameters,
          queryParameters: target.queryParameters.copyWith({'appBarTitle': pinnedThread.threadTitle}),
        );
      },
    );
  }

  /// Record the author of every thread of [group] in [ThreadAuthorCache], blocked or not; the rank lists members, not
  /// threads.
  static void recordAuthors(PinnedThreadGroup group) {
    if (group.isRank) {
      return;
    }
    for (final e in group.threadList) {
      final tid = Uri.tryParse(e.threadUrl.replaceAll('&amp;', '&'))?.queryParameters['tid'];
      ThreadAuthorCache.record(tid, uidOfProfileUrl(e.authorUrl)?.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    recordAuthors(group);
    final blockList = currentBlockList(context);
    final listTileList = group.threadList
        .where((e) => !blockList.hides(uidOfProfileUrl(e.authorUrl)))
        .map((e) => _sectionThreadBuilder(context, e, isRank: group.isRank))
        .toList();

    return Column(children: listTileList);
  }
}

/// All pinned thread in homepage.
///
/// Threads are separated into different groups, one card each side by side (medium and wide homepage layouts).
class PinSection extends StatelessWidget {
  /// Constructor.
  const PinSection(this.pinnedThreadGroup, {super.key});

  /// All pinned thread gathered in groups.
  final List<PinnedThreadGroup> pinnedThreadGroup;

  Widget _buildSection(BuildContext context, double textScaleFactor) {
    final ret = <Widget>[];

    final count = pinnedThreadGroup.length;

    for (var i = 0; i < count; i++) {
      final sectionName = pinnedThreadGroup[i].title;
      ret.add(
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: edgeInsetsT8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    sizedBoxW12H12,
                    Text(sectionName, style: Theme.of(context).textTheme.titleLarge),
                  ],
                ),
                sizedBoxW12H12,
                PinnedThreadList(pinnedThreadGroup[i]),
              ],
            ),
          ),
        ),
      );
    }

    return GridView(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 670,
        mainAxisExtent: 700 + math.max(25 * ((textScaleFactor - 1) / 0.1), 0),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      shrinkWrap: true,
      children: ret,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Pinned threads come from a customized block in forum homepage which no longer exists after the server upgraded
    // to Discuz! X5. Show nothing when empty.
    if (pinnedThreadGroup.isEmpty) {
      return sizedBoxEmpty;
    }
    // The text scale in effect: the system font size times the app's own scale (appTextScaler).
    final textScaleFactor = MediaQuery.textScalerOf(context).scale(14) / 14;
    return _buildSection(context, textScaleFactor);
  }
}

/// Horizontal padding of the tab row of [PinTabSection], inside its scroll view.
const _pinTabRowPadding = 8.0;

/// All pinned thread groups in one card of the phone homepage (compact layout): a row of tabs, the rows of the
/// selected group under it.
///
/// Seven cards of ten rows each made the phone homepage very long. The tabs look like those of the forum guide card
/// ([HomeCardTab]) and scroll sideways when they do not fit; the rows are the ones of [PinSection]
/// ([PinnedThreadList]). The selected group is remembered by its title in the settings
/// ([SettingsKeys.homepagePinnedGroup]): it stays selected after a refresh, which builds this card anew, and after a
/// restart; the first group is shown when the forum no longer has that title. A single group shows its title instead
/// of a row with one tab.
class PinTabSection extends StatefulWidget {
  /// Constructor.
  const PinTabSection(this.pinnedThreadGroup, {super.key});

  /// All pinned thread gathered in groups.
  final List<PinnedThreadGroup> pinnedThreadGroup;

  @override
  State<PinTabSection> createState() => _PinTabSectionState();
}

class _PinTabSectionState extends State<PinTabSection> {
  /// Title selected in this card; the settings answer the selection a little later.
  String? _chosen;

  /// Position of the group shown by the last build.
  int _shown = 0;

  final _tabsController = ScrollController();

  /// Keys of the tabs by position, to bring the selected one into view.
  final _tabKeys = <GlobalKey>[];

  @override
  void initState() {
    super.initState();
    // A remembered group may be past the right edge of a phone: its tab is scrolled into view at once.
    _revealSelectedTab(animate: false);
  }

  @override
  void dispose() {
    _tabsController.dispose();
    super.dispose();
  }

  void _select(PinnedThreadGroup group) {
    setState(() => _chosen = group.title);
    context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.homepagePinnedGroup, group.title));
    _revealSelectedTab(animate: true);
  }

  /// Scroll the tab row, and only the tab row, so the selected tab is fully visible: the page stays where it is.
  void _revealSelectedTab({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabsController.hasClients) {
        return;
      }
      final tab = _shown < _tabKeys.length ? _tabKeys[_shown].currentContext?.findRenderObject() : null;
      if (tab is! RenderBox || !tab.hasSize) {
        return;
      }
      final viewport = RenderAbstractViewport.maybeOf(tab);
      if (viewport == null) {
        return;
      }
      final position = _tabsController.position;
      // The offsets putting the tab at the start and at the end of the row, its padding kept on that side.
      final atStart = viewport.getOffsetToReveal(tab, 0).offset - _pinTabRowPadding;
      final atEnd = viewport.getOffsetToReveal(tab, 1).offset + _pinTabRowPadding;
      final target = math
          .min(math.max(position.pixels, atEnd), atStart)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((target - position.pixels).abs() < 0.5) {
        return;
      }
      if (animate) {
        unawaited(_tabsController.animateTo(target, duration: duration200, curve: Curves.easeInOut));
      } else {
        _tabsController.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.pinnedThreadGroup;
    if (groups.isEmpty) {
      return sizedBoxEmpty;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final stored = context.select<SettingsBloc, String>((bloc) => bloc.state.settingsMap.homepagePinnedGroup);
    final wanted = _chosen ?? stored;
    _shown = math.max(0, groups.indexWhere((e) => e.title == wanted));
    final selected = groups[_shown];
    // The threads of the other groups are on the homepage too: their authors are known as when every group had a card.
    for (final (i, group) in groups.indexed) {
      if (i != _shown) {
        PinnedThreadList.recordAuthors(group);
      }
    }
    while (_tabKeys.length < groups.length) {
      _tabKeys.add(GlobalKey());
    }

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (groups.length > 1)
            SingleChildScrollView(
              controller: _tabsController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: _pinTabRowPadding),
              child: Row(
                children: [
                  for (final (i, group) in groups.indexed)
                    HomeCardTab(
                      key: _tabKeys[i],
                      label: group.title,
                      selected: i == _shown,
                      onTap: () => _select(group),
                    ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Text(
                selected.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          Divider(height: 1, color: colorScheme.outlineVariant),
          // The card grows or shrinks smoothly to the rows of the new group; the page offset is left alone.
          AnimatedSize(
            duration: duration200,
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: PinnedThreadList(selected, key: ValueKey(_shown)),
            ),
          ),
        ],
      ),
    );
  }
}

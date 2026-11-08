import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/quick_open/models/quick_open_candidate.dart';
import 'package:tsdm_client/features/quick_open/repository/quick_open_sources_loader.dart';
import 'package:tsdm_client/features/quick_open/utils/quick_open_search.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Opens the quick open box over [context] (a context under the root navigator).
Future<void> showQuickOpenDialog(BuildContext context) => showDialog<void>(
  context: context,
  barrierLabel: context.t.keyboardShortcutsPage.commands.quickOpen,
  builder: (_) => const RootPage(DialogPaths.quickOpen, QuickOpenDialog()),
);

/// The icon of a kind of candidate.
IconData quickOpenIconOf(QuickOpenKind kind) => switch (kind) {
  QuickOpenKind.typedThread => Icons.article_outlined,
  QuickOpenKind.typedLink => Icons.link,
  QuickOpenKind.forum => Icons.forum_outlined,
  QuickOpenKind.thread => Icons.history,
  QuickOpenKind.user => Icons.person_outline,
  QuickOpenKind.search => Icons.search,
};

/// Box to jump anywhere by typing: a thread id or link, or part of the name of a forum, a thread visited recently or a
/// user. Up and down move the selection, Enter opens it (the first line at first), Esc closes the box.
class QuickOpenDialog extends StatefulWidget {
  /// Constructor.
  const QuickOpenDialog({this.sources, this.loader, super.key});

  /// Fixed sources instead of loading them from the app, for tests.
  @visibleForTesting
  final QuickOpenSources? sources;

  /// Loads the sources instead of the app's own, for tests; with [sources] given and no loader, nothing is loaded.
  @visibleForTesting
  final Future<void> Function(BuildContext context, {QuickOpenSourcesArrived onLoaded, bool Function() isActive})?
  loader;

  @override
  State<QuickOpenDialog> createState() => _QuickOpenDialogState();
}

class _QuickOpenDialogState extends State<QuickOpenDialog> {
  static const double _itemExtent = 48;

  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  late QuickOpenSources _sources = widget.sources ?? const QuickOpenSources();
  List<QuickOpenCandidate> _candidates = const [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refresh);
    final load = widget.loader ?? (widget.sources == null ? loadQuickOpenSources : null);
    if (load != null) {
      unawaited(
        load(
          context,
          isActive: () => mounted,
          onLoaded: ({forums, threads, users}) {
            _sources = QuickOpenSources(
              forums: forums ?? _sources.forums,
              threads: threads ?? _sources.threads,
              users: users ?? _sources.users,
            );
            _rebuildCandidates(keepSelection: true);
          },
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Typing starts the list over; a source arriving late only adds to it, and the line selected stays the selected.
  void _refresh() => _rebuildCandidates(keepSelection: false);

  void _rebuildCandidates({required bool keepSelection}) {
    final previous = _candidates.isEmpty ? null : _candidates[_selected];
    final candidates = buildQuickOpenCandidates(_controller.text, _sources);
    var selected = 0;
    if (keepSelection && previous != null) {
      final index = candidates.indexWhere(
        (e) => e.kind == previous.kind && e.title == previous.title && _sameRoute(e.route, previous.route),
      );
      selected = index < 0 ? 0 : index;
    }
    setState(() {
      _candidates = candidates;
      _selected = selected;
    });
    if (!keepSelection && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  bool _sameRoute(RecognizedRoute a, RecognizedRoute b) =>
      a.screenPath == b.screenPath &&
      mapEquals(a.pathParameters, b.pathParameters) &&
      mapEquals(a.queryParameters, b.queryParameters);

  void _move(int delta) {
    if (_candidates.isEmpty) {
      return;
    }
    setState(() => _selected = (_selected + delta) % _candidates.length);
    if (!_scrollController.hasClients) {
      return;
    }
    final top = _selected * _itemExtent;
    final position = _scrollController.position;
    if (top < position.pixels) {
      _scrollController.jumpTo(top);
    } else if (top + _itemExtent > position.pixels + position.viewportDimension) {
      _scrollController.jumpTo(top + _itemExtent - position.viewportDimension);
    }
  }

  void _open(QuickOpenCandidate? candidate) {
    if (candidate == null) {
      return;
    }
    final router = GoRouter.of(context);
    final route = candidate.route;
    Navigator.of(context).pop();
    unawaited(
      router.pushNamed<void>(
        route.screenPath,
        pathParameters: route.pathParameters,
        queryParameters: route.queryParameters,
      ),
    );
  }

  String _titleOf(QuickOpenCandidate candidate) =>
      candidate.kind == QuickOpenKind.search ? context.t.quickOpen.search(text: candidate.title) : candidate.title;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: const Alignment(0, -0.5),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Dialog(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
                  },
                  child: TextField(
                    key: const Key('quickOpenField'),
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.go,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.bolt), border: OutlineInputBorder()),
                    onSubmitted: (_) => _open(_candidates.isEmpty ? null : _candidates[_selected]),
                  ),
                ),
                if (_candidates.isNotEmpty)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: _itemExtent * 8),
                        child: ListView.builder(
                          controller: _scrollController,
                          shrinkWrap: true,
                          itemExtent: _itemExtent,
                          itemCount: _candidates.length,
                          itemBuilder: (context, index) {
                            final candidate = _candidates[index];
                            return ListTile(
                              key: ValueKey('quickOpenItem$index'),
                              selected: index == _selected,
                              selectedTileColor: colorScheme.secondaryContainer,
                              leading: Icon(quickOpenIconOf(candidate.kind)),
                              title: Text(_titleOf(candidate), maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => _open(candidate),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

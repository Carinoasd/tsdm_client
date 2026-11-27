import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/local_filter.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The filter of a list kept on the device: whether its field is shown in the app bar, and the words typed.
///
/// A page makes one, puts a [ListFilterAppBar] in its scaffold and filters what it lists with [matches]. Listeners are
/// told when the field opens or closes and when the words change.
final class ListFilterController extends ChangeNotifier {
  /// The field of the app bar.
  final TextEditingController text = TextEditingController();

  bool _open = false;

  /// Set by [dispose]: the dictionary may arrive after the page was left.
  bool _disposed = false;
  List<String> _tokens = const [];
  String _query = '';

  /// Whether the field is shown.
  bool get open => _open;

  /// The words typed, as typed (trimmed); empty when nothing filters the list.
  String get query => _query;

  /// Whether the list is filtered: the field is shown and holds words.
  bool get active => _tokens.isNotEmpty;

  /// Show the field. The dictionary of the simplified characters is loaded on the way, not waited for: the list is
  /// filtered again once it is there.
  void show() {
    if (_open) {
      return;
    }
    _open = true;
    notifyListeners();
    unawaited(
      ensureSearchFolding().then((_) {
        if (!_disposed && _open && _query.isNotEmpty) {
          _tokens = searchTokens(_query);
          notifyListeners();
        }
      }),
    );
  }

  /// Hide the field and list everything again.
  void close() {
    if (!_open) {
      return;
    }
    _open = false;
    text.clear();
    _query = '';
    _tokens = const [];
    notifyListeners();
  }

  /// The field was edited.
  void edited(String value) {
    final query = value.trim();
    if (query == _query) {
      return;
    }
    _query = query;
    _tokens = searchTokens(query);
    notifyListeners();
  }

  /// Whether an item with the texts [fields] is listed: every word typed is in one of them ([matchesSearch]).
  bool matches(Iterable<String?> fields) => matchesSearch(_tokens, fields);

  @override
  void dispose() {
    _disposed = true;
    text.dispose();
    super.dispose();
  }
}

/// The app bar of a page whose list can be filtered: [title] and a search button before the page's own [actions];
/// once the button is tapped, the field instead, with a way back to the title.
///
/// The system's back closes the field first ([ListFilterBackScope] around the page's body).
class ListFilterAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Constructor.
  const ListFilterAppBar({
    required this.controller,
    required this.title,
    this.actions = const [],
    this.bottom,
    super.key,
  });

  /// The filter of the page.
  final ListFilterController controller;

  /// Title of the page.
  final String title;

  /// The page's own actions, after the search button. Hidden while the field is shown.
  final List<Widget> actions;

  /// What stays under the bar (tabs, a tip).
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final tr = context.t.listFilter;
      if (!controller.open) {
        return AppBar(
          title: Text(title),
          actions: [
            IconButton(
              key: const ValueKey('list-filter-open'),
              icon: const Icon(Icons.search_outlined),
              tooltip: tr.open,
              onPressed: controller.show,
            ),
            ...actions,
          ],
          bottom: bottom,
        );
      }
      return AppBar(
        leading: IconButton(
          key: const ValueKey('list-filter-close'),
          icon: const BackButtonIcon(),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: controller.close,
        ),
        title: TextField(
          key: const ValueKey('list-filter-field'),
          controller: controller.text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: tr.hint, border: InputBorder.none),
          onChanged: controller.edited,
        ),
        actions: [
          if (controller.text.text.isNotEmpty)
            IconButton(
              key: const ValueKey('list-filter-clear'),
              icon: const Icon(Icons.clear_outlined),
              tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
              onPressed: () {
                controller.text.clear();
                controller.edited('');
              },
            ),
        ],
        bottom: bottom,
      );
    },
  );
}

/// The system's back closes the filter's field first; with the field closed it leaves the page as ever.
class ListFilterBackScope extends StatelessWidget {
  /// Constructor.
  const ListFilterBackScope({required this.controller, required this.child, super.key});

  /// The filter of the page.
  final ListFilterController controller;

  /// The page.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Under the app's router the back button is heard here before the router pops the page. Without one (a page
    // shown on a plain navigator) the route itself is asked not to pop while the field is open.
    if (Router.maybeOf(context) == null) {
      return ListenableBuilder(
        listenable: controller,
        builder: (context, child) => PopScope(
          canPop: !controller.open,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              controller.close();
            }
          },
          child: child!,
        ),
        child: child,
      );
    }
    return BackButtonListener(
      onBackButtonPressed: () async {
        // Only while the page is the one on top (not under a dialog or a page opened from it).
        if (!controller.open || !(ModalRoute.of(context)?.isCurrent ?? true)) {
          return false;
        }
        controller.close();
        return true;
      },
      child: child,
    );
  }
}

/// What a filtered list shows when nothing fits the words typed: not the empty list's own message.
class ListFilterNoMatch extends StatelessWidget {
  /// Constructor.
  const ListFilterNoMatch(this.query, {super.key});

  /// The words typed.
  final String query;

  @override
  Widget build(BuildContext context) => AppStateView(
    key: const ValueKey('list-filter-no-match'),
    icon: Icons.search_off_outlined,
    message: context.t.listFilter.noMatch(query: query),
  );
}

/// Owns the [ListFilterController] of a page and builds the page with it, again whenever the filter changes; the
/// system's back closes the field first ([ListFilterBackScope]).
class ListFilterHost extends StatefulWidget {
  /// Constructor.
  const ListFilterHost({required this.builder, super.key});

  /// Builds the page: a scaffold with a [ListFilterAppBar] of the controller, listing what [ListFilterController
  /// .matches].
  final Widget Function(BuildContext context, ListFilterController filter) builder;

  @override
  State<ListFilterHost> createState() => _ListFilterHostState();
}

class _ListFilterHostState extends State<ListFilterHost> {
  final _filter = ListFilterController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListFilterBackScope(
    controller: _filter,
    child: ListenableBuilder(listenable: _filter, builder: (context, _) => widget.builder(context, _filter)),
  );
}

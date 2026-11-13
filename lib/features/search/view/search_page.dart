import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/jump_page/widgets/jump_page_dialog.dart';
import 'package:tsdm_client/features/open_in_app/utils/forum_link_in_text.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/search/bloc/search_bloc.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/search/repository/search_history_store.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/features/search/widgets/search_filter_bar.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

/// Page of search, including a form to fill search parameters and search
/// results.
class SearchPage extends StatefulWidget {
  /// Constructor.
  const SearchPage({this.keyword, this.authorUid, this.authorName, this.fid, this.page, super.key});

  /// Keyword to search.
  final String? keyword;

  /// Author's uid.
  final String? authorUid;

  /// Author's user name.
  ///
  /// Preferred over [authorUid] when both are given, see [buildSearchQuery].
  final String? authorName;

  /// Forum id to search, several joined by `_` ([searchForumIdsValue]).
  final String? fid;

  /// Page number of search result.
  final String? page;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with LoggerMixin {
  final formKey = GlobalKey<FormState>();
  final keywordController = TextEditingController();
  final authorController = TextEditingController();
  final keywordFocus = FocusNode();
  final scrollController = ScrollController();

  /// Flags on limiting author.
  bool unlimitedAuthor = true;

  /// The forums to search in, empty for any forum.
  List<int> fids = const [];

  /// Time range, order and title only of the next search.
  SearchFilter filter = const SearchFilter();

  /// The forums the search can be limited to, from the forum index; empty until it loaded.
  List<SearchForumOption> forumOptions = const [];

  /// The keywords searched before by the current account, the latest first.
  List<String> history = const [];

  /// Where [history] is kept, null when there is no storage (tests).
  final SearchHistoryStore? _historyStore = getIt.isRegistered<StorageProvider>()
      ? SearchHistoryStore(getIt.get<StorageProvider>())
      : null;

  /// The account whose [history] is shown, 0 for the guest: the account the page was opened with (switching accounts
  /// goes through the app's root, which opens the search page anew).
  int _historyUid = 0;

  /// Flag on expand search form.
  ///
  /// true: Form is expanded.
  /// false: Form is collapsed.
  bool expandForm = true;

  /// Parameters used last time.
  /// Use these when search form is collapsed and get no state.
  String lastKeyword = '';
  String lastAuthorUid = '0';
  String lastAuthorName = '';
  String lastFid = '0';
  SearchFilter lastFilter = const SearchFilter();

  /// Run the search once the page is built, when opened with an author from a profile page.
  bool _searchOnBuild = false;

  /// The keyword field's text and selection before its last change of the text, and its value now: what a change put
  /// in ([forumLinkPasted]).
  String _keywordBefore = '';
  TextSelection? _keywordSelectionBefore;
  TextEditingValue _keywordNow = TextEditingValue.empty;

  /// The author the page was opened with by name ([SearchPage.authorName]: a profile page, a "TA的主题" link naming
  /// the member): searched by name while the author field still holds it, also when the name is all digits, which
  /// the field otherwise takes as a uid.
  String? _authorByName;

  @override
  void initState() {
    super.initState();
    // Set to the fid passed from outside.
    // This may by opening the search page from a forum page.
    if (widget.fid != null) {
      fids = searchForumIdsOf(widget.fid!);
    }
    if (widget.keyword case final String keyword when keyword.isNotEmpty) {
      keywordController.text = keyword;
    }
    keywordFocus.addListener(() => setState(() {}));
    _keywordNow = keywordController.value;
    keywordController.addListener(() {
      if (keywordController.text != _keywordNow.text) {
        _keywordBefore = _keywordNow.text;
        _keywordSelectionBefore = _keywordNow.selection;
      }
      _keywordNow = keywordController.value;
    });
    _historyUid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid ?? 0;
    unawaited(_loadHistory());
    // The names of the forums the page was opened with; otherwise the index is asked when the picker opens.
    if (fids.isNotEmpty) {
      unawaited(_loadForumOptions());
    }
    final author = switch ((widget.authorName, widget.authorUid)) {
      (final String name, _) when name.isNotEmpty => name,
      (_, final String uid) when uid.isNotEmpty && uid != '0' => uid,
      _ => null,
    };
    if (author != null) {
      if (widget.authorName case final String name when name.isNotEmpty) {
        _authorByName = name;
      }
      setState(() {
        authorController.text = author;
        unlimitedAuthor = false;
      });
      // "Search this member's posts" on a profile page: the user came for the results, not for the form.
      _searchOnBuild = true;
    }
  }

  @override
  void dispose() {
    keywordController.dispose();
    authorController.dispose();
    keywordFocus.dispose();
    scrollController.dispose();
    super.dispose();
  }

  /// Do the search action.
  ///
  /// This is the last internal action so there is no parameter checking.
  /// MUST ensure parameters are checked before calling.
  Future<void> _doSearch(
    BuildContext context, {
    required String keyword,
    required String authorUid,
    required String authorName,
    required String fid,
    required SearchFilter filter,
    required int page,
  }) async {
    debug(
      'search with args: keyword=$keyword, authorUid=$authorUid, authorName=$authorName, '
      'fid=$fid, filter=$filter, page=$page',
    );

    context.read<SearchBloc>().add(
      SearchRequested(
        keyword: keyword,
        uid: authorUid,
        authorName: authorName,
        fid: fid,
        filter: filter,
        pageNumer: page,
      ),
    );

    // Only return to top when attached (not the first search).
    if (scrollController.hasClients) {
      await scrollController.animateTo(0, curve: Curves.ease, duration: const Duration(microseconds: 500));
      setState(() {});
    }
  }

  /// Search with given keyword, authorUid and fid, return the [page] index
  /// in result pages.
  /// Always validate search parameters.
  Future<void> _search(BuildContext context, [int page = 0]) async {
    // A forum link in the keyword is opened, not searched.
    if (formKey.currentState != null && page == 0) {
      if (findForumLinkInText(keywordController.text) case final link?) {
        _openLink(context, link);
        return;
      }
    }
    if (formKey.currentState == null) {
      // Collapsed: the search shown is asked again with the parameters it was asked with (the page switches do not
      // come here, they go through the bloc, see _turnPage).
      if (lastKeyword.isNotEmpty || lastAuthorUid != '0' || lastAuthorName.isNotEmpty || lastFid != '0') {
        await _doSearch(
          context,
          keyword: lastKeyword,
          authorUid: lastAuthorUid,
          authorName: lastAuthorName,
          fid: lastFid,
          filter: lastFilter,
          page: page,
        );
      }
      return;
    }

    if (!(formKey.currentState!).validate()) {
      // Invalid parameters.
      return;
    }

    final keyword = keywordController.text;
    final (authorUid, authorName) = _authorOf(authorController.text);
    final fid = searchForumIdsValue(fids);
    keywordFocus.unfocus();
    // Remembered when asked, not only when found: a search the forum held back for its interval is asked again.
    unawaited(_addHistory(keyword));
    await _doSearch(
      context,
      keyword: keyword,
      authorUid: authorUid,
      authorName: authorName,
      fid: fid,
      filter: filter,
      page: page,
    );
    lastKeyword = keyword;
    lastAuthorUid = authorUid;
    lastAuthorName = authorName;
    lastFid = fid;
    lastFilter = filter;
  }

  /// Open the page of [link], a forum link in the keyword field.
  void _openLink(BuildContext context, ForumLinkInText link) {
    keywordFocus.unfocus();
    unawaited(context.dispatchAsUrl(link.url));
  }

  /// The keyword field changed to [text]: a piece of text with a forum link pasted at once opens the link, and the
  /// field gets back what it held before the paste (coming back to the page does not open it again). A link typed
  /// character by character stays, offered in [_buildOpenLinkRow].
  void _onKeywordChanged(BuildContext context, String text) {
    final link = forumLinkPasted(_keywordBefore, text, selection: _keywordSelectionBefore);
    if (link != null) {
      final before = _keywordBefore;
      keywordController.value = TextEditingValue(
        text: before,
        selection: TextSelection.collapsed(offset: before.length),
      );
      _openLink(context, link);
    }
    setState(() {});
  }

  /// The line opening the forum link in the keyword field, null when it holds none.
  Widget? _buildOpenLinkRow(BuildContext context) {
    final link = findForumLinkInText(keywordController.text);
    if (link == null) {
      return null;
    }
    final tr = context.t.linkToken;
    return AppSurface(
      key: const ValueKey('search-open-link'),
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(link.isThread ? Icons.article_outlined : Icons.open_in_new),
        title: Text(link.isThread ? tr.openThread : tr.openPage),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openLink(context, link),
      ),
    );
  }

  Future<void> _loadHistory() async {
    final store = _historyStore;
    if (store == null) {
      return;
    }
    final uid = _historyUid;
    final loaded = await store.load(uid);
    if (mounted && uid == _historyUid) {
      setState(() => history = loaded);
    }
  }

  Future<void> _addHistory(String keyword) async {
    if (keyword.trim().isEmpty) {
      return;
    }
    setState(() => history = searchHistoryWith(history, keyword));
    await _historyStore?.add(_historyUid, keyword);
  }

  Future<void> _removeHistory(String keyword) async {
    setState(() => history = history.where((e) => e != keyword).toList());
    await _historyStore?.remove(_historyUid, keyword);
  }

  Future<void> _clearHistory() async {
    setState(() => history = const []);
    await _historyStore?.clear(_historyUid);
  }

  /// The forums of the forum index (the cached homepage, fetched when there is none) as the forum picker lists them.
  Future<void> _loadForumOptions() async {
    final repository = context.readOrNull<ForumHomeRepository>();
    if (repository == null) {
      return;
    }
    final groups = (await repository.fetchHomePage().run()).fold(
      (_) => const <ForumGroup>[],
      (page) => switch (page) {
        ForumHomeWebPage(:final document) => buildGroupListFromDocument(document),
        ForumHomeApiPage(:final json) => forumGroupsFromApi(json),
      },
    );
    if (mounted) {
      setState(() => forumOptions = searchForumOptions(groups));
    }
  }

  Future<void> _pickForums() async {
    if (forumOptions.isEmpty) {
      await _loadForumOptions();
    }
    if (!mounted) {
      return;
    }
    if (forumOptions.isEmpty && fids.isEmpty) {
      // The forum index failed: nothing to pick from.
      showSnackBar(context: context, message: context.t.general.failedToLoad);
      return;
    }
    final picked = await showSearchForumPicker(context, options: forumOptions, selected: {...fids});
    if (picked != null && mounted) {
      setState(() => fids = picked.toList()..sort());
    }
  }

  /// Fill the keyword field with [keyword] from the history and search it.
  Future<void> _searchHistory(BuildContext context, String keyword) async {
    keywordController
      ..text = keyword
      ..selection = TextSelection.collapsed(offset: keyword.length);
    await _search(context);
  }

  /// Whether has previous pages in search result.
  bool _hasPreviousPage(SearchState state) {
    return state.searchResult != null && state.hasPreviousPage;
  }

  /// Whether has next pages in search result.
  bool _hasNextPage(SearchState state) {
    return state.searchResult != null && state.hasNextPage;
  }

  /// show a dialog and jump to the specified page.
  ///
  /// `state.SearchResult` is guaranteed to not be null before calling
  /// this function.
  Future<void> _gotoSpecifiedPage(BuildContext context, SearchState state) async {
    final page = await showDialog<int>(
      context: context,
      builder: (context) => RootPage(
        DialogPaths.jumpPage,
        JumpPageDialog(min: 1, current: state.searchResult!.currentPage, max: state.searchResult!.totalPages),
      ),
    );
    if (page == null || page == state.searchResult!.currentPage) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    await _turnPage(context, SearchJumpPageRequested(page));
  }

  /// Search result is guaranteed to not be null before calling this function.
  Future<void> _searchPreviousPage(BuildContext context, SearchState state) async {
    if (!_hasPreviousPage(state)) {
      return;
    }
    await _turnPage(context, SearchGotoPreviousPageRequested());
  }

  /// Search result is guaranteed to not be null before calling this function.
  Future<void> _searchNextPage(BuildContext context, SearchState state) async {
    if (!_hasNextPage(state)) {
      return;
    }
    await _turnPage(context, SearchGotoNextPageRequested());
  }

  /// Show another page of the search shown, [event]: the bloc asks it with the parameters of that search (its
  /// keyword, author, forums and filters, the search id the repository keeps), not with what the form holds now, so
  /// a filter changed without searching does not apply and the forum's interval between new searches is not hit.
  Future<void> _turnPage(BuildContext context, SearchEvent event) async {
    context.read<SearchBloc>().add(event);
    if (scrollController.hasClients) {
      await scrollController.animateTo(0, curve: Curves.ease, duration: const Duration(microseconds: 500));
    }
  }

  Widget _buildSearchButton(BuildContext context, SearchState state) {
    return SizedBox(
      height: 48,
      child: DebounceFilledButton(
        shouldDebounce: state.status.isSearching(),
        onPressed: () async => _search(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_outlined),
            sizedBoxW8H8,
            Flexible(child: Text(context.t.searchPage.form.search, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }

  /// The author field takes a uid or a user name; empty means any author.
  String? _validateAuthor(BuildContext context, String? v) {
    final text = v?.trim() ?? '';
    if (text.isEmpty) {
      setState(() {
        unlimitedAuthor = true;
      });
      return null;
    }
    // Same restriction as the keyword: the server rejects the wildcard.
    if (text.contains('%')) {
      return context.t.searchPage.form.authorInvalid;
    }
    return null;
  }

  /// Split the author field into the (uid, name) pair sent to the server: digits only is a uid, anything else a name;
  /// the name the page was opened with ([_authorByName]) is a name whatever it looks like.
  (String uid, String name) _authorOf(String text) {
    final author = text.trim();
    if (author.isEmpty) {
      return ('0', '');
    }
    if (author == _authorByName?.trim()) {
      return ('0', author);
    }
    if (int.tryParse(author) case final int uid when uid >= 0) {
      return ('$uid', '');
    }
    return ('0', author);
  }

  /// The keywords searched before while the keyword field has the focus: all of them for an empty field (each one
  /// removable, all clearable), the ones starting with what is typed otherwise. Null when there are none to show.
  Widget? _buildHistory(BuildContext context) {
    if (!keywordFocus.hasFocus) {
      return null;
    }
    final typed = keywordController.text;
    final all = typed.trim().isEmpty;
    final keywords = all ? history : searchHistorySuggestions(history, typed);
    if (keywords.isEmpty) {
      return null;
    }
    final deleteTooltip = MaterialLocalizations.of(context).deleteButtonTooltip;
    // Part of the keyword field for its taps: a mouse press outside the field takes the focus away (and the history
    // with it) before the press ends on a chip.
    return TextFieldTapRegion(
      child: _historyWrap(context, keywords, all: all, deleteTooltip: deleteTooltip),
    );
  }

  Widget _historyWrap(BuildContext context, List<String> keywords, {required bool all, required String deleteTooltip}) {
    return Wrap(
      key: const ValueKey('search-history'),
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final keyword in keywords)
          InputChip(
            key: ValueKey('search-history-$keyword'),
            avatar: const Icon(Icons.history),
            label: Text(keyword, maxLines: 1, overflow: TextOverflow.ellipsis),
            onPressed: () async => _searchHistory(context, keyword),
            onDeleted: all ? () async => _removeHistory(keyword) : null,
            deleteButtonTooltipMessage: deleteTooltip,
          ),
        if (all)
          TextButton.icon(
            key: const ValueKey('search-history-clear'),
            icon: const Icon(Icons.delete_sweep_outlined),
            label: Text(context.t.searchPage.history.clear),
            onPressed: () async => _clearHistory(),
          ),
      ],
    );
  }

  Widget _buildSearchForm(BuildContext context, SearchState state) {
    final keywordField = TextFormField(
      autofocus: true,
      controller: keywordController,
      focusNode: keywordFocus,
      textInputAction: TextInputAction.search,
      onChanged: (v) => _onKeywordChanged(context, v),
      onFieldSubmitted: (_) async => _search(context),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.abc_outlined),
        labelText: context.t.searchPage.form.keyword,
      ),
      validator: (v) {
        // An invalid author tells itself, the keyword is not checked then.
        if (_validateAuthor(context, authorController.text) != null) {
          return null;
        }
        // The forum searches without a keyword when an author or a time range is given; forums alone get its empty
        // search form back.
        if (v == null || v.isEmpty && authorController.text.trim().isEmpty && filter.timeRange == SearchTimeRange.all) {
          return context.t.searchPage.form.keywordEmpty;
        }
        if (v.contains('%')) {
          return context.t.searchPage.form.keywordInvalid;
        }
        return null;
      },
    );
    final authorField = TextFormField(
      controller: authorController,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.person_outline),
        labelText: context.t.searchPage.form.author,
        suffixText: unlimitedAuthor ? context.t.searchPage.form.any : null,
      ),
      onChanged: (v) {
        setState(() {
          unlimitedAuthor = v.trim().isEmpty;
        });
      },
      validator: (v) => _validateAuthor(context, v),
    );
    final filterBar = SearchFilterBar(
      filter: filter,
      fids: fids,
      forumNames: {for (final e in forumOptions) e.fid: e.name},
      onFilterChanged: (v) => setState(() => filter = v),
      onPickForums: () async => _pickForums(),
    );
    final historyView = _buildHistory(context);

    // One surface: the keyword with the history under it while it is typed in, the author, the filters, the button.
    return AppSurface(
      padding: edgeInsetsL16T16R16B16,
      child: Form(
        key: formKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 560;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSectionHeader(
                  context.t.searchPage.title,
                  icon: Icons.manage_search_outlined,
                  padding: const EdgeInsets.only(bottom: 12),
                ),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: keywordField),
                      sizedBoxW12H12,
                      Expanded(child: authorField),
                    ],
                  )
                else ...[
                  keywordField,
                  if (historyView != null) ...[sizedBoxW8H8, historyView],
                  sizedBoxW12H12,
                  authorField,
                ],
                if (wide && historyView != null) ...[sizedBoxW8H8, historyView],
                sizedBoxW12H12,
                filterBar,
                sizedBoxW16H16,
                _buildSearchButton(context, state),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Title and counts of the result with the page switcher; the switcher goes below the counts on narrow windows.
  Widget _buildResultInfoRow(BuildContext context, SearchState state) {
    final searching = state.status.isSearching();
    final r = context.t.searchPage.result;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final result = state.searchResult;
    final info = Row(
      children: [
        const AppIconTile(Icons.list_alt_outlined, size: 36),
        sizedBoxW12H12,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.title, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
              Text(
                '${r.totalThreadCount(count: '${result?.count ?? "-"}')} · '
                '${r.pageInfo(total: result?.totalPages ?? "-")}',
                style: textTheme.bodySmall?.copyWith(color: colorScheme.outline),
              ),
            ],
          ),
        ),
      ],
    );
    final pager = AppPager(
      current: result?.currentPage,
      total: result?.totalPages,
      onPrevious: !searching && _hasPreviousPage(state) ? () async => _searchPreviousPage(context, state) : null,
      onNext: !searching && _hasNextPage(state) ? () async => _searchNextPage(context, state) : null,
      onJump: !searching && (_hasPreviousPage(state) || _hasNextPage(state)) && result != null
          ? () async => _gotoSpecifiedPage(context, state)
          : null,
    );
    return AppSurface(
      padding: edgeInsetsL12T8R12B8,
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 420
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  info,
                  sizedBoxW8H8,
                  Align(alignment: Alignment.centerRight, child: pager),
                ],
              )
            : Row(
                children: [
                  Expanded(child: info),
                  sizedBoxW8H8,
                  pager,
                ],
              ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, SearchState state) {
    // Form, result info and results share one centered column, at most [appListMaxWidth] wide, in one scroll view:
    // with the keyboard up or a large font the form scrolls instead of overflowing.
    return AppCenteredList(
      builder: (context, side, _) {
        final results = state.searchResult?.data;
        final Widget resultSliver;
        if (state.status.isSearching()) {
          resultSliver = const SliverFillRemaining(hasScrollBody: false, child: CenteredCircularIndicator());
        } else if (state.status == SearchStatus.failed) {
          // A failure is no empty result: say why, and how long the forum wants to wait when it limits searches.
          resultSliver = SliverFillRemaining(
            hasScrollBody: false,
            child: FailureView(
              failure: state.failure,
              scrollable: false,
              onRetry: () => context.read<SearchBloc>().add(const SearchRetryRequested()),
            ),
          );
        } else if (state.status == SearchStatus.initial) {
          // Nothing searched yet: what to do, not "no data".
          resultSliver = SliverFillRemaining(
            hasScrollBody: false,
            child: AppStateView(
              icon: Icons.manage_search_outlined,
              message: context.t.searchPage.result.hint,
              scrollable: false,
            ),
          );
        } else if (results == null || results.isEmpty) {
          // Nothing found, and what to try: other words, or the search without its author or forum limit.
          final limited =
              state.uid != '0' ||
              state.authorName.isNotEmpty ||
              state.fid != '0' ||
              state.filter.timeRange != SearchTimeRange.all;
          resultSliver = SliverFillRemaining(
            hasScrollBody: false,
            child: AppStateView(
              icon: Icons.search_off_outlined,
              message: context.t.searchPage.result.noData,
              detail: limited ? context.t.searchPage.result.noDataFiltered : context.t.searchPage.result.noDataHint,
              scrollable: false,
            ),
          );
        } else {
          final result = state.searchResult!;
          final bloc = context.read<SearchBloc>();
          resultSliver = SliverPadding(
            padding: side.copyWith(bottom: 12).add(context.safePadding()),
            // The end of the results is their last item: built when it comes near, it appends the next page.
            sliver: SliverList.separated(
              itemCount: results.length + 1,
              itemBuilder: (context, index) => index < results.length
                  ? SearchedThreadCard(results[index])
                  : ListFooter(
                      status: listFooterStatus(
                        hasMore: result.currentPage < result.totalPages,
                        loading: state.loadingMore,
                        failed: state.loadMoreFailed,
                      ),
                      itemCount: results.length,
                      failure: state.failure,
                      onLoadMore: () => bloc.add(const SearchLoadMoreRequested()),
                      onRetry: () => bloc.add(const SearchLoadMoreRequested()),
                    ),
              separatorBuilder: (context, index) => appListSeparator,
            ),
          );
        }
        final openLinkRow = expandForm ? _buildOpenLinkRow(context) : null;
        return CustomScrollView(
          controller: scrollController,
          slivers: [
            if (expandForm)
              SliverPadding(
                padding: side.copyWith(top: 8),
                sliver: SliverToBoxAdapter(child: _buildSearchForm(context, state)),
              ),
            if (openLinkRow != null)
              SliverPadding(
                padding: side.copyWith(top: 12),
                sliver: SliverToBoxAdapter(child: openLinkRow),
              ),
            SliverPadding(
              padding: side.copyWith(top: 12, bottom: 8),
              sliver: SliverToBoxAdapter(child: _buildResultInfoRow(context, state)),
            ),
            resultSliver,
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // A wide window shows the thread tapped on the right of the results.
    return TwoPaneLayout(list: _buildPage(context));
  }

  /// The page, under the [TwoPaneLayout] of [build].
  Widget _buildPage(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => SearchRepository()),
        BlocProvider(create: (context) => SearchBloc(searchRepository: context.repo())),
      ],
      child: BlocConsumer<SearchBloc, SearchState>(
        // The forum searched the titles though the full text was asked for (the user group may not search it): the
        // chip goes back to what was searched.
        listenWhen: (prev, curr) => curr.searchResult != prev.searchResult && curr.searchResult?.fullText == false,
        listener: (context, state) {
          if (!filter.titleOnly) {
            setState(() => filter = filter.copyWith(titleOnly: true));
          }
        },
        builder: (context, state) {
          if (_searchOnBuild) {
            _searchOnBuild = false;
            // The form exists once this frame is built; `context` here is below the bloc provider.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) {
                unawaited(_search(context));
              }
            });
          }
          return Scaffold(
            appBar: AppBar(
              title: Text(context.t.searchPage.title),
              actions: [
                const OpenInAppPageButton(),
                IconButton(
                  icon: const Icon(Icons.sell_outlined),
                  tooltip: context.t.tagPage.cloudTitle,
                  onPressed: () async => context.pushNamed(ScreenPaths.tagCloud),
                ),
                IconButton(
                  icon: Icon(expandForm ? Icons.expand_less : Icons.expand_more),
                  tooltip: expandForm
                      ? MaterialLocalizations.of(context).expandedIconTapHint
                      : MaterialLocalizations.of(context).collapsedIconTapHint,
                  onPressed: () {
                    setState(() {
                      expandForm = !expandForm;
                    });
                  },
                ),
              ],
            ),
            body: SafeArea(bottom: false, child: _buildBody(context, state)),
          );
        },
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/jump_page/widgets/jump_page_dialog.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/search/bloc/search_bloc.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_footer.dart';

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

  /// Forum id to search.
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
  final fidController = TextEditingController(text: '0');
  final scrollController = ScrollController();

  /// Flags on limiting author or fid.
  bool unlimitedAuthor = true;
  bool unlimitedFid = true;

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

  /// Run the search once the page is built, when opened with an author from a profile page.
  bool _searchOnBuild = false;

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
      setState(() {
        fidController.text = widget.fid!;
        unlimitedFid = false;
      });
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
    fidController.dispose();
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
    required int page,
  }) async {
    debug(
      'search with args: keyword=$keyword, authorUid=$authorUid, authorName=$authorName, '
      'fid=$fid, page=$page',
    );

    context.read<SearchBloc>().add(
      SearchRequested(keyword: keyword, uid: authorUid, authorName: authorName, fid: fid, pageNumer: page),
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
    if (formKey.currentState == null) {
      // Collapsed.
      // If lastKeyword is not empty, indicates there is a valid last search.
      // User want to jump to another page so use the last used parameters
      // and parameter page.
      if (lastKeyword.isNotEmpty || lastAuthorUid != '0' || lastAuthorName.isNotEmpty || lastFid != '0') {
        await _doSearch(
          context,
          keyword: lastKeyword,
          authorUid: lastAuthorUid,
          authorName: lastAuthorName,
          fid: lastFid,
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
    final fid = switch (fidController.text) {
      '' => '0',
      _ => fidController.text,
    };
    await _doSearch(context, keyword: keyword, authorUid: authorUid, authorName: authorName, fid: fid, page: page);
    lastKeyword = keyword;
    lastAuthorUid = authorUid;
    lastAuthorName = authorName;
    lastFid = fid;
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
    await _search(context, page);
  }

  /// Search result is guaranteed to not be null before calling this function.
  Future<void> _searchPreviousPage(BuildContext context, SearchState state) async {
    if (!_hasPreviousPage(state)) {
      return;
    }

    final page = state.searchResult!.currentPage;
    await _search(context, page - 1);
  }

  /// Search result is guaranteed to not be null before calling this function.
  Future<void> _searchNextPage(BuildContext context, SearchState state) async {
    if (!_hasNextPage(state)) {
      return;
    }
    final page = state.searchResult!.currentPage;
    await _search(context, page + 1);
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

  String? _validateFid(BuildContext context, String? v) {
    // Allow empty value because the default parameter in searching
    // is zero.
    if (v!.isEmpty) {
      setState(() {
        fidController.text = '0';
        unlimitedFid = true;
      });
      return null;
    }
    final i = int.tryParse(v);
    if (i == null || i < 0) {
      return context.t.searchPage.form.fidInvalid;
    }
    return null;
  }

  Widget _buildSearchForm(BuildContext context, SearchState state) {
    final keywordField = TextFormField(
      autofocus: true,
      controller: keywordController,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.abc_outlined),
        labelText: context.t.searchPage.form.keyword,
      ),
      validator: (v) {
        // FIXME: Extra validation not graceful at all.
        // Purpose is to skip keyword validation when both author and forum id are valid and not `any`.
        // The server allows searching without keyword when author or forum id is set.
        // If author or forum id is not valid, it's unnecessary to validate keyword.
        if (_validateAuthor(context, authorController.text) != null ||
            _validateFid(context, fidController.text) != null) {
          return null;
        }
        // Validation only fails when running with keyword field, in other words author and forum id are `any`.
        // It's fine to have an empty keyword when author or forum id is not `any`.
        if (v == null || v.isEmpty && authorController.text.trim().isEmpty && fidController.text == '0') {
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
    final fidField = TextFormField(
      controller: fidController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.forum_outlined),
        labelText: context.t.searchPage.form.fid,
        suffixText: unlimitedFid ? context.t.searchPage.form.any : null,
      ),
      onChanged: (v) {
        setState(() {
          unlimitedFid = fidController.text == '0';
        });
      },
      validator: (v) => _validateFid(context, v),
    );

    // One surface: keyword on its own line, the two filters side by side when there is room, the button last.
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
                keywordField,
                sizedBoxW12H12,
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: authorField),
                      sizedBoxW12H12,
                      Expanded(child: fidField),
                    ],
                  )
                else ...[
                  authorField,
                  sizedBoxW12H12,
                  fidField,
                ],
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
          final limited = state.uid != '0' || state.authorName.isNotEmpty || state.fid != '0';
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
        return CustomScrollView(
          controller: scrollController,
          slivers: [
            if (expandForm)
              SliverPadding(
                padding: side.copyWith(top: 8),
                sliver: SliverToBoxAdapter(child: _buildSearchForm(context, state)),
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
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => SearchRepository()),
        BlocProvider(create: (context) => SearchBloc(searchRepository: context.repo())),
      ],
      child: BlocBuilder<SearchBloc, SearchState>(
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

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/list.dart';
import 'package:tsdm_client/features/jump_page/widgets/jump_page_dialog.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/search/bloc/search_bloc.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';
import 'package:tsdm_client/widgets/indicator.dart';

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
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 50,
            child: DebounceFilledButton(
              shouldDebounce: state.status.isSearching(),
              onPressed: () async => _search(context),
              child: Text(context.t.searchPage.form.search),
            ),
          ),
        ),
      ],
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

  /// Split the author field into the (uid, name) pair sent to the server: digits only is a uid, anything else a name.
  (String uid, String name) _authorOf(String text) {
    final author = text.trim();
    if (author.isEmpty) {
      return ('0', '');
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
    return Form(
      key: formKey,
      child: Column(
        children: <Widget>[
          TextFormField(
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
          ),
          TextFormField(
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
          ),
          TextFormField(
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
          ),
          _buildSearchButton(context, state),
        ].insertBetween(sizedBoxW12H12),
      ),
    );
  }

  Widget _buildResultInfoRow(BuildContext context, SearchState state) {
    final searching = state.status.isSearching();
    final r = context.t.searchPage.result;
    final searchResultCount =
        '${r.totalThreadCount(count: '${state.searchResult?.count ?? "-"}')} '
        '${r.pageInfo(total: state.searchResult?.totalPages ?? "-")}';
    return Row(
      children: [
        Expanded(
          child: ListTile(
            title: Text(context.t.searchPage.result.title, style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text(searchResultCount),
            visualDensity: VisualDensity.compact,
          ),
        ),
        // Text(),
        IconButton(
          icon: const Icon(Icons.arrow_left_outlined),
          onPressed: !searching && _hasPreviousPage(state) ? () async => _searchPreviousPage(context, state) : null,
        ),
        TextButton(
          onPressed: !searching && (_hasPreviousPage(state) || _hasNextPage(state)) && state.searchResult != null
              ? () async {
                  await _gotoSpecifiedPage(context, state);
                }
              : null,
          child: Text('${state.searchResult?.currentPage ?? "-"}'),
        ),
        IconButton(
          icon: const Icon(Icons.arrow_right_outlined),
          onPressed: !searching && _hasNextPage(state) ? () async => _searchNextPage(context, state) : null,
        ),
      ],
    );
  }

  Widget _buildSearchResult(BuildContext context, SearchState state) {
    if (state.status.isSearching()) {
      return const Expanded(child: CenteredCircularIndicator());
    } else if (state.searchResult?.data?.isEmpty ?? true) {
      return Expanded(child: Center(child: Text(context.t.searchPage.result.noData)));
    }

    return Expanded(
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView.separated(
          controller: scrollController,
          shrinkWrap: true,
          itemCount: state.searchResult!.data!.length,
          itemBuilder: (context, index) {
            final d = state.searchResult!.data![index];
            return SearchedThreadCard(d);
          },
          separatorBuilder: (context, index) => sizedBoxW4H4,
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, SearchState state) {
    return Padding(
      padding: edgeInsetsL12T4R12,
      child: Column(
        children: [
          if (expandForm) _buildSearchForm(context, state),
          _buildResultInfoRow(context, state),
          _buildSearchResult(context, state),
        ].insertBetween(sizedBoxW12H12),
      ),
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
                  onPressed: () {
                    setState(() {
                      expandForm = !expandForm;
                    });
                  },
                ),
              ],
            ),
            // FIXME: Support android landscape orientation.
            body: _buildBody(context, state),
          );
        },
      ),
    );
  }
}

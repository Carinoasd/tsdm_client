import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/utils/load_failure.dart';

/// The pages of a paged list of the collection pages, loaded one after another: the first page ([first], as last
/// loaded), the items of every page loaded so far, and whether the next one is loading or failed.
final class CollectionPager<P, I> extends ChangeNotifier {
  /// Constructor.
  CollectionPager({required this.fetch, required this.itemsOf, required this.pagesOf});

  /// Load page N (1 based).
  final AsyncEither<P> Function(int page) fetch;

  /// The items of a page.
  final List<I> Function(P page) itemsOf;

  /// The pages of the list a page tells.
  final int Function(P page) pagesOf;

  /// The first page as last loaded, null before it loaded.
  P? first;

  /// The items of the pages loaded.
  final List<I> items = [];

  /// The pages loaded.
  int loadedPages = 0;

  /// The pages of the list.
  int totalPages = 1;

  /// The first page is loading.
  bool loading = false;

  /// The next page is loading.
  bool loadingMore = false;

  /// The next page failed.
  bool moreFailed = false;

  /// Why the last load failed, null when it did not.
  LoadFailure? failure;

  bool _disposed = false;

  /// Counts the loads of the first page: an answer of an older load (a page of the order picked before, a next page
  /// asked before a refresh) is dropped.
  int _generation = 0;

  /// Whether a next page exists.
  bool get hasMore => loadedPages < totalPages;

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Load the first page again: the items loaded before stay until it came.
  Future<void> refresh() async {
    final generation = ++_generation;
    loading = true;
    // A next page asked before is of the list as it was: its answer is dropped.
    loadingMore = false;
    _notify();
    final result = await fetch(1).run();
    if (generation != _generation) {
      return;
    }
    loading = false;
    switch (result) {
      case Left(:final value):
        failure = LoadFailure.of(value);
      case Right(:final value):
        failure = null;
        first = value;
        items
          ..clear()
          ..addAll(itemsOf(value));
        loadedPages = 1;
        totalPages = pagesOf(value);
        moreFailed = false;
    }
    _notify();
  }

  /// Load the next page.
  Future<void> loadMore() async {
    if (loadingMore || loading || !hasMore) {
      return;
    }
    final generation = _generation;
    loadingMore = true;
    moreFailed = false;
    _notify();
    final result = await fetch(loadedPages + 1).run();
    if (generation != _generation) {
      return;
    }
    loadingMore = false;
    switch (result) {
      case Left(:final value):
        moreFailed = true;
        failure = LoadFailure.of(value);
      case Right(:final value):
        items.addAll(itemsOf(value));
        loadedPages += 1;
        totalPages = pagesOf(value);
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

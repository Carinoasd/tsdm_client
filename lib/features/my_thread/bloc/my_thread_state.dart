part of 'my_thread_bloc.dart';

/// Status of MyThread page.
enum MyThreadStatus {
  /// Initial.
  initial,

  /// This loading state only presents when first enter MyThread page.
  ///
  /// Means loading the initial data.
  ///
  /// After refresh and loading more pages will stay in success state.
  loading,

  /// Load succeed.
  success,

  /// Load failed.
  failed,
}

/// State of MyThread.
@MappableClass()
final class MyThreadState with MyThreadStateMappable {
  /// Constructor.
  const MyThreadState({
    this.status = MyThreadStatus.initial,
    this.threadList = const [],
    this.threadPageNumber = 1,
    this.nextThreadPageUrl,
    this.refreshingThread = false,
    this.replyList = const [],
    this.replyPageNumber = 1,
    this.nextReplyPageUrl,
    this.refreshingReply = false,
    this.threadFailed = false,
    this.threadLoadMoreFailed = false,
    this.replyFailed = false,
    this.replyLoadMoreFailed = false,
  });

  /// Status.
  final MyThreadStatus status;

  /// List of [MyThread] contains threads in thread tab.
  final List<MyThread> threadList;

  /// Current page number of thread tab page.
  final int threadPageNumber;

  /// The url to fetch next thread page.
  final String? nextThreadPageUrl;

  /// Flag indicates refreshing thread tab.
  final bool refreshingThread;

  /// List of [MyThread] contains replies in reply tab.
  final List<MyThread> replyList;

  /// CUrrent page number of reply tab page.
  final int replyPageNumber;

  /// The url to fetch next reply page.
  final String? nextReplyPageUrl;

  /// Flag indicates refreshing reply tab.
  final bool refreshingReply;

  /// Loading the thread tab (its first page) failed last time: an empty tab offers the retry instead of "no data".
  final bool threadFailed;

  /// Loading the next page of the thread tab failed last time: the threads loaded before stay, the end of the list
  /// offers the retry.
  final bool threadLoadMoreFailed;

  /// Loading the reply tab (its first page) failed last time, see [threadFailed].
  final bool replyFailed;

  /// Loading the next page of the reply tab failed last time, see [threadLoadMoreFailed].
  final bool replyLoadMoreFailed;
}

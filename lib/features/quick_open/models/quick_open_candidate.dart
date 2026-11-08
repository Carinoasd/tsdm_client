import 'package:tsdm_client/extensions/string.dart';

/// What a candidate of the quick open box is.
enum QuickOpenKind {
  /// A thread typed as its id or its link.
  typedThread,

  /// Any other page of the forum typed as its link.
  typedLink,

  /// A forum of the forum index.
  forum,

  /// A thread visited recently.
  thread,

  /// A user (a friend or somebody mentioned recently).
  user,

  /// The search page with what was typed.
  search,
}

/// One line of the quick open box: [title] to show and where [route] goes.
final class QuickOpenCandidate {
  /// Constructor.
  const QuickOpenCandidate(this.kind, this.title, this.route);

  /// What it is.
  final QuickOpenKind kind;

  /// The text shown.
  final String title;

  /// The page it opens.
  final RecognizedRoute route;
}

/// A forum the box can jump to.
typedef QuickOpenForum = ({int fid, String name});

/// A thread visited recently, newest first in the list holding it.
typedef QuickOpenThread = ({int tid, String title});

/// A user the box can jump to.
typedef QuickOpenUser = ({String uid, String name});

/// Everything the box matches the typed text against.
final class QuickOpenSources {
  /// Constructor.
  const QuickOpenSources({this.forums = const [], this.threads = const [], this.users = const []});

  /// Forums of the local forum index.
  final List<QuickOpenForum> forums;

  /// Threads visited recently, newest first.
  final List<QuickOpenThread> threads;

  /// Friends and users mentioned recently.
  final List<QuickOpenUser> users;
}

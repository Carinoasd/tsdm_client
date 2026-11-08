import 'package:flutter/widgets.dart';

/// Opens the search page.
class OpenSearchIntent extends Intent {
  /// Constructor.
  const OpenSearchIntent();
}

/// Opens the quick open box.
class OpenQuickOpenIntent extends Intent {
  /// Constructor.
  const OpenQuickOpenIntent();
}

/// Opens the settings page.
class OpenSettingsIntent extends Intent {
  /// Constructor.
  const OpenSettingsIntent();
}

/// Reloads the page in view.
class RefreshPageIntent extends Intent {
  /// Constructor.
  const RefreshPageIntent();
}

/// Moves to the next item (a floor, a thread of a list).
class NextItemIntent extends Intent {
  /// Constructor.
  const NextItemIntent();
}

/// Moves to the previous item (a floor, a thread of a list).
class PreviousItemIntent extends Intent {
  /// Constructor.
  const PreviousItemIntent();
}

/// Opens the item moved to.
class OpenItemIntent extends Intent {
  /// Constructor.
  const OpenItemIntent();
}

/// Goes to the next page of a paged list.
class NextPageIntent extends Intent {
  /// Constructor.
  const NextPageIntent();
}

/// Goes to the previous page of a paged list.
class PreviousPageIntent extends Intent {
  /// Constructor.
  const PreviousPageIntent();
}

/// Starts a reply.
class StartReplyIntent extends Intent {
  /// Constructor.
  const StartReplyIntent();
}

/// Scrolls to the start of the page.
class ScrollToStartIntent extends Intent {
  /// Constructor.
  const ScrollToStartIntent();
}

/// Scrolls to the end of the page.
class ScrollToEndIntent extends Intent {
  /// Constructor.
  const ScrollToEndIntent();
}

/// Copies the link of the page.
class CopyPageLinkIntent extends Intent {
  /// Constructor.
  const CopyPageLinkIntent();
}

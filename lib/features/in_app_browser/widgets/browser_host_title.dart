import 'package:flutter/widgets.dart';

/// The host of the page in the title bar of the in-app browser, on one line: a host too long for the bar loses its
/// start, never its end (`…aaaa.evil.example`), as an address bar does: the end is the domain the page is on, the start
/// can be anything (`www.tsdm39.com.aaaa…`).
class BrowserHostTitle extends StatelessWidget {
  /// Constructor.
  const BrowserHostTitle(this.text, {super.key});

  /// What to show, `browserTitleOf` the page.
  final String text;

  @override
  Widget build(BuildContext context) {
    // Measured as drawn: `Text` makes it bold when the system asks for bold text.
    var style = DefaultTextStyle.of(context).style;
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => Text(
        tailFitting(text, style, constraints.maxWidth, direction, scaler),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
    );
  }
}

/// [text] as it fits in [maxWidth] on one line in [style]: whole when it fits, else its longest end after `…`.
@visibleForTesting
String tailFitting(String text, TextStyle style, double maxWidth, TextDirection direction, TextScaler scaler) {
  bool fits(String s) {
    final painter = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width <= maxWidth;
  }

  if (!maxWidth.isFinite || fits(text)) {
    return text;
  }
  // The first index from which the rest fits after the ellipsis.
  var lo = 1;
  var hi = text.length;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (fits('…${text.substring(mid)}')) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return '…${text.substring(lo)}';
}

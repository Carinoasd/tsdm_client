import 'package:flutter/material.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/munch_options.dart';
import 'package:universal_html/parsing.dart';

/// [munchElement] run once per piece of html and kept across rebuilds.
///
/// Parsing a post and turning it into spans is the most expensive thing a card does. Done straight in `build`, it ran
/// again on every rebuild of the page: a badge update or the keyboard coming up re-munched every floor kept alive on
/// the thread page, which is where most of the dropped frames came from. Here the result is kept and only rebuilt when
/// the html changes or something the spans were built from changes: the theme, the text scale or the locale.
class MunchedHtml extends StatefulWidget {
  /// Constructor.
  const MunchedHtml(this.html, {this.options = const MunchOptions(), this.parseLockedWithPurchase = false, super.key});

  /// The html to render.
  final String html;

  /// Passed to [munchElement]. Its callbacks are taken from the first build and kept with the spans, so they must read
  /// live state through the caller's `State` rather than through values captured when they were created.
  final MunchOptions options;

  /// Passed to [munchElement].
  final bool parseLockedWithPurchase;

  @override
  State<MunchedHtml> createState() => _MunchedHtmlState();
}

class _MunchedHtmlState extends State<MunchedHtml> {
  Widget? _content;
  ThemeData? _theme;
  TextScaler? _textScaler;
  Locale? _locale;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reading these registers the dependencies, so a change lands here again and drops the kept spans.
    final theme = Theme.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    if (theme != _theme || textScaler != _textScaler || locale != _locale) {
      _theme = theme;
      _textScaler = textScaler;
      _locale = locale;
      _content = null;
    }
  }

  @override
  void didUpdateWidget(MunchedHtml oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html || oldWidget.parseLockedWithPurchase != widget.parseLockedWithPurchase) {
      _content = null;
    }
  }

  @override
  Widget build(BuildContext context) => _content ??= munchElement(
    context,
    parseHtmlDocument(widget.html).body!,
    options: widget.options,
    parseLockedWithPurchase: widget.parseLockedWithPurchase,
  );
}

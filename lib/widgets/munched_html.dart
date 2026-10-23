import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/munch_options.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:universal_html/parsing.dart';

/// [munchElement] run once per piece of html and kept across rebuilds.
///
/// Parsing a post and turning it into spans is the most expensive thing a card does. Done straight in `build`, it ran
/// again on every rebuild of the page: a badge update or the keyboard coming up re-munched every floor on the thread
/// page, which is where most of the dropped frames came from. Here the result is kept and only rebuilt when the html
/// changes or something the spans were built from changes: the theme, the text scale, the locale or the
/// [PostTypography] of a post's content (and whether it is one, [PostTypographyScope.postContent]).
///
/// Under a [MunchCacheScope] (the thread page) the result is kept in its [MunchCache] instead, so a floor scrolled
/// away (its card is not kept alive) and built again later takes it back rather than munching its html again.
class MunchedHtml extends StatefulWidget {
  /// Constructor.
  const MunchedHtml(this.html, {this.options = const MunchOptions(), this.parseLockedWithPurchase = false, super.key});

  /// The html to render.
  final String html;

  /// Passed to [munchElement]. Its callbacks are taken from the first build and kept with the spans, so they must read
  /// live state through the caller's `State` rather than through values captured when they were created. Only the
  /// default options (no callback) go to a [MunchCache].
  final MunchOptions options;

  /// Passed to [munchElement].
  final bool parseLockedWithPurchase;

  @override
  State<MunchedHtml> createState() => _MunchedHtmlState();
}

class _MunchedHtmlState extends State<MunchedHtml> {
  Widget? _content;
  _MunchDeps? _deps;
  MunchCache? _cache;

  /// The cached content in use here, see [MunchCache].
  _MunchEntry? _entry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reading these registers the dependencies, so a change lands here again and drops the kept spans.
    final deps = _MunchDeps(
      theme: Theme.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      typography: PostTypographyScope.maybeOf(context),
      postContent: PostTypographyScope.isPostContent(context),
    );
    final cache = MunchCacheScope.maybeOf(context);
    if (deps != _deps || cache != _cache) {
      _deps = deps;
      _cache = cache;
      _drop();
    }
  }

  @override
  void didUpdateWidget(MunchedHtml oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html || oldWidget.parseLockedWithPurchase != widget.parseLockedWithPurchase) {
      _drop();
    }
  }

  @override
  void dispose() {
    _drop();
    super.dispose();
  }

  /// Forget the content: built again on the next build.
  void _drop() {
    _content = null;
    _entry?.release(context as Element);
    _entry = null;
  }

  Widget _munch(BuildContext context) => ClipRect(
    clipper: const PostContentClipper(),
    child: munchElement(
      context,
      parseHtmlDocument(widget.html).body!,
      options: widget.options,
      parseLockedWithPurchase: widget.parseLockedWithPurchase,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_content case final content?) {
      return content;
    }
    final cache = _cache;
    final deps = _deps;
    // Callbacks of other options belong to the widget that gave them: not shared.
    if (cache == null || deps == null || !identical(widget.options, const MunchOptions())) {
      return _content = _munch(context);
    }
    final element = context as Element;
    final key = '${widget.parseLockedWithPurchase ? 1 : 0}:${widget.html}';
    final entry = cache._adopt(key, deps, element) ?? cache._put(key, deps, element, _munch);
    _entry = entry;
    return _content = entry.content;
  }
}

/// What munched content is built from besides its html: kept content of other ones is munched again.
@immutable
final class _MunchDeps {
  const _MunchDeps({
    required this.theme,
    required this.textScaler,
    required this.locale,
    required this.typography,
    required this.postContent,
  });

  final ThemeData theme;
  final TextScaler textScaler;
  final Locale? locale;
  final PostTypography? typography;
  final bool postContent;

  @override
  bool operator ==(Object other) =>
      other is _MunchDeps &&
      other.theme == theme &&
      other.textScaler == textScaler &&
      other.locale == locale &&
      other.typography == typography &&
      other.postContent == postContent;

  @override
  int get hashCode => Object.hash(theme, textScaler, locale, typography, postContent);
}

/// Munched contents kept for one page that shows many of them (the thread page): the content of a floor built again
/// (scrolled back to, its card was not kept alive) is taken from here instead of munching its html again.
///
/// At most [capacity] contents, the least recently used one dropped first; everything goes with the page.
///
/// A content is used by one widget at a time. Its spans call back into the page (a link opened, an image tapped)
/// through the context they were munched with, which is the one of the widget using them now: taken by another
/// widget once the first one is gone, they act from there.
final class MunchCache {
  /// Constructor.
  MunchCache({this.capacity = 64});

  /// Contents kept at most.
  final int capacity;

  /// Least recently used first (a map literal keeps the insertion order).
  final _entries = <String, _MunchEntry>{};

  /// Contents kept now.
  int get length => _entries.length;

  /// Forget every content kept (those in use stay with their widgets).
  void clear() => _entries.clear();

  /// What a floor's widget left of itself (a vote chosen and not sent yet), by key: floors are not kept alive, one
  /// built again takes it back from here. At most [_memoryCapacity] values, the oldest dropped first.
  final _memory = <String, Object>{};
  static const _memoryCapacity = 256;

  /// The value remembered for [key], null when none.
  Object? recall(String key) => _memory[key];

  /// Remember [value] for [key]; null forgets it.
  void remember(String key, Object? value) {
    _memory.remove(key);
    if (value == null) {
      return;
    }
    _memory[key] = value;
    while (_memory.length > _memoryCapacity) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// The content kept for [key] built from [deps], now used by [owner]; null when there is none, or it is in use by
  /// another widget still mounted (that one keeps it, [owner] munches its own).
  _MunchEntry? _adopt(String key, _MunchDeps deps, Element owner) {
    final entry = _entries[key];
    if (entry == null) {
      return null;
    }
    if (entry.deps != deps) {
      _entries.remove(key);
      return null;
    }
    final current = entry.owner;
    if (current != null && current != owner && current.mounted) {
      return null;
    }
    // Most recently used: last.
    _entries
      ..remove(key)
      ..[key] = entry;
    entry.adopt(owner);
    return entry;
  }

  _MunchEntry _put(String key, _MunchDeps deps, Element owner, Widget Function(BuildContext context) munch) {
    final host = _HostContext(owner);
    final entry = _MunchEntry(content: munch(host), deps: deps, host: host)..owner = owner;
    if (_entries.containsKey(key)) {
      // In use by another widget: that one keeps its own, this one is kept from now on.
      _entries.remove(key);
    }
    _entries[key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    return entry;
  }
}

final class _MunchEntry {
  _MunchEntry({required this.content, required this.deps, required this.host});

  final Widget content;
  final _MunchDeps deps;
  final _HostContext host;

  /// The widget using [content] now, null while none.
  Element? owner;

  void adopt(Element element) {
    owner = element;
    host.target = element;
  }

  /// [element] no longer uses [content].
  void release(Element element) {
    if (owner != element) {
      return;
    }
    owner = null;
    // Not kept alive through the spans (gone with its card).
    host.target = null;
  }
}

/// Makes [MunchCache] [cache] the one of the munched contents below (the thread page's).
class MunchCacheScope extends InheritedWidget {
  /// Constructor.
  const MunchCacheScope({required this.cache, required super.child, super.key});

  /// The contents kept.
  final MunchCache cache;

  /// The cache above [context], null when none.
  static MunchCache? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MunchCacheScope>()?.cache;

  /// The cache above [context] without depending on it (from `initState`), null when none.
  static MunchCache? find(BuildContext context) => context.getInheritedWidgetOfExactType<MunchCacheScope>()?.cache;

  @override
  bool updateShouldNotify(MunchCacheScope oldWidget) => !identical(cache, oldWidget.cache);
}

/// The context munched content calls back into: the one of the widget using the content now ([target]), so content
/// kept in a [MunchCache] and shown again by another widget acts from that one.
final class _HostContext implements BuildContext {
  _HostContext(this.target);

  /// The widget using the content now.
  Element? target;

  Element get _target {
    final element = target;
    if (element == null) {
      throw FlutterError('Munched content used while no widget shows it.');
    }
    return element;
  }

  @override
  Widget get widget => _target.widget;

  @override
  BuildOwner? get owner => _target.owner;

  @override
  bool get mounted => target?.mounted ?? false;

  @override
  bool get debugDoingBuild => _target.debugDoingBuild;

  @override
  RenderObject? findRenderObject() => _target.findRenderObject();

  @override
  Size? get size => _target.size;

  @override
  InheritedWidget dependOnInheritedElement(InheritedElement ancestor, {Object? aspect}) =>
      _target.dependOnInheritedElement(ancestor, aspect: aspect);

  @override
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>({Object? aspect}) =>
      _target.dependOnInheritedWidgetOfExactType<T>(aspect: aspect);

  @override
  T? getInheritedWidgetOfExactType<T extends InheritedWidget>() => _target.getInheritedWidgetOfExactType<T>();

  @override
  InheritedElement? getElementForInheritedWidgetOfExactType<T extends InheritedWidget>() =>
      _target.getElementForInheritedWidgetOfExactType<T>();

  @override
  T? findAncestorWidgetOfExactType<T extends Widget>() => _target.findAncestorWidgetOfExactType<T>();

  @override
  T? findAncestorStateOfType<T extends State<StatefulWidget>>() => _target.findAncestorStateOfType<T>();

  @override
  T? findRootAncestorStateOfType<T extends State<StatefulWidget>>() => _target.findRootAncestorStateOfType<T>();

  @override
  T? findAncestorRenderObjectOfType<T extends RenderObject>() => _target.findAncestorRenderObjectOfType<T>();

  @override
  void visitAncestorElements(ConditionalElementVisitor visitor) => _target.visitAncestorElements(visitor);

  @override
  void visitChildElements(ElementVisitor visitor) => _target.visitChildElements(visitor);

  @override
  void dispatchNotification(Notification notification) => _target.dispatchNotification(notification);

  @override
  DiagnosticsNode describeElement(String name, {DiagnosticsTreeStyle style = DiagnosticsTreeStyle.errorProperty}) =>
      _target.describeElement(name, style: style);

  @override
  DiagnosticsNode describeWidget(String name, {DiagnosticsTreeStyle style = DiagnosticsTreeStyle.errorProperty}) =>
      _target.describeWidget(name, style: style);

  @override
  List<DiagnosticsNode> describeMissingAncestor({required Type expectedAncestorType}) =>
      _target.describeMissingAncestor(expectedAncestorType: expectedAncestorType);

  @override
  DiagnosticsNode describeOwnershipChain(String name) => _target.describeOwnershipChain(name);
}

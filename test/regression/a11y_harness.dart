/// The pages of the app under its providers, for the accessibility tests (test_279, test_990, test_991): a synthetic
/// account and forum, nothing leaves the test.
///
/// Every page is taken down by [A11yHarness.finish] inside the test, with an end condition for each step: the blocs,
/// the repositories and the database of the test are closed while the fake clock and the real one both still run,
/// and a close that does not end fails the test naming it. Closing them after the test instead (in a `tearDown`)
/// waited forever when a close needed a timer or a microtask of the test's fake zone, which nobody runs any more once
/// the test is over (test_279 timed out after ten minutes on CI that way).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show CheckedState, Tristate;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';

/// The account of the tests.
const a11yAlice = UserLoginInfo(username: 'Alice', uid: 1000);

/// A phone, 1.0 scale.
const a11yPhone = Size(390, 844);

/// The fixture [name] under `test/data`.
String a11yData(String name) => File('test/data/$name').readAsStringSync();

/// A 1x1 PNG.
final Uint8List a11yPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// What the forum answers to [uri] ([method]): the body and whether it is JSON; null for an empty page.
typedef A11yAnswer = (String, bool)? Function(Uri uri, String method);

/// The forum: [answer] first, then [fallback]; an empty page otherwise. Nothing leaves the test.
final class A11yForum implements HttpClientAdapter {
  A11yForum(this.answer, this.fallback);

  /// The answers of the test.
  A11yAnswer? answer;

  /// The answers of the file.
  final A11yAnswer? fallback;

  /// What was asked.
  final asked = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    asked.add(options.uri);
    final (body, json) =
        answer?.call(options.uri, options.method) ??
        fallback?.call(options.uri, options.method) ??
        ('<html><body></body></html>', false);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [
          if (json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers a PNG for every image request.
final class A11yImages implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    a11yPng,
    200,
    headers: {
      Headers.contentTypeHeader: ['image/png'],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// Notification bloc with a fixed state; events are dropped.
final class A11yNotifications extends Fake implements NotificationBloc {
  A11yNotifications(this.state);

  @override
  final NotificationState state;

  @override
  void add(NotificationEvent event) {}

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// The notices, messages and broadcasts of the notification page.
final a11yNotificationState = NotificationState(
  status: NotificationStatus.success,
  ownerUid: a11yAlice.uid,
  noticeList: const [
    NoticeV2(id: 1, timestamp: 1788000001, data: 'unread notice one'),
    NoticeV2(id: 2, timestamp: 1788000002, data: 'read notice two', alreadyRead: true),
    NoticeV2(id: 3, timestamp: 1788000006, data: 'a notice from Carol', authorId: 1003, author: 'Carol'),
  ],
  personalMessageList: const [
    PersonalMessageV2(
      timestamp: 1788000003,
      data: 'a message from Bob',
      peerUid: 1001,
      peerUsername: 'Bob',
      sender: false,
      alreadyRead: false,
    ),
    PersonalMessageV2(
      timestamp: 1788000004,
      data: 'a message to Carol',
      peerUid: 1003,
      peerUsername: 'Carol',
      sender: true,
      alreadyRead: true,
    ),
  ],
  broadcastMessageList: const [
    BroadcastMessageV2(timestamp: 1788000005, data: 'a broadcast of the forum', pmid: 7),
  ],
);

final class _FakeContext extends Fake implements BuildContext {}

/// The theme of the app, light or [dark].
ThemeData a11yTheme({required bool dark}) => dark
    ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: '')
    : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: '');

/// Let the requests (real futures) and the frames they cause finish: [rounds] times a moment of real time, then a
/// frame 50 ms later. A fixed number of rounds, nothing waits for an animation to end.
Future<void> a11ySettle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Settle until [done], at most [rounds] rounds: fails naming [what] when it is not by then.
Future<void> a11ySettleUntil(WidgetTester tester, bool Function() done, String what, {int rounds = 40}) async {
  for (var i = 0; i < rounds && !done(); i++) {
    await a11ySettle(tester, rounds: 1);
  }
  if (!done()) {
    fail('$what: not after $rounds rounds');
  }
}

/// Drive [future] (started in the test) to its end on both clocks, at most [rounds] rounds; fails naming [what] when
/// it does not end.
Future<void> a11yDrive(WidgetTester tester, Future<void> future, String what, {int rounds = 200}) async {
  var done = false;
  Object? error;
  StackTrace? stack;
  unawaited(
    future.then(
      (_) => done = true,
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      },
    ),
  );
  for (var i = 0; i < rounds && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (!done) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
  }
  if (error != null) {
    Error.throwWithStackTrace(error!, stack!);
  }
  if (!done) {
    fail('$what did not end after $rounds rounds');
  }
}

/// The global rect of [node]: its own, through the transforms up to the root.
Rect a11yGlobalRect(SemanticsNode node) {
  var rect = node.rect;
  SemanticsNode? current = node;
  while (current != null) {
    final transform = current.transform;
    if (transform != null) {
      rect = MatrixUtils.transformRect(transform, rect);
    }
    current = current.parent;
  }
  return rect;
}

/// Whether [node] lies within one of the [exempt] rects (a hair of tolerance for the pixel snapping).
bool _isExempt(SemanticsNode node, List<Rect> exempt) {
  final rect = a11yGlobalRect(node);
  return exempt.any((e) => e.inflate(0.5).contains(rect.topLeft) && e.inflate(0.5).contains(rect.bottomRight));
}

/// The rects of what the [finders] find on screen.
List<Rect> a11yRectsOf(WidgetTester tester, List<Finder> finders) => [
  for (final finder in finders)
    for (final element in finder.evaluate())
      if (element.renderObject case final RenderBox box when box.hasSize && box.attached)
        MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size),
];

/// [androidTapTargetGuideline] (48x48) leaving out the nodes within [exempt].
final class A11yTapTargets extends MinimumTapTargetGuideline {
  const A11yTapTargets(this.exempt)
    : super(size: const Size(48, 48), link: 'https://support.google.com/accessibility/android/answer/7101858');

  final List<Rect> exempt;

  @override
  bool shouldSkipNode(SemanticsNode node) => super.shouldSkipNode(node) || _isExempt(node, exempt);
}

/// [iOSTapTargetGuideline] (44x44) leaving out the nodes within [exempt].
final class A11yIosTapTargets extends MinimumTapTargetGuideline {
  const A11yIosTapTargets(this.exempt)
    : super(
        size: const Size(44, 44),
        link: 'https://developer.apple.com/design/human-interface-guidelines/ios/visual-design/adaptivity-and-layout/',
      );

  final List<Rect> exempt;

  @override
  bool shouldSkipNode(SemanticsNode node) => super.shouldSkipNode(node) || _isExempt(node, exempt);
}

/// [textContrastGuideline] leaving out the text under one of the [exempt] rects: covered, not low in contrast.
final class A11yContrast extends MinimumTextContrastGuideline {
  A11yContrast(this.exempt);

  final List<Rect> exempt;

  /// Labels of the text nodes under an exempt rect, collected before the evaluation (the nodes it asks about carry
  /// no transform to the root).
  final _covered = <String>{};

  void _collect(SemanticsNode node) {
    node.visitChildren((child) {
      _collect(child);
      return true;
    });
    final rect = a11yGlobalRect(node);
    if (exempt.any((e) => e.overlaps(rect))) {
      final data = node.getSemanticsData();
      _covered.add(data.label.isEmpty ? data.value : data.label);
    }
  }

  @override
  Future<Evaluation> evaluate(WidgetTester tester) {
    _covered.clear();
    for (final view in tester.binding.renderViews) {
      _collect(view.owner!.semanticsOwner!.rootSemanticsNode!);
    }
    return super.evaluate(tester);
  }

  @override
  bool shouldSkipNode(SemanticsData data) =>
      super.shouldSkipNode(data) || _covered.contains(data.label.isEmpty ? data.value : data.label);
}

/// [labeledTapTargetGuideline] (whose constructor is private) leaving out the nodes within [exempt].
final class A11yLabeledTargets extends AccessibilityGuideline {
  const A11yLabeledTargets(this.exempt);

  final List<Rect> exempt;

  @override
  String get description => 'Tappable widgets should have a semantic label';

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) {
    var result = const Evaluation.pass();
    for (final view in tester.binding.renderViews) {
      result += _traverse(view.owner!.semanticsOwner!.rootSemanticsNode!);
    }
    return result;
  }

  Evaluation _traverse(SemanticsNode node) {
    var result = const Evaluation.pass();
    node.visitChildren((child) {
      result += _traverse(child);
      return true;
    });
    if (node.isMergedIntoParent ||
        node.isInvisible ||
        node.flagsCollection.isHidden ||
        node.flagsCollection.isTextField ||
        _isExempt(node, exempt)) {
      return result;
    }
    final data = node.getSemanticsData();
    if (!data.hasAction(SemanticsAction.longPress) && !data.hasAction(SemanticsAction.tap)) {
      return result;
    }
    if (data.label.isEmpty && data.tooltip.isEmpty) {
      result += Evaluation.fail('$node: expected tappable node to have semantic label, but none was found.');
    }
    return result;
  }
}

/// Everything that takes a tap says what it is to a screen reader: a button, a link, a text field, a check box, a
/// switch, a slider, a tab ...: a custom tappable ([GestureDetector], [InkWell]) without such a role is read as text
/// that happens to take a tap. The nodes within [exempt] are left out.
final class A11yTapRoles extends AccessibilityGuideline {
  const A11yTapRoles(this.exempt);

  final List<Rect> exempt;

  @override
  String get description => 'Tappable widgets should say what they are';

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) {
    var result = const Evaluation.pass();
    for (final view in tester.binding.renderViews) {
      result += _traverse(view.owner!.semanticsOwner!.rootSemanticsNode!);
    }
    return result;
  }

  Evaluation _traverse(SemanticsNode node) {
    var result = const Evaluation.pass();
    node.visitChildren((child) {
      result += _traverse(child);
      return true;
    });
    if (node.isMergedIntoParent || node.isInvisible || node.flagsCollection.isHidden || _isExempt(node, exempt)) {
      return result;
    }
    final data = node.getSemanticsData();
    // The barrier of a menu or a dialog: closing it is its tap, the framework names it.
    if (!data.hasAction(SemanticsAction.tap) || data.hasAction(SemanticsAction.dismiss)) {
      return result;
    }
    final flags = data.flagsCollection;
    final hasRole =
        flags.isButton ||
        flags.isLink ||
        flags.isTextField ||
        flags.isSlider ||
        flags.isChecked != CheckedState.none ||
        flags.isToggled != Tristate.none ||
        flags.isSelected != Tristate.none ||
        flags.isExpanded != Tristate.none ||
        data.role != SemanticsRole.none;
    if (!hasRole) {
      result += Evaluation.fail('$node: a tappable node that is not a button, a link or another control.');
    }
    return result;
  }
}

/// The text nodes of the semantics tree on screen, in the order a screen reader reads them.
List<String> a11yReadingOrder(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    final text = [data.label, data.value, data.tooltip].where((e) => e.isNotEmpty).join(' ');
    if (!node.isMergedIntoParent && text.isNotEmpty) {
      labels.add(text);
    }
    node.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder).forEach(visit);
  }

  tester.binding.renderViews.map((view) => view.owner!.semanticsOwner!.rootSemanticsNode!).forEach(visit);
  return labels;
}

/// The overflows and the other errors of the layout reported while [body] ran.
Future<List<FlutterErrorDetails>> a11yLayoutErrors(Future<void> Function() body) async {
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

/// The texts on screen that are cut: a [RenderParagraph] that did not fit its box (an ellipsis or a fade is no cut,
/// [TextOverflow.clip] and [TextOverflow.visible] are) or that lies outside the screen without a scrollable around
/// it to bring it in.
List<String> a11yClippedTexts(WidgetTester tester) {
  final cut = <String>[];
  final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  void visit(RenderObject object) {
    if (object is RenderParagraph && object.hasSize && object.attached) {
      final text = object.text.toPlainText();
      final clips = object.overflow == TextOverflow.clip || object.overflow == TextOverflow.visible;
      if (text.trim().isNotEmpty && clips && (object.didExceedMaxLines || object.debugHasOverflowShader)) {
        cut.add(text);
      }
      final rect = MatrixUtils.transformRect(object.getTransformTo(null), Offset.zero & object.size);
      final scrolls = _inScrollable(object);
      if (text.trim().isNotEmpty && !scrolls && rect.width > 0 && rect.height > 0) {
        if (rect.right > screen.right + 1 || rect.left < screen.left - 1) {
          cut.add('$text (off the screen: $rect)');
        }
      }
    }
    object.visitChildren(visit);
  }

  tester.binding.renderViews.forEach(visit);
  return cut;
}

bool _inScrollable(RenderObject object) {
  var current = object.parent;
  while (current != null) {
    if (current is RenderAbstractViewport || current is RenderSliver) {
      return true;
    }
    current = current.parent;
  }
  return false;
}

/// One test of the accessibility files: two minutes at most, so a hang fails at once instead of after ten minutes.
void a11yTest(String description, WidgetTesterCallback body) =>
    testWidgets(description, body, timeout: const Timeout(Duration(minutes: 2)));

/// The account, the forum and the providers of the app for the pages of a test file; [install] in its `main`.
final class A11yHarness {
  A11yHarness({this.fallback});

  /// The answers of the forum shared by the tests of the file.
  final A11yAnswer? fallback;

  late Directory _tmp;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late AuthenticationRepository auth;
  late NotificationInfoRepository info;
  late NotificationStateCubit counts;
  late A11yForum forum;

  /// What is closed by [finish], in order: the objects of the page first, the database last.
  final _closers = <(String, Future<void> Function())>[];

  /// The test closed what it opened ([finish]).
  bool _finished = false;

  /// Register the set up and the tear down of the tests.
  void install() {
    setUpAll(() async {
      talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
      await LocaleSettings.setLocale(AppLocale.zhCn);
      _tmp = Directory.systemTemp.createTempSync('tsdm_a11y_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${_tmp.path}/cache',
          'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${_tmp.path}/support',
          'getTemporaryPath' || 'getTemporaryDirectory' => '${_tmp.path}/tmp',
          'getApplicationDocumentsPath' || 'getApplicationDocumentsDirectory' => '${_tmp.path}/docs',
          'getDownloadsDirectory' => '${_tmp.path}/downloads',
          _ => null,
        },
      );
      await initCache();
    });

    tearDownAll(() => _tmp.delete(recursive: true));

    setUp(() async {
      _finished = false;
      _closers.clear();
      TsdmAppApi.reset();
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      forum = A11yForum(null, fallback);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        )
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = A11yImages()),
          instanceName: ServiceKeys.noCookie,
        )
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = A11yImages())),
        );
      await settings.init();
      await settings.setValue(SettingsKeys.loginUsername, a11yAlice.username!);
      await settings.setValue(SettingsKeys.loginUid, a11yAlice.uid!);
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      auth = AuthenticationRepository(user: a11yAlice);
      info = NotificationInfoRepository();
      counts = NotificationStateCubit(info);
      ThreadAuthorCache.clear();
    });

    tearDown(() async {
      if (!_finished) {
        // The test failed before it closed what it opened: close what can be, bounded, its failure is the one told.
        for (final (_, close) in _closers.reversed) {
          await close().timeout(const Duration(seconds: 2), onTimeout: () {}).catchError((Object _) {});
        }
      }
      _closers.clear();
      await getIt.reset();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });
  }

  /// Close [close] (named [name]) in [finish], before what was registered earlier.
  void closeLater(String name, Future<void> Function() close) => _closers.add((name, close));

  /// [home] at `/` (or [initialLocation]) under the providers of the app, with [routes] beside it, in the light or the
  /// [dark] theme, on a window of [size] with the text scaled by [textScale]; the forum answers [answer] first.
  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    required bool dark,
    List<RouteBase> routes = const [],
    Size size = a11yPhone,
    double textScale = 1,
    A11yAnswer? answer,
    String? initialLocation,
    List<RepositoryProvider<Object>> repositories = const [],
    List<BlocProvider> blocs = const [],
    int settleRounds = 8,
  }) async {
    forum.answer = answer;
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    // The objects of the set up, closed last (the closers run in reverse).
    closeLater('database', db.close);
    closeLater('settings', settings.dispose);
    closeLater('image cache', () => getIt.get<ImageCacheProvider>().dispose());
    closeLater('auth', auth.dispose);
    closeLater('blocks', blocks.dispose);
    closeLater('settings bloc', settingsBloc.close);
    closeLater('counts', counts.close);
    closeLater('info', info.dispose);

    final blockCubit = UserBlockCubit(
      repository: blocks,
      currentUid: () => a11yAlice.uid,
      authStatus: auth.status,
      retryDelays: const [],
    );
    final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
    final homeCubit = HomeCubit();
    final checkin = CheckinBloc(
      checkinRepository: CheckinRepository(storageProvider: storage),
      authenticationRepository: auth,
      settingsRepository: settings,
    );
    final forumHome = ForumHomeRepository();
    final theme = ThemeCubit();
    final status = StreamController<AuthStatus>.broadcast(sync: true);
    final titles = CurrentTitleCubit(
      currentUid: () => a11yAlice.uid,
      authStatus: status.stream,
      fetchTitles: () => TaskEither.right(const []),
    );
    final notices = NotificationRepository(storageProvider: storage);
    final auto = AutoNotificationCubit(
      authenticationRepository: auth,
      notificationRepository: notices,
      storageProvider: storage,
    );
    final router = GoRouter(
      initialLocation: initialLocation ?? '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        ...routes,
      ],
    );
    closeLater('notices', notices.dispose);
    closeLater('auto notification', auto.close);
    closeLater('auth status', status.close);
    closeLater('titles', titles.close);
    closeLater('theme', theme.close);
    closeLater('forum home', forumHome.dispose);
    closeLater('checkin', checkin.close);
    closeLater('home', homeCubit.close);
    closeLater('history', history.close);
    closeLater('block cubit', blockCubit.close);
    closeLater('router', () async => router.dispose());

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<NotificationInfoRepository>.value(value: info),
            RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
            RepositoryProvider<ProfileRepository>(create: (_) => ProfileRepository()),
            RepositoryProvider<ForumRepository>(create: (_) => ForumRepository()),
            RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
            RepositoryProvider<StorageProvider>.value(value: storage),
            RepositoryProvider<SettingsRepository>.value(value: settings),
            ...repositories,
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: blockCubit),
              BlocProvider<NotificationBloc>.value(value: A11yNotifications(a11yNotificationState)),
              BlocProvider<NotificationStateCubit>.value(value: counts),
              BlocProvider<AutoNotificationCubit>.value(value: auto),
              BlocProvider<HomeCubit>.value(value: homeCubit),
              BlocProvider<CheckinBloc>.value(value: checkin),
              BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
              BlocProvider<ThemeCubit>.value(value: theme),
              BlocProvider<CurrentTitleCubit>.value(value: titles),
              ...blocs,
            ],
            child: Builder(
              builder: (context) => MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: a11yTheme(dark: dark),
                routerConfig: router,
                scaffoldMessengerKey: snackbarKey,
                locale: TranslationProvider.of(context).flutterLocale,
                supportedLocales: AppLocaleUtils.supportedLocales,
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
              ),
            ),
          ),
        ),
      ),
    );
    await a11ySettle(tester, rounds: settleRounds);
  }

  /// Take the page down and close what the test opened, each with an end: the frames of the page down first (the
  /// timers of its indicators run out on the fake clock), then every bloc, repository and the database, driven on
  /// both clocks until each one has closed; one that does not fails the test naming it.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    await a11ySettle(tester, rounds: 2);
    while (_closers.isNotEmpty) {
      final (name, close) = _closers.removeLast();
      await a11yDrive(tester, close(), 'closing $name');
    }
    // What closing scheduled on the fake clock.
    await tester.pump(const Duration(seconds: 1));
    _finished = true;
  }

  /// The three guidelines on what is on screen: tap targets of 48 and of 44 ([tapTargetExempt] left out), labels on
  /// everything tappable ([labelExempt] left out), text contrast (the text under [covered] left out).
  Future<void> audit(
    WidgetTester tester, {
    List<Finder> tapTargetExempt = const [],
    List<Finder> labelExempt = const [],
    List<Finder> covered = const [],
    List<Finder> roleExempt = const [],
  }) async {
    final handle = tester.ensureSemantics();
    await tester.pump();
    final targets = a11yRectsOf(tester, tapTargetExempt);
    await expectLater(tester, meetsGuideline(A11yTapTargets(targets)));
    await expectLater(tester, meetsGuideline(A11yIosTapTargets(targets)));
    await expectLater(tester, meetsGuideline(A11yLabeledTargets(a11yRectsOf(tester, labelExempt))));
    await expectLater(tester, meetsGuideline(A11yContrast(a11yRectsOf(tester, covered))));
    await expectLater(tester, meetsGuideline(A11yTapRoles(a11yRectsOf(tester, roleExempt))));
    handle.dispose();
  }
}

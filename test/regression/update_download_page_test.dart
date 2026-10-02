import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/update/cubit/update_cubit.dart';
import 'package:tsdm_client/features/update/cubit/update_download_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/view/update_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/git_info.dart';

class _DownloadCubit extends UpdateDownloadCubit {
  _DownloadCubit({bool supported = true}) : super(supported: supported);

  final downloads = <LatestVersionInfo>[];
  int installs = 0;
  int settingsOpened = 0;
  int cancellations = 0;

  void show(UpdateDownloadState value) => emit(value);

  @override
  Future<void> download(LatestVersionInfo info) async {
    downloads.add(info);
    show(UpdateDownloadState(status: UpdateDownloadStatus.resolving, version: info.version));
  }

  @override
  Future<void> install() async {
    installs++;
  }

  @override
  Future<void> openPermissionSettings() async {
    settingsOpened++;
  }

  @override
  void cancel() {
    cancellations++;
    show(UpdateDownloadState(status: UpdateDownloadStatus.cancelled, version: state.version));
  }
}

const _newer = LatestVersionInfo(version: '99.0.0', versionCode: 999999, changelog: 'Release notes for testing');
const _launcher = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  late _DownloadCubit download;
  late UpdateCubit updates;
  final browserCalls = <MethodCall>[];

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    download = _DownloadCubit();
    updates = UpdateCubit(download: download);
    browserCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_launcher, (
      call,
    ) async {
      browserCalls.add(call);
      return true;
    });
  });

  tearDown(() async {
    await updates.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_launcher, null);
  });

  void checked(UpdateCubitState state) {
    // Drive the metadata response without a network request.
    updates.emit(state);
  }

  Future<void> pumpPage(WidgetTester tester, {bool visible = true, double scale = 1, double width = 800}) async {
    tester.view
      ..physicalSize = Size(width, 1200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider.value(
          value: updates,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: visible ? const UpdatePage() : const Scaffold(body: Text('Other page')),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('Android download is explicit, names its version, and precedes the changelog', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.updatePage;
    checked(const UpdateCubitState(latestVersionInfo: _newer));
    await pumpPage(tester);
    final action = find.text(tr.download.downloadApk(version: _newer.version));
    expect(action, findsOneWidget);
    expect(find.text(tr.download.universalApk), findsOneWidget);
    expect(tester.getTopLeft(action).dy, lessThan(tester.getTopLeft(find.text(tr.availableDialog.changelog)).dy));
    expect(download.downloads, isEmpty);
    expect(download.installs, 0);
    expect(browserCalls, isEmpty);

    await tester.tap(action);
    await tester.pump();
    expect(download.downloads, [_newer]);
    expect(find.text(tr.download.resolving), findsOneWidget);
    expect(download.installs, 0);
  });

  testWidgets('known and unknown download sizes show progress, cancel and an explicit retry', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations;
    checked(const UpdateCubitState(latestVersionInfo: _newer));
    download.show(
      const UpdateDownloadState(status: UpdateDownloadStatus.downloading, version: '99.0.0', received: 25, total: 100),
    );
    await pumpPage(tester);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.25);
    expect(
      find.text(
        tr.updatePage.download.progress(
          received: tr.updatePage.download.bytes(count: '25'),
          total: tr.updatePage.download.bytes(count: '100'),
          percent: '25',
        ),
      ),
      findsOneWidget,
    );

    download.show(
      const UpdateDownloadState(status: UpdateDownloadStatus.downloading, version: '99.0.0', received: 50),
    );
    // Deliver the asynchronous cubit event, then render its scheduled frame.
    await tester.pump();
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);
    expect(
      find.text(tr.updatePage.download.received(bytes: tr.updatePage.download.bytes(count: '50'))),
      findsOneWidget,
    );
    await tester.tap(find.text(tr.general.cancel));
    await tester.pump();
    expect(download.cancellations, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text(tr.updatePage.download.cancelled), findsOneWidget);
    await tester.tap(find.text(tr.updatePage.download.retryDownload(version: _newer.version)));
    await tester.pump();
    expect(download.downloads, [_newer]);
  });

  testWidgets('version checks and returning to the page preserve an active APK and its version', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.updatePage;
    checked(const UpdateCubitState(latestVersionInfo: _newer));
    download.show(
      const UpdateDownloadState(status: UpdateDownloadStatus.downloading, version: '98.0.0', received: 20, total: 100),
    );
    await pumpPage(tester);
    checked(const UpdateCubitState(loading: true));
    await tester.pump();
    expect(find.text(tr.download.title(version: '98.0.0')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    checked(const UpdateCubitState(notice: true));
    await tester.pump();
    expect(find.text(tr.failed), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await pumpPage(tester, visible: false);
    expect(download.isClosed, isFalse);
    download.show(const UpdateDownloadState(status: UpdateDownloadStatus.ready, version: '98.0.0'));
    checked(const UpdateCubitState(latestVersionInfo: _newer));
    await pumpPage(tester);
    expect(find.text(tr.download.title(version: '98.0.0')), findsOneWidget);
    expect(find.text(tr.download.title(version: '99.0.0')), findsNothing);
    expect(find.text(tr.download.install), findsOneWidget);
    expect(find.text(tr.download.downloadApk(version: '99.0.0')), findsNothing);
    expect(download.downloads, isEmpty);
    expect(download.installs, 0);
    await tester.tap(find.text(tr.download.install));
    await tester.pump();
    expect(download.installs, 1);
  });

  testWidgets('permission settings and installer retry each require an explicit tap', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.updatePage.download;
    download.show(const UpdateDownloadState(status: UpdateDownloadStatus.permissionRequired, version: '99.0.0'));
    await pumpPage(tester);
    expect(find.text(tr.permissionRequired), findsOneWidget);
    expect(download.installs, 0);
    await tester.tap(find.text(tr.openPermissionSettings));
    await tester.pump();
    expect(download.settingsOpened, 1);
    expect(download.installs, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(download.installs, 0);
    await tester.tap(find.text(tr.retryInstall));
    await tester.pump();
    expect(download.installs, 1);

    download.show(const UpdateDownloadState(status: UpdateDownloadStatus.installerOpened, version: '99.0.0'));
    await tester.pump();
    expect(find.text(tr.installerOpened), findsOneWidget);
    expect(find.text(tr.ready), findsNothing);
    expect(download.installs, 1);
    await tester.tap(find.text(tr.retryInstall));
    await tester.pump();
    expect(download.installs, 2);
    expect(download.downloads, isEmpty);
  });

  testWidgets('download errors keep browser fallback and retry the explicitly named latest release', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.updatePage.download;
    checked(const UpdateCubitState(latestVersionInfo: _newer));
    download.show(
      const UpdateDownloadState(
        status: UpdateDownloadStatus.failed,
        version: '98.0.0',
        failure: UpdateDownloadFailure.integrity,
      ),
    );
    await pumpPage(tester);
    expect(find.text(tr.integrityError), findsOneWidget);
    expect(find.text(tr.github), findsOneWidget);
    expect(find.text(tr.title(version: '98.0.0')), findsOneWidget);
    expect(find.text(tr.retryDownload(version: '99.0.0')), findsOneWidget);
    expect(find.text(tr.install), findsNothing);
    await tester.tap(find.text(tr.retryDownload(version: '99.0.0')));
    await tester.pump();
    expect(download.downloads, [_newer]);
  });

  testWidgets('an installer failure retries the existing APK without another download', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.updatePage.download;
    checked(const UpdateCubitState(latestVersionInfo: _newer));
    download.show(
      const UpdateDownloadState(
        status: UpdateDownloadStatus.failed,
        version: '98.0.0',
        failure: UpdateDownloadFailure.install,
      ),
    );
    await pumpPage(tester);
    expect(find.text(tr.installError), findsOneWidget);
    expect(find.text(tr.retryDownload(version: '99.0.0')), findsNothing);
    await tester.tap(find.text(tr.retryInstall));
    await tester.pump();
    expect(download.installs, 1);
    expect(download.downloads, isEmpty);
  });

  testWidgets('already-current Android offers no unnecessary download but retains a ready APK', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.updatePage;
    checked(
      UpdateCubitState(
        latestVersionInfo: LatestVersionInfo(
          version: 'current',
          versionCode: int.parse(appVersion.split('+').last),
          changelog: '',
        ),
      ),
    );
    await pumpPage(tester);
    expect(find.text(tr.alreadyLatest), findsOneWidget);
    expect(find.text(tr.download.downloadApk(version: 'current')), findsNothing);
    expect(find.text(tr.download.github), findsOneWidget);
    expect(download.downloads, isEmpty);

    download.show(const UpdateDownloadState(status: UpdateDownloadStatus.ready, version: '99.0.0'));
    // Deliver the asynchronous cubit event, then render its scheduled frame.
    await tester.pump();
    await tester.pump();
    expect(find.text(tr.download.install), findsOneWidget);
    expect(download.installs, 0);
  });

  testWidgets('non-Android keeps an explicit external-browser GitHub download', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.updatePage.download;
    await updates.close();
    download = _DownloadCubit(supported: false);
    updates = UpdateCubit(download: download);
    checked(const UpdateCubitState(latestVersionInfo: _newer));
    await pumpPage(tester);
    expect(find.text(tr.downloadApk(version: _newer.version)), findsNothing);
    expect(find.text(tr.githubTip), findsOneWidget);
    await tester.tap(find.text(tr.github));
    await tester.pump();
    expect(browserCalls, hasLength(1));
    final arguments = browserCalls.single.arguments as Map<Object?, Object?>;
    expect(arguments['url'], upgradeGithubReleaseUrl);
    expect(arguments['useWebView'], isFalse);
    expect(download.downloads, isEmpty);
  });

  testWidgets('download, permission and error actions wrap on a narrow screen with large text', (tester) async {
    final tr = LocaleSettings.instance.currentTranslations.updatePage.download;
    checked(const UpdateCubitState(latestVersionInfo: _newer));
    await pumpPage(tester, width: 320, scale: 2);
    await tester.scrollUntilVisible(find.text(tr.downloadApk(version: '99.0.0')), 300);
    expect(tester.takeException(), isNull);
    download.show(const UpdateDownloadState(status: UpdateDownloadStatus.permissionRequired, version: '99.0.0'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text(tr.retryInstall), 300);
    expect(find.text(tr.openPermissionSettings), findsOneWidget);
    expect(tester.takeException(), isNull);
    download.show(
      const UpdateDownloadState(
        status: UpdateDownloadStatus.failed,
        version: '99.0.0',
        failure: UpdateDownloadFailure.network,
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(find.text(tr.retryDownload(version: '99.0.0')), -150);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text(tr.github), 300);
    expect(tester.takeException(), isNull);
    expect(download.downloads, isEmpty);
    expect(download.installs, 0);
  });
}

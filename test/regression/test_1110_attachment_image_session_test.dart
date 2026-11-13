/// A picture served as an attachment of the forum (`forum.php?mod=attachment&aid=…`: the forum hides the address of its
/// files, `attachrefcheck`) is fetched with the session of the account its token was made for.
///
/// It was fetched without any session, the token alone carrying the account. A forum that limits who downloads
/// attachments (`getattachperm`) checks its groups with the group of the session sending the request (`forumperm()`
/// reads `$_G['groupid']`): without the cookie the request was a guest's, and the forum answered its message page
/// (`抱歉，您没有权限下载本附件`), which the app showed in place of the picture. The web page, sending the cookie,
/// showed it. Reproduced on Discuz X5 with the anti-leech option on and a forum limiting downloads to some groups: the
/// same picture url loads with the account's cookie and is refused without it.
///
/// Other hosts never see the cookie, nor does a token made for a guest or for another account than the one in use.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The download address of attachment 90098 of thread 9203565 as the forum makes it for account [uid].
String _attachmentUrl(int uid, {String host = 'https://www.tsdm39.com'}) {
  final token = base64.encode(utf8.encode('90098|b26d44a3|1700000000|$uid|9203565'));
  return '$host/forum.php?mod=attachment&aid=${Uri.encodeQueryComponent(token)}&noupdate=yes';
}

/// A PNG of one pixel.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// The forum's answer to a request for an attachment without the session, in a forum limiting downloads (captured on
/// Discuz X5).
final Uint8List _refused = File('test/data/attachment_getattachperm_x5.html').readAsBytesSync();

/// A host answering [_png], or the forum's refusal for an attachment when it [refuses], or a redirect to [redirectTo];
/// recording the urls asked.
final class _Host implements HttpClientAdapter {
  _Host({required this.refuses});

  /// Answers the forum's refusal page instead of an attachment.
  final bool refuses;

  /// Where every request is redirected (`302`), when not null.
  String? redirectTo;

  final requests = <String>[];

  /// The options of every request.
  final options = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.uri}');
    this.options.add(options);
    if (redirectTo case final location?) {
      return ResponseBody(
        Stream.value(Uint8List(0)),
        302,
        headers: {
          HttpHeaders.locationHeader: [location],
        },
        isRedirect: true,
      );
    }
    final refused = refuses && options.uri.queryParameters['mod'] == 'attachment';
    final body = refused ? _refused : _png;
    return ResponseBody(
      Stream.value(body),
      200,
      headers: {
        Headers.contentTypeHeader: [if (refused) 'text/html; charset=utf-8' else 'image'],
        Headers.contentLengthHeader: ['${body.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _alice = UserLoginInfo(username: 'Alice', uid: 31);

void main() {
  late Directory tmp;
  late AppDatabase db;
  late SettingsRepository settings;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tmp = Directory.systemTemp.createTempSync('tsdm_1110_');
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
        'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
        'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
        'getApplicationDocumentsPath' || 'getApplicationDocumentsDirectory' => '${tmp.path}/docs',
        _ => null,
      },
    );
    await initCache();
  });

  tearDownAll(() => tmp.delete(recursive: true));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider(_alice, {}))
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await db.close();
  });

  group('the account of a download address', () {
    test('is the uid of its token', () {
      expect(uidOfAttachmentUrl(_attachmentUrl(31)), 31);
      expect(uidOfAttachmentUrl(_attachmentUrl(31, host: 'https://tsdm39.com')), 31);
      expect(uidOfAttachmentUrl(_attachmentUrl(31).replaceFirst('https://www.tsdm39.com/', '')), 31);
    });

    test('is none for a guest, a bare aid, another host or another page', () {
      expect(uidOfAttachmentUrl(_attachmentUrl(0)), isNull);
      expect(uidOfAttachmentUrl('https://www.tsdm39.com/forum.php?mod=attachment&aid=90098'), isNull);
      expect(uidOfAttachmentUrl(_attachmentUrl(31, host: 'https://img.example')), isNull);
      expect(uidOfAttachmentUrl('https://www.tsdm39.com/data/attachment/forum/202611/14/a.png'), isNull);
      expect(uidOfAttachmentUrl('https://www.tsdm39.com/forum.php?mod=viewthread&tid=9203565'), isNull);
    });
  });

  group('a picture served as an attachment', () {
    late _Host anonymous;
    late _Host session;
    late List<int> sessionsAsked;
    late ImageCacheProvider images;

    setUp(() {
      // Without the session the forum refuses, as it does in a forum limiting downloads.
      anonymous = _Host(refuses: true);
      session = _Host(refuses: false);
      sessionsAsked = [];
      images = ImageCacheProvider(
        NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = anonymous),
        sessionClientOf: (uid) {
          sessionsAsked.add(uid);
          return uid == _alice.uid ? NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = session) : null;
        },
      );
      getIt.registerSingleton<ImageCacheProvider>(images);
    });

    tearDown(() => images.dispose());

    test('made for the account in use loads with its session', () async {
      final url = _attachmentUrl(31);
      final data = await images.getOrMakeCache(ImageCacheGeneralRequest(url));
      expect(data.toNullable(), _png);
      expect(session.requests, hasLength(1));
      expect(anonymous.requests, isEmpty);
      expect(sessionsAsked, [31]);
      expect(images.htmlMessageOf(url), isNull);
    });

    test('made for a guest is fetched without a session, the refusal kept to explain the placeholder', () async {
      final url = _attachmentUrl(0);
      final data = await images.getOrMakeCache(ImageCacheGeneralRequest(url));
      expect(data.isNone(), isTrue);
      expect(anonymous.requests, hasLength(1));
      expect(session.requests, isEmpty);
      expect(sessionsAsked, isEmpty);
      expect(images.htmlMessageOf(url), '抱歉，您没有权限下载本附件');
    });

    test('made for another account is fetched without a session', () async {
      final url = _attachmentUrl(77);
      await images.getOrMakeCache(ImageCacheGeneralRequest(url));
      expect(sessionsAsked, [77]);
      expect(anonymous.requests, hasLength(1));
      expect(session.requests, isEmpty);
    });

    test('never follows the redirect to the page taking the credits of a download', () async {
      // An image uploaded as a file (`isimage` -1) whose download costs credits: loading that page takes them.
      session.redirectTo = 'forum.php?mod=misc&action=attachcredit&aid=90098&formhash=f1f2f3f4';
      final data = await images.getOrMakeCache(ImageCacheGeneralRequest(_attachmentUrl(31)));
      expect(data.isNone(), isTrue);
      expect(session.requests, hasLength(1));
      expect(anonymous.requests, isEmpty);
    });

    test('asks every client not to follow a redirect of the session, the Kotlin client of Android too', () async {
      await images.getOrMakeCache(ImageCacheGeneralRequest(_attachmentUrl(31)));
      final sent = session.options.single;
      expect(sent.followRedirects, isFalse);
      // What the Kotlin client reads to pick its client that follows no redirect.
      expect(sent.extra[singleAttemptHttpRequestKey], isTrue);
    });

    test('follows any other redirect without the session', () async {
      session.redirectTo = 'https://img.example/storage/a.png';
      final data = await images.getOrMakeCache(ImageCacheGeneralRequest(_attachmentUrl(31)));
      expect(data.toNullable(), _png);
      expect(session.requests, hasLength(1));
      expect(anonymous.requests, ['https://img.example/storage/a.png']);
    });

    test('of another host, or a file of the forum, is fetched without a session', () async {
      for (final url in [
        _attachmentUrl(31, host: 'https://img.example'),
        'https://img.example/a.png',
        'https://www.tsdm39.com/data/attachment/forum/202611/14/a.png',
      ]) {
        await images.getOrMakeCache(ImageCacheGeneralRequest(url));
      }
      expect(anonymous.requests, hasLength(3));
      expect(session.requests, isEmpty);
      expect(sessionsAsked, isEmpty);
    });
  });

  group('the client of the app for those pictures', () {
    test('is one of the account in use, kept while it is', () {
      final client = currentAccountImageClient(31);
      expect(client, isNotNull);
      expect(currentAccountImageClient(31), same(client));
    });

    test('is none for another account or a guest', () {
      expect(currentAccountImageClient(77), isNull);
      expect(currentAccountImageClient(0), isNull);
    });

    test('is a new one once the cookie of the app is another', () async {
      final first = currentAccountImageClient(31);
      await getIt.unregister<CookieProvider>();
      getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, {}));
      expect(currentAccountImageClient(31), isNot(same(first)));
    });
  });
}

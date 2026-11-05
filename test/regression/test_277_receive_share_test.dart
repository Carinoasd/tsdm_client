/// Receiving what other apps share to this one (#277): the Dart side.
///
/// The Android side (`ShareIntents.kt`, `MainActivity.kt`) copies shared images into the cache and hands text, subject
/// and the paths over on the `shareReceive` channel; it cannot run here. The channel is answered by the test.
///
/// Decided here ([decideShare]) and carried out on a router ([ShareDispatcher]):
///
/// * a text that is one forum link opens its page (no account needed); one the app has no page for goes to the
///   "open in app" page;
/// * any other text, and every image, starts a new thread in a forum the user picks, the text as the body (the subject
///   as the title) and the images uploaded as attachments by the editor ([PostEditRepository.uploadImage],
///   `[attachimg]aid[/attachimg]` in the post, `attachnew[aid][description]` posted with it);
/// * without an account the login page comes first; declined, the shared files are deleted.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
// The editor package's own dependency: the selection is set with its change source.
// ignore: depend_on_referenced_packages
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource;
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/utils/attachment_upload.dart';
import 'package:tsdm_client/features/share_receive/models/shared_content.dart';
import 'package:tsdm_client/features/share_receive/models/shared_thread_draft.dart';
import 'package:tsdm_client/features/share_receive/share_dispatcher.dart';
import 'package:tsdm_client/features/share_receive/share_receiver.dart';
import 'package:tsdm_client/features/share_receive/utils/share_action.dart';
import 'package:tsdm_client/features/share_receive/widgets/forum_picker_sheet.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

const _thread = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123&extra=page%3D1';
const _report = 'https://tsdm39.com/forum.php?mod=modcp&action=report&fid=247';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/data/$path').readAsStringSync()) as Map<String, dynamic>;

/// A shared image file in a temporary directory, deleted with the test (synchronous io: widget tests run under a fake
/// clock, where the real event loop does not turn).
String _imageFile(String name) {
  final dir = Directory.systemTemp.createTempSync('tsdm_share_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = File('${dir.path}/$name')..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47]);
  return file.path;
}

Response<dynamic> _response(Object data, {int status = 200}) =>
    Response(requestOptions: RequestOptions(), statusCode: status, data: data);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(useConsoleLogs: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('A. what the channel hands over', () {
    test('subject, text and image paths, trimmed; nothing when empty', () {
      final content = SharedContent.fromChannel({
        'subject': ' A title ',
        'text': ' hello \n',
        'images': ['/cache/a.jpg', '', 7, '/cache/b.png'],
      })!;
      expect(content.subject, 'A title');
      expect(content.text, 'hello');
      expect(content.imagePaths, ['/cache/a.jpg', '/cache/b.png']);
      expect(SharedContent.fromChannel({'subject': 't', 'text': '  ', 'images': <String>[]}), isNull);
      expect(SharedContent.fromChannel(null), isNull);
      expect(SharedContent.fromChannel('text'), isNull);
      expect(SharedContent.fromChannel({'text': null, 'images': null}), isNull);
    });
  });

  group('B. the decision', () {
    test('one forum link opens its page, logged in or not', () {
      for (final loggedIn in [true, false]) {
        final action = decideShare(
          const SharedContent(text: _thread, subject: 'A thread'),
          loggedIn: loggedIn,
        );
        expect(action, isA<ShareOpenRoute>());
        final route = (action as ShareOpenRoute).route;
        expect(route.screenPath, ScreenPaths.threadV1);
        expect(route.queryParameters['tid'], '123');
      }
      // Without the www: still the forum.
      expect(
        decideShare(const SharedContent(text: 'https://tsdm39.com/forum.php?mod=viewthread&tid=5'), loggedIn: false),
        isA<ShareOpenRoute>(),
      );
    });

    test('a forum link the app has no page for goes to the open in app page', () {
      final action = decideShare(const SharedContent(text: _report), loggedIn: true);
      expect(action, isA<ShareOpenInApp>());
      expect((action as ShareOpenInApp).url, _report);
    });

    test('a foreign link, a title with a link, a note: a new thread with the text', () {
      for (final text in [
        'https://example.com/a?b=1',
        'Look at this $_thread',
        'just a note',
        'forum.php?mod=viewthread&tid=1',
      ]) {
        final action = decideShare(SharedContent(text: text, subject: 'S'), loggedIn: true);
        expect(action, isA<ShareCompose>(), reason: text);
        final compose = action as ShareCompose;
        expect(compose.text, text);
        expect(compose.subject, 'S');
        expect(compose.imagePaths, isEmpty);
      }
    });

    test('images: a new thread with the images, with the text if any (never opened as a link)', () {
      final action = decideShare(const SharedContent(text: _thread, imagePaths: ['/c/a.jpg']), loggedIn: true);
      expect(action, isA<ShareCompose>());
      expect((action as ShareCompose).imagePaths, ['/c/a.jpg']);
      expect(action.text, _thread);
      final only = decideShare(const SharedContent(imagePaths: ['/c/a.jpg', '/c/b.jpg']), loggedIn: true);
      expect((only as ShareCompose).text, '');
      expect(only.subject, '');
    });

    test('a new thread needs an account: login first', () {
      final action = decideShare(const SharedContent(text: 'note', imagePaths: ['/c/a.jpg']), loggedIn: false);
      expect(action, isA<ShareLoginFirst>());
      final compose = (action as ShareLoginFirst).compose;
      expect(compose.text, 'note');
      expect(compose.imagePaths, ['/c/a.jpg']);
    });

    test('an empty share is ignored', () {
      expect(decideShare(const SharedContent(), loggedIn: true), isA<ShareIgnored>());
    });
  });

  group('C. the channel', () {
    const channel = MethodChannel(ShareReceiver.channelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('the share the app was launched with is asked once; later shares are pushed, handled in order', () async {
      final asked = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        asked.add(call.method);
        return {'subject': null, 'text': _thread, 'images': <String>[]};
      });
      final got = <SharedContent>[];
      final receiver = ShareReceiver(
        channel: channel,
        onShare: (content) async {
          // The first share takes a while: the second must wait for it.
          if (got.isEmpty) await Future<void>.delayed(const Duration(milliseconds: 50));
          got.add(content);
        },
      );
      addTearDown(receiver.dispose);
      final started = receiver.start();
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('onShare', {'text': 'second', 'images': <String>[]})),
        (_) {},
      );
      await started;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(asked, ['getInitialShare']);
      expect(got.map((e) => e.text), [_thread, 'second']);
    });

    test('nothing at launch, a share without content, a side that does not answer: no handler is called', () async {
      final got = <SharedContent>[];
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final receiver = ShareReceiver(channel: channel, onShare: (content) async => got.add(content));
      addTearDown(receiver.dispose);
      await receiver.start();
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('onShare', {'text': ' ', 'images': <String>[]})),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);

      // No Android side at all (another platform): start must not throw.
      messenger.setMockMethodCallHandler(channel, null);
      final silent = ShareReceiver(channel: channel, onShare: (content) async => got.add(content));
      addTearDown(silent.dispose);
      await silent.start();
      expect(got, isEmpty);
    });
  });

  group('D. carried out on the router', () {
    /// The pages opened, in order: path with its path and query parameters and the extra.
    late List<(String, Map<String, String>, Map<String, String>, Object?)> opened;
    late GoRouter router;
    late bool loggedIn;
    late int? picked;
    late int pickCalls;

    Future<void> pumpApp(WidgetTester tester) async {
      opened = [];
      GoRoute page(String path) => GoRoute(
        path: path,
        name: path,
        builder: (context, state) {
          opened.add((path, state.pathParameters, state.uri.queryParameters, state.extra));
          return Scaffold(body: Text('page $path'));
        },
      );
      router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: Text('home')),
          ),
          page(ScreenPaths.threadV1),
          page(ScreenPaths.openInApp),
          page(ScreenPaths.login),
          page(ScreenPaths.editPost),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    }

    ShareDispatcher dispatcher() => ShareDispatcher(
      router: router,
      isLoggedIn: () => loggedIn,
      currentUid: () => loggedIn ? 31 : null,
      pickForum: () async {
        pickCalls++;
        return picked;
      },
    );

    setUp(() {
      loggedIn = true;
      picked = 2;
      pickCalls = 0;
    });

    testWidgets('a thread link opens the thread page', (tester) async {
      await pumpApp(tester);
      unawaited(dispatcher().dispatch(const SharedContent(text: _thread)));
      await tester.pumpAndSettle();
      expect(opened.length, 1);
      expect(opened.single.$1, ScreenPaths.threadV1);
      expect(opened.single.$3['tid'], '123');
      expect(pickCalls, 0);
    });

    testWidgets('an unsupported forum link goes to the open in app page, to be opened by the user', (tester) async {
      await pumpApp(tester);
      unawaited(dispatcher().dispatch(const SharedContent(text: _report)));
      await tester.pumpAndSettle();
      expect(opened.single.$1, ScreenPaths.openInApp);
      expect(opened.single.$3, {'url': _report, 'autoOpen': 'true'});
    });

    testWidgets('a text starts a new thread in the forum picked, the text as body and the subject as title', (
      tester,
    ) async {
      await pumpApp(tester);
      unawaited(dispatcher().dispatch(const SharedContent(subject: 'Title', text: 'a note')));
      await tester.pumpAndSettle();
      expect(pickCalls, 1);
      final (path, params, _, extra) = opened.single;
      expect(path, ScreenPaths.editPost);
      expect(params, {'editType': '${PostEditType.newThread.index}', 'fid': '2'});
      final draft = extra! as SharedThreadDraft;
      expect(draft.imagePaths, isEmpty);
      expect(draft.transfer!.subject, 'Title');
      expect(draft.transfer!.body, 'a note');
      expect(draft.transfer!.appliesTo(uid: 31, fid: '2'), isTrue, reason: 'the editor takes it for this account');
    });

    testWidgets('images start a new thread with the images to attach, the files kept for the editor', (tester) async {
      final a = _imageFile('a.jpg');
      final b = _imageFile('b.png');
      await pumpApp(tester);
      unawaited(dispatcher().dispatch(SharedContent(imagePaths: [a, b])));
      await tester.pumpAndSettle();
      final draft = opened.single.$4! as SharedThreadDraft;
      expect(draft.imagePaths, [a, b]);
      expect(draft.transfer, isNull, reason: 'nothing to type in');
      expect(File(a).existsSync(), isTrue);
      expect(File(b).existsSync(), isTrue);
    });

    testWidgets('no forum picked: nothing opens and the shared files are deleted', (tester) async {
      final a = _imageFile('a.jpg');
      picked = null;
      await pumpApp(tester);
      await dispatcher().dispatch(SharedContent(text: 'note', imagePaths: [a]));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(File(a).existsSync(), isFalse);
    });

    testWidgets('without an account the login page comes first; logged in, the thread follows', (tester) async {
      loggedIn = false;
      await pumpApp(tester);
      final done = dispatcher().dispatch(const SharedContent(text: 'note'));
      await tester.pumpAndSettle();
      expect(opened.single.$1, ScreenPaths.login);
      expect(pickCalls, 0);
      loggedIn = true;
      router.pop();
      await done;
      await tester.pumpAndSettle();
      expect(opened.map((e) => e.$1), [ScreenPaths.login, ScreenPaths.editPost]);
      expect((opened.last.$4! as SharedThreadDraft).transfer!.uid, 31);
    });

    testWidgets('login declined: nothing more, the shared files are deleted', (tester) async {
      final a = _imageFile('a.jpg');
      loggedIn = false;
      await pumpApp(tester);
      final done = dispatcher().dispatch(SharedContent(imagePaths: [a]));
      await tester.pumpAndSettle();
      expect(opened.single.$1, ScreenPaths.login);
      router.pop();
      await done;
      await tester.pumpAndSettle();
      expect(opened.length, 1);
      expect(pickCalls, 0);
      expect(File(a).existsSync(), isFalse);
    });
  });

  group('E. the forum picker', () {
    final groups = forumGroupsFromApi(_json('tsdmapp/index_v5_favorites.json'));

    test('every forum of every group a thread can be written in, link and hidden forums left out', () {
      final sections = postableForums(groups);
      expect(sections.map((e) => e.$1.name), groups.map((e) => e.name), reason: 'the favorites panel first');
      final forums = sections.expand((e) => e.$2).toList();
      expect(forums, isNotEmpty);
      expect(forums.where((f) => f.redirectUrl != null), isEmpty);
      expect(forums.where((f) => f.isPrivate), isEmpty);
      expect(forums.where((f) => f.forumID == 29), isEmpty, reason: 'the link forum of the fixture');
      expect(forums.where((f) => f.forumID == 7).length, 2, reason: 'in the favorites panel and in its category');
      final hidden = Forum.fromApi({'fid': 26, 'name': 'hidden', 'private': 1});
      expect(
        postableForums([
          ForumGroup(name: 'g', url: '', forumList: [hidden]),
        ]),
        isEmpty,
      );
    });

    test('the index as the topics tab shows it, from the structured answer or the web page', () {
      expect(groups.where((e) => e.isFavorites).length, 1);
      final web = buildGroupListFromDocument(
        parseHtmlDocument(File('test/data/forum_index_x5.html').readAsStringSync()),
      );
      expect(postableForums(web), isNotEmpty);
    });

    testWidgets('the sheet lists the forums under their groups and answers the one tapped', (tester) async {
      int? picked;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => picked = await showForumPickerSheet(context, groups),
                  child: const Text('pick'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      expect(find.text(tr.shareReceive.pickForum), findsOneWidget);
      expect(find.text(groups.first.name), findsOneWidget);
      final tile = find.byKey(const ValueKey('share-forum-7'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(picked, 7);
    });
  });

  group('F. the attachment upload of the form', () {
    final form = PostForm.fromJson(_json('tsdmapp/post_v16_newthread_hook.json'))!;

    test('read from attach.upload: url with type=image, uid and hash, the image types', () {
      final upload = form.attachmentUpload!;
      expect(upload.url.toString(), '$baseUrl/misc.php?mod=swfupload&action=swfupload&operation=upload&fid=2');
      expect(upload.imageUrl.queryParameters, {
        'mod': 'swfupload',
        'action': 'swfupload',
        'operation': 'upload',
        'fid': '2',
        'type': 'image',
      });
      expect(upload.uid, 31);
      expect(upload.hash, '00000000000000000000000000000000');
      expect(upload.fields, {'uid': '31', 'hash': '00000000000000000000000000000000'});
      expect(upload.maxKb, 2000);
      expect(upload.image, isTrue);
      expect(upload.imageExts, ['jpg', 'jpeg', 'gif', 'png']);
      expect(upload.acceptsImage('a.JPG'), isTrue);
      expect(upload.acceptsImage('a.webp'), isFalse);
      expect(upload.acceptsImage('noext'), isFalse);
    });

    test('none without the block or what an upload needs', () {
      final json = _json('tsdmapp/post_v16_newthread_hook.json');
      final attach = Map<String, dynamic>.from(json['attach'] as Map);
      expect(
        PostForm.fromJson({
          ...json,
          'attach': {...attach, 'upload': null},
        })!.attachmentUpload,
        isNull,
      );
      final upload = Map<String, dynamic>.from(attach['upload'] as Map);
      expect(
        PostForm.fromJson({
          ...json,
          'attach': {
            ...attach,
            'upload': {...upload, 'hash': ''},
          },
        })!.attachmentUpload,
        isNull,
      );
      expect(
        PostForm.fromJson({
          ...json,
          'attach': {
            ...attach,
            'upload': {...upload, 'url': 'https://example.com/misc.php?mod=swfupload'},
          },
        })!.attachmentUpload,
        isNull,
        reason: 'never off the forum',
      );
      expect(AttachmentUpload.fromJson({...upload, 'image': 0})!.image, isFalse);
    });

    test('the uploaded attachments are posted as attachnew[aid][description] with the thread', () {
      final body = form.bodyWith(const PostFormEdits(message: 'x', attachNew: [12, 34])).toMap()!;
      expect(body['attachnew[12][description]'], '');
      expect(body['attachnew[34][description]'], '');
      expect(body['message'], 'x');
      expect(
        form.bodyWith(const PostFormEdits(message: 'x')).toMap()!.keys.where((k) => k.startsWith('attachnew')),
        isEmpty,
      );
    });

    test('the upload script answer: the aid, or its error', () {
      expect(parseAttachmentUploadAnswer('DISCUZUPLOAD|31|0|4567|1|202611/05/abc.jpg|a.jpg\n').toNullable(), 4567);
      expect(parseAttachmentUploadAnswer(utf8.encode('DISCUZUPLOAD|31|0|89|1|p|n')).toNullable(), 89);
      final refused = parseAttachmentUploadAnswer('DISCUZUPLOAD|31|3|0|0|||2048000').getLeft().toNullable();
      expect(refused, isA<AttachmentUploadFailedException>());
      expect((refused! as AttachmentUploadFailedException).code, 3);
      final page = parseAttachmentUploadAnswer('<html>login</html>').getLeft().toNullable();
      expect((page! as AttachmentUploadFailedException).code, isNull);
      expect(parseAttachmentUploadAnswer('DISCUZUPLOAD|31|0|0|1').isLeft(), isTrue, reason: 'no aid');
      expect(parseAttachmentUploadAnswer(null).isLeft(), isTrue);
    });

    test('the media type by the extension', () {
      expect(imageContentTypeOf('/cache/1_0.jpg'), 'image/jpeg');
      expect(imageContentTypeOf('a.PNG'), 'image/png');
      expect(imageContentTypeOf('a.gif'), 'image/gif');
      expect(imageContentTypeOf('a.bin'), 'application/octet-stream');
      expect(attachmentImageBBCode(12), '[attachimg]12[/attachimg]');
    });

    test('the repository posts uid, hash and the file as Filedata to the image url, as the account in use', () async {
      final sent = <(String, Map<String, String>, MultipartFilePart)>[];
      var uid = 31;
      final repo = PostEditRepository.withTransport(
        currentUid: () => uid,
        getPage: (_) async => throw StateError('no page'),
        sendForm: (_, _) async => throw StateError('no form'),
        sendFile: (url, fields, file) async {
          sent.add((url, fields, file));
          return right(_response('DISCUZUPLOAD|31|0|777|1|202611/05/x.jpg|a.jpg'));
        },
      );
      final upload = form.attachmentUpload!;
      final aid = await repo.uploadImage(upload, '/cache/shared_images/1_0.jpg').run();
      expect(aid.toNullable(), 777);
      final (url, fields, file) = sent.single;
      expect(url, upload.imageUrl.toString());
      expect(fields, {'uid': '31', 'hash': '00000000000000000000000000000000'});
      expect(file.path, '/cache/shared_images/1_0.jpg');
      expect(file.filename, '1_0.jpg');
      expect(file.contentType, 'image/jpeg');
      expect(file.toChannelMap(), {
        'path': '/cache/shared_images/1_0.jpg',
        'filename': '1_0.jpg',
        'contentType': 'image/jpeg',
      });

      // A type the forum does not take is refused before anything is sent.
      final webp = await repo.uploadImage(upload, '/cache/a.webp').run();
      expect(webp.getLeft().toNullable(), isA<AttachmentUploadFailedException>());
      expect(sent.length, 1);

      // The account changed: nothing is uploaded as another one.
      uid = 99;
      final other = await repo.uploadImage(upload, '/cache/b.jpg').run();
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(sent.length, 1);
    });

    test('the forum refuses, or answers something else: the failure, no aid', () async {
      final answers = <Object>['DISCUZUPLOAD|31|4|0|0', '<html>denied</html>'];
      final repo = PostEditRepository.withTransport(
        currentUid: () => 31,
        getPage: (_) async => throw StateError('no page'),
        sendForm: (_, _) async => throw StateError('no form'),
        sendFile: (_, _, _) async => right(_response(answers.removeAt(0))),
      );
      final upload = form.attachmentUpload!;
      final refused = await repo.uploadImage(upload, '/c/a.jpg').run();
      expect((refused.getLeft().toNullable()! as AttachmentUploadFailedException).code, 4);
      final page = await repo.uploadImage(upload, '/c/a.jpg').run();
      expect((page.getLeft().toNullable()! as AttachmentUploadFailedException).code, isNull);

      // Without a file transport (a page without the forum's app API) nothing is offered.
      final none = PostEditRepository.withTransport(
        currentUid: () => 31,
        getPage: (_) async => throw StateError('no page'),
        sendForm: (_, _) async => throw StateError('no form'),
      );
      expect((await none.uploadImage(upload, '/c/a.jpg').run()).isLeft(), isTrue);
    });
  });

  group('G. the editor keeps the attachment code', () {
    test('inserted at the cursor as text, it leaves the editor as it went in', () {
      final controller = buildBBCodeEditorController(initialText: 'hello')
        ..updateSelection(const TextSelection.collapsed(offset: 5), ChangeSource.local)
        ..insertTextAtCursor('\n${attachmentImageBBCode(123)}\n');
      expect(controller.toForumBBCode(), 'hello\n[attachimg]123[/attachimg]\n');
      controller.dispose();
    });
  });
}

Translations get tr => LocaleSettings.instance.currentTranslations;

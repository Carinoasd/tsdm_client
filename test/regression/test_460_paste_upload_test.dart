/// Images pasted or dropped into the post editor go up as attachments.
///
/// A paste with no text on the clipboard but a picture (a screenshot, "copy image") or image files copied in the
/// file manager uploads them through the form's upload (`attach.upload`) and shows each at the cursor as
/// `[attachimg]aid[/attachimg]`; image files dropped on the editor (desktop) do the same. Text on the clipboard is
/// pasted as before. A format the forum does not take (the Windows clipboard's bitmap, WebP) goes up as a PNG.
///
/// The upload url the form names has no `simple`, so the forum (`forum_upload::uploadmsg`) answers the bare `aid`, or
/// the error negated: measured on the test forum, `1602` for a PNG and `-1` for a BMP. The edit of a post binds the
/// uploads as the new thread does (`attachnew[aid][description]`); the fixture is `post_v16_edit_reply.json`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:image/image.dart' as img;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/utils/attachment_upload.dart';
import 'package:tsdm_client/features/post/utils/pasted_image.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

Response<dynamic> _response(Object? data) =>
    Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200);

Uint8List _png({int width = 4, int height = 3, bool alpha = false}) {
  final image = img.Image(width: width, height: height, numChannels: alpha ? 4 : 3);
  img.fill(image, color: alpha ? img.ColorRgba8(255, 0, 0, 128) : img.ColorRgb8(255, 0, 0));
  return img.encodePng(image);
}

Uint8List _bmp({int width = 5, int height = 2}) => img.encodeBmp(
  img.fill(
    img.Image(width: width, height: height),
    color: img.ColorRgb8(0, 0, 255),
  ),
);

/// The forum's image extensions: `*.jpg;*.jpeg;*.gif;*.png`.
bool _forumTakes(String filename) => AttachmentUpload.fromJson(_upload())!.acceptsImage(filename);

Object? _upload() => (_json('post_v16_edit_reply')['attach'] as Map<String, dynamic>)['upload'];

ClipboardImageReader _clipboard({String? text, List<String> files = const [], Uint8List? image, bool fails = false}) =>
    ClipboardImageReader(
      hasText: () async => fails ? throw Exception('no clipboard') : text != null,
      readFiles: () async => fails ? throw Exception('no clipboard') : files,
      readImage: () async => fails ? throw Exception('no clipboard') : image,
    );

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });
  setUp(TsdmAppApi.reset);

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tsdm_paste_');
    addTearDown(() => tmp.deleteSync(recursive: true));
  });

  group('the upload answer of the form url', () {
    test('the bare aid, or the error negated', () {
      expect(parseAttachmentUploadAnswer('1602').toNullable(), 1602);
      expect(parseAttachmentUploadAnswer(utf8.encode('1603\n')).toNullable(), 1603);
      final refused = parseAttachmentUploadAnswer('-1').getLeft().toNullable()! as AttachmentUploadFailedException;
      expect(refused.reason, AttachmentUploadRefusal.refused);
      expect(refused.code, 1);
      final zero = parseAttachmentUploadAnswer('0').getLeft().toNullable()! as AttachmentUploadFailedException;
      expect(zero.reason, AttachmentUploadRefusal.unavailable);
      final empty = parseAttachmentUploadAnswer('').getLeft().toNullable()! as AttachmentUploadFailedException;
      expect(empty.reason, AttachmentUploadRefusal.unavailable, reason: 'a wrong hash answers nothing');
    });

    test('an upload through the repository takes the bare aid', () async {
      final sent = <(String, Map<String, String>, MultipartFilePart)>[];
      final repo = PostEditRepository.withTransport(
        currentUid: () => 31,
        getPage: (_) async => right(_response('')),
        sendForm: (_, _) async => right(_response('')),
        sendFile: (url, fields, file) async {
          sent.add((url, fields, file));
          return right(_response('1602'));
        },
      );
      final upload = AttachmentUpload.fromJson(_upload())!;
      final result = await repo.uploadImage(upload, '${tmp.path}/paste_1.png', fileSize: (_) => 10).run();
      expect(result.toNullable(), 1602);
      expect(sent.single.$1, contains('type=image'));
      expect(sent.single.$3.filename, 'paste_1.png');
      expect(sent.single.$3.contentType, 'image/png');
    });
  });

  group('image bytes', () {
    test('the format is told by the first bytes', () {
      expect(sniffImageExtension(_png()), 'png');
      expect(sniffImageExtension(img.encodeJpg(img.Image(width: 2, height: 2))), 'jpg');
      expect(sniffImageExtension(img.encodeGif(img.Image(width: 2, height: 2))), 'gif');
      expect(sniffImageExtension(_bmp()), 'bmp');
      expect(sniffImageExtension([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBPVP8 ')]), 'webp');
      expect(sniffImageExtension([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WAVEfmt ')]), isNull);
      expect(sniffImageExtension(utf8.encode('hello')), isNull);
      expect(sniffImageExtension(const []), isNull);
    });

    test('image files by their extension', () {
      expect(isImageFilePath('/a/b/Shot.PNG'), isTrue);
      expect(isImageFilePath(r'C:\Users\x\photo.jpeg'), isTrue);
      expect(isImageFilePath('/a/b.webp'), isTrue);
      expect(isImageFilePath('/a/notes.txt'), isFalse);
      expect(isImageFilePath('/a/png'), isFalse);
      expect(isImageFilePath('/a/.png'), isFalse, reason: 'a hidden file without a name');
    });

    test('a PNG the forum takes is written as it is', () async {
      final bytes = _png();
      final file = (await writeUploadImage(bytes, dir: tmp, stem: 'paste_1', accepts: _forumTakes))!;
      expect(file.temporary, isTrue);
      expect(file.path, endsWith('paste_1.png'));
      expect(File(file.path).readAsBytesSync(), bytes);
    });

    test('a bitmap the forum does not take goes up as a PNG of the same picture', () async {
      final file = (await writeUploadImage(_bmp(), dir: tmp, stem: 'paste_2', accepts: _forumTakes))!;
      expect(file.path, endsWith('paste_2.png'));
      final written = File(file.path).readAsBytesSync();
      expect(sniffImageExtension(written), 'png');
      final decoded = img.decodePng(written)!;
      expect((decoded.width, decoded.height), (5, 2));
      expect(decoded.getPixel(0, 0).b, 255);
    });

    test('a bitmap goes up as a PNG even where the forum names no types', () async {
      final file = (await writeUploadImage(_bmp(), dir: tmp, stem: 'paste_4', accepts: (_) => true))!;
      expect(file.path, endsWith('paste_4.png'));
      final own = File('${tmp.path}/mine.bmp')..writeAsBytesSync(_bmp());
      final copy = (await prepareImageFile(own.path, dir: tmp, stem: 'image_9', accepts: (_) => true))!;
      expect(copy.temporary, isTrue);
      expect(copy.path, endsWith('image_9.png'));
    });

    test('a bitmap the image package cannot read goes as it is where the forum takes bitmaps', () async {
      final odd = Uint8List.fromList([...ascii.encode('BM'), 1, 2, 3]);
      final file = (await writeUploadImage(odd, dir: tmp, stem: 'paste_5', accepts: (_) => true))!;
      expect(file.path, endsWith('paste_5.bmp'));
      expect(File(file.path).readAsBytesSync(), odd);
      expect(await writeUploadImage(odd, dir: tmp, stem: 'paste_6', accepts: _forumTakes), isNull);
    });

    test('a PNG with transparency keeps it', () async {
      final file = (await writeUploadImage(_png(alpha: true), dir: tmp, stem: 'paste_3', accepts: _forumTakes))!;
      final decoded = img.decodePng(File(file.path).readAsBytesSync())!;
      expect(decoded.numChannels, 4);
      expect(decoded.getPixel(1, 1).a, 128);
    });

    test('no image, or one the forum takes in no form: nothing written', () async {
      expect(await writeUploadImage(utf8.encode('text'), dir: tmp, stem: 'x', accepts: _forumTakes), isNull);
      expect(await writeUploadImage(_bmp(), dir: tmp, stem: 'y', accepts: (name) => name.endsWith('.jpg')), isNull);
      expect(tmp.listSync(), isEmpty);
    });
  });

  group('dropped or copied image files', () {
    test('a file the forum takes goes up as it is and is kept', () async {
      final own = File('${tmp.path}/mine.png')..writeAsBytesSync(_png());
      final file = (await prepareImageFile(own.path, dir: tmp, stem: 'image_1', accepts: _forumTakes))!;
      expect(file, UploadImageFile(own.path, temporary: false));
    });

    test('a file of another type goes up as a PNG copy; the file itself stays', () async {
      final own = File('${tmp.path}/mine.bmp')..writeAsBytesSync(_bmp());
      final copyDir = Directory('${tmp.path}/upload');
      final file = (await prepareImageFile(own.path, dir: copyDir, stem: 'image_2', accepts: _forumTakes))!;
      expect(file.temporary, isTrue);
      expect(file.path, startsWith(copyDir.path));
      expect(file.path, endsWith('image_2.png'));
      expect(own.existsSync(), isTrue);
      expect(own.readAsBytesSync(), _bmp());
    });

    test('an unreadable or broken file is refused', () async {
      expect(await prepareImageFile('${tmp.path}/gone.bmp', dir: tmp, stem: 'z', accepts: _forumTakes), isNull);
      final broken = File('${tmp.path}/broken.webp')..writeAsStringSync('not an image');
      expect(await prepareImageFile(broken.path, dir: tmp, stem: 'z', accepts: _forumTakes), isNull);
    });
  });

  group('what a paste takes from the clipboard', () {
    test('text is pasted as text, even beside a picture', () async {
      expect(await _clipboard(text: 'hello').read(), isNull);
      expect(await _clipboard(text: 'cells', image: _png()).read(), isNull);
    });

    test('a picture without text is uploaded', () async {
      final bytes = _png();
      final images = await _clipboard(image: bytes).read();
      expect(images, isA<ClipboardImageBytes>());
      expect((images! as ClipboardImageBytes).bytes, bytes);
    });

    test('image files copied in the file manager are uploaded; with any other file, nothing is', () async {
      final images = await _clipboard(files: ['/a/1.png', '/a/2.JPG'], text: '/a/1.png').read();
      expect((images! as ClipboardImagePaths).paths, ['/a/1.png', '/a/2.JPG']);
      expect(await _clipboard(files: ['/a/1.png', '/a/doc.pdf'], image: _png()).read(), isNull);
    });

    test('an empty or unreadable clipboard leaves the paste to the editor', () async {
      expect(await _clipboard().read(), isNull);
      expect(await _clipboard(image: Uint8List(0)).read(), isNull);
      expect(await _clipboard(fails: true).read(), isNull);
    });
  });

  group('the edit of a post', () {
    test('binds the images uploaded while editing', () async {
      final posts = <Map<String, String>>[];
      final repo = PostEditRepository.withTransport(
        currentUid: () => 31,
        getPage: (_) async => right(_response(_json('post_v16_edit_reply'))),
        sendForm: (_, body) async {
          posts.add(body);
          return right(
            _response({
              'ok': 1,
              'api': 1,
              'time': 1700000000,
              'uid': 31,
              'formhash': 'f1f2f3f4',
              'type': 'result',
              'schema': 13,
              'kind': 'redirect',
              'message': '',
              'message_key': 'post_edit_succeed',
              'url': 'forum.php?mod=viewthread&tid=9600001&page=&extra=#pid9700003',
              'handlekey': '',
              'values': <String, Object?>{},
              'login': 0,
              'alert': '',
            }),
          );
        },
      );
      final bloc = PostEditBloc(postEditRepository: repo);
      addTearDown(bloc.close);
      final loaded = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
      bloc.add(
        const PostEditLoadDataRequested(
          'https://www.tsdm39.com/forum.php?mod=post&action=edit&fid=2&tid=9600001&pid=9700003',
        ),
      );
      await loaded.timeout(const Duration(seconds: 3));
      final content = bloc.state.content!;
      final settled = bloc.stream.firstWhere((s) => s.status != PostEditStatus.uploading);
      bloc.add(
        PostEditCompleteEditRequested(
          formHash: content.formHash,
          postTime: content.postTime,
          delattachop: '0',
          page: content.page ?? '',
          wysiwyg: content.wysiwyg,
          fid: '2',
          tid: '9600001',
          pid: '9700003',
          threadType: null,
          threadTitle: content.threadTitle,
          data: 'reply\n${attachmentImageBBCode(1605)}',
          options: const [],
          save: '',
          perm: null,
          price: null,
          attachNew: const [1605],
        ),
      );
      final state = await settled.timeout(const Duration(seconds: 3));
      expect(state.status, PostEditStatus.success);
      expect(posts.single['attachnew[1605][description]'], '');
      expect(posts.single['message'], 'reply\n[attachimg]1605[/attachimg]');
    });
  });
}

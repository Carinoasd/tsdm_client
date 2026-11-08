/// Images are edited before they go up as attachments.
///
/// The image editor ([ImageUploadEditPage]) cuts (free or to a ratio), pixelates with a brush, turns, and chooses the
/// longest side (1280, 1920, the original) and the JPEG quality; 略過 uploads the image as it is. The settings decide
/// whether every image opens it first (off by default) and the size and quality images go up with otherwise.
/// Processing ([applyImageEdits]) bakes the EXIF orientation, keeps PNG when there is transparency, writes JPEG
/// otherwise, and leaves a GIF and an image with nothing to change as they are. The images here are made in the test.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post/utils/image_edits.dart';
import 'package:tsdm_client/features/post/utils/pasted_image.dart';
import 'package:tsdm_client/features/post/view/image_upload_edit_page.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/upload_image_settings.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

/// A picture of [width] by [height] whose pixel (x, y) is (x * 10, y * 10, 100), opaque or half transparent.
img.Image _picture(int width, int height, {bool alpha = false}) {
  final image = img.Image(width: width, height: height, numChannels: alpha ? 4 : 3);
  for (final p in image) {
    p
      ..r = p.x * 10
      ..g = p.y * 10
      ..b = 100;
    if (alpha) p.a = 128;
  }
  return image;
}

Uint8List _png(int width, int height, {bool alpha = false}) => img.encodePng(_picture(width, height, alpha: alpha));

img.Image _decode(EditedImage edited) => img.decodeImage(edited.bytes)!;

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  group('processing', () {
    test('nothing to change: the file goes up as it is', () {
      expect(applyImageEdits(_png(8, 4), const ImageEdits()), isNull);
      expect(applyImageEdits(_png(8, 4), const ImageEdits(maxSide: 1280)), isNull, reason: 'not larger than the side');
      expect(applyImageEdits(Uint8List.fromList([1, 2, 3]), const ImageEdits(quarterTurns: 1)), isNull);
    });

    test('scaled down to the longest side, as JPEG of the quality', () {
      final edited = applyImageEdits(_png(30, 10), const ImageEdits(maxSide: 12, quality: 80))!;
      expect(edited.extension, 'jpg');
      expect((edited.width, edited.height), (12, 4));
      expect(sniffImageExtension(edited.bytes), 'jpg');
      final tall = applyImageEdits(_png(10, 30), const ImageEdits(maxSide: 12))!;
      expect((tall.width, tall.height), (4, 12));
    });

    test('a quarter turn clockwise: the top left corner goes to the top right', () {
      final edited = applyImageEdits(_png(4, 2, alpha: true), const ImageEdits(quarterTurns: 1))!;
      final image = _decode(edited);
      expect((image.width, image.height), (2, 4));
      // Source (0, 0) is (0, 0, 100); after the turn it is at (height - 1, 0).
      expect(image.getPixel(1, 0).r, 0);
      expect(image.getPixel(1, 0).g, 0);
      // Source (3, 0) is (30, 0, 100), now at (1, 3).
      expect(image.getPixel(1, 3).r, 30);
    });

    test('cut to the part kept, in fractions of the turned picture', () {
      final edited = applyImageEdits(_png(8, 4, alpha: true), const ImageEdits(crop: Rect.fromLTWH(0.5, 0, 0.5, 1)))!;
      final image = _decode(edited);
      expect((image.width, image.height), (4, 4));
      expect(image.getPixel(0, 0).r, 40, reason: 'the right half starts at x 4');
    });

    test('the mosaic fills each cell the brush touched with its average; the rest stays', () {
      final source = _picture(80, 80, alpha: true);
      const edits = ImageEdits(
        strokes: [
          MosaicStroke([Offset(0.25, 0.25)], 0.01),
        ],
      );
      final image = _decode(applyImageEdits(img.encodePng(source), edits)!);
      final cell = mosaicCellSize(80);
      expect(cell, 4);
      // The cell under the point (20, 20): x 20..23, y 20..23, the average of x * 10 is 215.
      final colors = {
        for (var y = 20; y < 24; y++)
          for (var x = 20; x < 24; x++) (image.getPixel(x, y).r.toInt(), image.getPixel(x, y).g.toInt()),
      };
      expect(colors, {(215, 215)});
      expect(image.getPixel(60, 10).r, source.getPixel(60, 10).r);
      expect(image.getPixel(60, 10).g, source.getPixel(60, 10).g);
    });

    test('a stroke covers the cells along its whole way', () {
      const edits = ImageEdits(
        strokes: [
          MosaicStroke([Offset(0.1, 0.5), Offset(0.9, 0.5)], 0.01),
        ],
      );
      final image = _decode(applyImageEdits(_png(80, 80, alpha: true), edits)!);
      for (final x in [10, 40, 70]) {
        final cellX = x ~/ 4 * 4;
        expect(image.getPixel(cellX, 40).r, image.getPixel(cellX + 3, 40).r, reason: 'cell at x $x is one color');
      }
    });

    test('transparency keeps PNG; an opaque picture becomes JPEG', () {
      final clear = applyImageEdits(_png(8, 4, alpha: true), const ImageEdits(quarterTurns: 2))!;
      expect(clear.extension, 'png');
      expect(_decode(clear).getPixel(0, 0).a, 128);
      final opaque = applyImageEdits(_png(8, 4), const ImageEdits(quarterTurns: 2))!;
      expect(opaque.extension, 'jpg');
      // An alpha channel that is opaque everywhere is no transparency.
      final full = img.Image(width: 4, height: 4, numChannels: 4);
      img.fill(full, color: img.ColorRgba8(1, 2, 3, 255));
      expect(applyImageEdits(img.encodePng(full), const ImageEdits(quarterTurns: 1))!.extension, 'jpg');
    });

    test('the EXIF orientation is baked before the edits and not written again', () {
      final exif = img.ExifData();
      exif.imageIfd.orientation = 6;
      final jpg = img.injectJpgExif(img.encodeJpg(_picture(8, 4)), exif)!;
      expect(img.decodeJpgExif(jpg)!.imageIfd.orientation, 6);
      final edited = applyImageEdits(jpg, const ImageEdits(crop: Rect.fromLTWH(0, 0, 1, 0.5)))!;
      final image = _decode(edited);
      // Shown turned (4 wide, 8 high), the top half kept.
      expect((image.width, image.height), (4, 4));
      expect(image.exif.imageIfd.hasOrientation, isFalse);
    });

    test('turning the crop and the strokes with the picture; four turns are none', () {
      const crop = Rect.fromLTWH(0.1, 0.2, 0.3, 0.4);
      final once = turnCropRect(crop);
      expect(once.left, closeTo(0.4, 1e-9));
      expect(once.top, closeTo(0.1, 1e-9));
      expect(once.width, closeTo(0.4, 1e-9));
      expect(once.height, closeTo(0.3, 1e-9));
      final back = turnCropRect(turnCropRect(turnCropRect(once)));
      expect(back.left, closeTo(crop.left, 1e-9));
      expect(back.bottom, closeTo(crop.bottom, 1e-9));
      const stroke = MosaicStroke([Offset(0.2, 0.3)], 0.05);
      expect(stroke.turned().points.single, const Offset(0.7, 0.2));
      final around = stroke.turned().turned().turned().turned().points.single;
      expect(around.dx, closeTo(0.2, 1e-9));
      expect(around.dy, closeTo(0.3, 1e-9));
    });

    test('the preview is turned and pixelated, not cut, and small', () {
      final preview = previewImageEdits(
        _png(40, 20),
        const ImageEdits(quarterTurns: 1, crop: Rect.fromLTWH(0, 0, 0.5, 0.5)),
        maxSide: 10,
      )!;
      expect((preview.width, preview.height), (5, 10));
      expect(preview.extension, 'png');
    });

    test('GIF is not edited', () {
      expect(isEditableImage(img.encodeGif(img.Image(width: 2, height: 2))), isFalse);
      expect(isEditableImage(_png(2, 2)), isTrue);
      expect(isEditableImage(const [1, 2, 3]), isFalse);
    });
  });

  group('the file that goes up', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tsdm_edit_');
      addTearDown(() => tmp.deleteSync(recursive: true));
    });

    bool forumTakes(String name) => RegExp(r'\.(jpe?g|gif|png)$').hasMatch(name);

    test('edited: a temporary copy, the original kept', () async {
      final own = File('${tmp.path}/mine.png')..writeAsBytesSync(_png(30, 10));
      final source = UploadImageFile(own.path, temporary: false);
      final out = await writeEditedImage(
        source,
        const ImageEdits(maxSide: 15),
        dir: Directory('${tmp.path}/up'),
        stem: 'edited_1',
        accepts: forumTakes,
      );
      expect(out.temporary, isTrue);
      expect(out.path, endsWith('edited_1.jpg'));
      expect(img.decodeJpg(File(out.path).readAsBytesSync())!.width, 15);
      expect(own.existsSync(), isTrue);
    });

    test('nothing to do: the file is not even read', () async {
      final gone = UploadImageFile('${tmp.path}/gone.png', temporary: false);
      expect(await writeEditedImage(gone, const ImageEdits(), dir: tmp, stem: 's', accepts: forumTakes), gone);
      final small = UploadImageFile(
        (File('${tmp.path}/small.png')..writeAsBytesSync(_png(8, 8))).path,
        temporary: false,
      );
      expect(
        await writeEditedImage(small, const ImageEdits(maxSide: 1280), dir: tmp, stem: 's', accepts: forumTakes),
        small,
      );
      expect(tmp.listSync().map((e) => e.path), [small.path]);
    });

    test('nothing changed, a GIF, or a type the forum does not take: the file itself', () async {
      final own = UploadImageFile((File('${tmp.path}/a.png')..writeAsBytesSync(_png(4, 4))).path, temporary: false);
      expect(await writeEditedImage(own, const ImageEdits(), dir: tmp, stem: 's', accepts: forumTakes), own);
      final gif = UploadImageFile(
        (File('${tmp.path}/b.gif')..writeAsBytesSync(img.encodeGif(_picture(8, 8)))).path,
        temporary: false,
      );
      expect(
        await writeEditedImage(gif, const ImageEdits(quarterTurns: 1), dir: tmp, stem: 's', accepts: forumTakes),
        gif,
      );
      expect(
        await writeEditedImage(own, const ImageEdits(quarterTurns: 1), dir: tmp, stem: 's', accepts: (_) => false),
        own,
      );
    });
  });

  group('the settings', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      await settings.init();
    });

    tearDown(() async {
      await settings.dispose();
      await db.close();
    });

    test('off, the original size and quality 90 by default; kept across a restart', () async {
      final now = settings.currentSettings;
      expect(now.editImageBeforeUpload, isFalse);
      expect(now.uploadImageMaxSide, 0);
      expect(now.uploadImageQuality, 90);
      await settings.setValue(SettingsKeys.editImageBeforeUpload, true);
      await settings.setValue(SettingsKeys.uploadImageMaxSide, 1920);
      await settings.setValue(SettingsKeys.uploadImageQuality, 75);
      final restarted = SettingsRepository(storage);
      await restarted.init();
      expect(restarted.currentSettings.editImageBeforeUpload, isTrue);
      expect(restarted.currentSettings.uploadImageMaxSide, 1920);
      expect(restarted.currentSettings.uploadImageQuality, 75);
      await restarted.dispose();
      expect(now.copyWithKey(SettingsKeys.uploadImageMaxSide, 1280).uploadImageMaxSide, 1280);
    });

    testWidgets('the output dialog pops the side and the quality chosen', (tester) async {
      (int, int)? popped;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, _) => TextButton(
                    onPressed: () async => popped = await showDialog<(int, int)>(
                      context: context,
                      builder: (_) => const UploadImageOutputDialog(maxSide: 0, quality: 90),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1920'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.general.ok));
      await tester.pumpAndSettle();
      expect(popped, (1920, 90));
    });
  });

  group('the editor', () {
    Future<Future<ImageEdits?>> pumpEditor(WidgetTester tester, Uint8List bytes) async {
      late Future<ImageEdits?> result;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => result = ImageUploadEditPage.show(context, bytes, maxSide: 1920, quality: 80),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      // The preview is made in another isolate, on real time.
      for (var i = 0; i < 20 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      return result;
    }

    testWidgets('略過 uploads the image as it is', (tester) async {
      final result = await pumpEditor(tester, _png(40, 20));
      await tester.tap(find.text(tr.imageUpload.edit.skip));
      await tester.pumpAndSettle();
      expect(await result, const ImageEdits());
    });

    testWidgets('turned, a ratio cut, the size and quality chosen at first', (tester) async {
      final result = await pumpEditor(tester, _png(40, 20));
      await tester.tap(find.byIcon(Icons.rotate_right_outlined));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      await tester.tap(find.text('1:1'));
      await tester.pump();
      await tester.tap(find.text(tr.imageUpload.edit.upload));
      await tester.pumpAndSettle();
      final edits = (await result)!;
      expect(edits.quarterTurns, 1);
      expect(edits.maxSide, 1920);
      expect(edits.quality, 80);
      // Turned the picture is 20 wide and 40 high: the square is all its width, centered.
      final crop = edits.crop!;
      expect(crop.width, closeTo(1, 1e-9));
      expect(crop.height, closeTo(0.5, 1e-9));
      expect(crop.top, closeTo(0.25, 1e-9));
    });

    testWidgets('a mosaic stroke drawn on the picture; undone again', (tester) async {
      final result = await pumpEditor(tester, _png(40, 40));
      await tester.tap(find.text(tr.imageUpload.edit.mosaic));
      await tester.pump();
      final picture = tester.getRect(find.byType(Image));
      await tester.dragFrom(picture.center, const Offset(30, 0));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      await tester.tap(find.byIcon(Icons.undo_outlined));
      await tester.pump();
      await tester.dragFrom(picture.topLeft + const Offset(5, 5), const Offset(20, 20));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      await tester.tap(find.text(tr.imageUpload.edit.upload));
      await tester.pumpAndSettle();
      final edits = (await result)!;
      expect(edits.strokes, hasLength(1));
      final first = edits.strokes.single.points.first;
      expect(first.dx, lessThan(0.3));
      expect(first.dy, lessThan(0.3));
      expect(edits.crop, isNull);
    });

    testWidgets('leaving the editor uploads nothing', (tester) async {
      final result = await pumpEditor(tester, _png(10, 10));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });
  });
}

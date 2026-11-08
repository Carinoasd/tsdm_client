/// Imported font files: stored, listed, deleted and registered at startup; a file that fails to load is skipped.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/settings/repositories/custom_font_store.dart';

void main() {
  late Directory root;
  late Directory fonts;
  late List<String> registered;

  CustomFontStore makeStore({Set<String> failing = const {}}) => CustomFontStore(
    fonts,
    registerFont: (family, bytes) async {
      if (failing.contains(family)) {
        throw const FormatException('bad font');
      }
      registered.add(family);
    },
  );

  File makeSource(String name, [List<int> bytes = const [1, 2, 3]]) =>
      File('${root.path}/$name')..writeAsBytesSync(Uint8List.fromList(bytes));

  setUp(() {
    root = Directory.systemTemp.createTempSync('font_store_test');
    fonts = Directory('${root.path}/store/fonts');
    registered = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('lists nothing when the directory does not exist', () async {
    expect(await makeStore().list(), isEmpty);
    expect(await makeStore().loadAll(), isEmpty);
  });

  test('import copies the file, registers it under its file name and lists it', () async {
    final store = makeStore();
    final family = await store.import(makeSource('MyFont.ttf'));
    expect(family, 'MyFont');
    expect(registered, ['MyFont']);
    expect(File('${fonts.path}/MyFont.ttf').readAsBytesSync(), [1, 2, 3]);
    await store.import(makeSource('Another.OTF'));
    expect(await store.list(), ['Another', 'MyFont']);
  });

  test('import rejects unsupported extensions and unloadable files without keeping anything', () async {
    final store = makeStore(failing: {'Broken'});
    await expectLater(store.import(makeSource('notes.txt')), throwsFormatException);
    await expectLater(store.import(makeSource('Broken.ttf')), throwsFormatException);
    expect(await store.list(), isEmpty);
  });

  test('delete removes the file', () async {
    final store = makeStore();
    await store.import(makeSource('A.ttf'));
    await store.import(makeSource('B.otf'));
    await store.delete('A');
    expect(await store.list(), ['B']);
  });

  test('loadAll registers every stored font and skips a font that fails to load', () async {
    await makeStore().import(makeSource('Good.ttf'));
    await makeStore().import(makeSource('Bad.ttf'));
    File('${fonts.path}/readme.txt').writeAsStringSync('x');
    registered.clear();
    final loaded = await makeStore(failing: {'Bad'}).loadAll();
    expect(loaded, ['Good']);
    expect(registered, ['Good']);
  });
}

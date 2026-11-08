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
    CustomFontStore.resetRegisteredFamilies();
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
    await expectLater(store.import(makeSource('notes.txt')), throwsA(isA<FontImportException>()));
    await expectLater(store.import(makeSource('Broken.ttf')), throwsA(isA<FontImportException>()));
    expect(await store.list(), isEmpty);
  });

  test('generic family names are refused', () async {
    await expectLater(makeStore().import(makeSource('Monospace.ttf')), throwsA(isA<FontImportException>()));
  });

  test('load registers only the named font', () async {
    await makeStore().import(makeSource('One.ttf'));
    await makeStore().import(makeSource('Two.ttf'));
    registered.clear();
    CustomFontStore.resetRegisteredFamilies();
    expect(await makeStore().load('Two'), isTrue);
    expect(registered, ['Two']);
    expect(await makeStore().load('Missing'), isFalse);
  });

  test('a same-name file is refused after the family is registered and the stored font stays', () async {
    final store = makeStore();
    await store.import(makeSource('Foo.ttf'));
    await expectLater(
      store.import(makeSource('Foo.otf', [9, 9])),
      throwsA(isA<FontImportException>().having((e) => e.error, 'error', FontImportError.nameInUse)),
    );
    expect(File('${fonts.path}/Foo.ttf').readAsBytesSync(), [1, 2, 3]);
    expect(fonts.listSync().length, 1);
  });

  test('a replaced extension is swapped after a restart', () async {
    await makeStore().import(makeSource('Bar.ttf'));
    CustomFontStore.resetRegisteredFamilies();
    await makeStore().import(makeSource('Bar.otf'));
    expect(await makeStore().list(), ['Bar']);
    expect(fonts.listSync().length, 1);
  });

  test('after a restart and loadAll the same-name import is refused until the font is deleted and restarted', () async {
    await makeStore().import(makeSource('Baz.ttf'));
    CustomFontStore.resetRegisteredFamilies();
    final store = makeStore();
    await store.loadAll();
    await expectLater(store.import(makeSource('Baz.ttf', [7])), throwsA(isA<FontImportException>()));
    await store.delete('Baz');
    CustomFontStore.resetRegisteredFamilies();
    await store.import(makeSource('Baz.ttf', [7]));
    expect(File('${fonts.path}/Baz.ttf').readAsBytesSync(), [7]);
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
    CustomFontStore.resetRegisteredFamilies();
    final loaded = await makeStore(failing: {'Bad'}).loadAll();
    expect(loaded, ['Good']);
    expect(registered, ['Good']);
  });
}

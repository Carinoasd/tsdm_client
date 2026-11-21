/// On Windows, a selection made while the input method still composes (Zhuyin typed and not confirmed) left the
/// input method holding its string behind the editor's back: the next key it took (Ctrl+C, Delete) made it send the
/// string again and the text was there twice. The engine only tells the input method to drop its composition when
/// the input connection closes, so the editor closes it and opens it again when it changes under a composition by
/// anything but the input method.
///
/// 1. Windows, composing: the input method's own updates (typing on, its caret moving inside the composing text)
///    leave the connection alone; a selection over the composing text closes it at once and opens it again after
///    the frame with the selection and no composing range, the text stays; typing goes on afterwards;
/// 2. Windows, composing: a caret put elsewhere (inside the composing text as well) and text inserted by a button
///    close it too; without focus it does not open again;
/// 3. Windows, not composing (confirmed): a selection does nothing;
/// 4. the other platforms: nothing, composing or not.
///
/// What this cannot show is the input method itself letting go of its string: that is the engine and Windows, and
/// is checked by hand on a Windows machine.
///
/// Synthetic data only: no network, nothing is sent.
library;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource;
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Never answers: nothing is fetched in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);
const _others = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
  TargetPlatform.linux,
});

/// The text of the editor as the input method sees it: the document always ends with a line break.
TextEditingValue _ime(String text, {required int caret, TextRange composing = TextRange.empty}) => TextEditingValue(
  text: '$text\n',
  selection: TextSelection.collapsed(offset: caret),
  composing: composing,
);

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late FocusNode node;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio()..httpClientAdapter = _OfflineAdapter()),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    node = FocusNode();
  });

  tearDown(() async {
    node.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// The focused editor with an open input connection; the log of the connection starts empty.
  Future<BBCodeEditorController> pumpEditor(WidgetTester tester) async {
    final controller = buildBBCodeEditorController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              SizedBox(
                height: 120,
                child: RichEditor(controller: controller, editorFocusNode: node),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.log.clear();
    return controller;
  }

  List<String> calls(WidgetTester tester) => tester.testTextInput.log.map((e) => e.method).toList();

  int count(WidgetTester tester, String method) => calls(tester).where((e) => e == method).length;

  /// The editing states sent to the input method.
  List<Map<String, dynamic>> states(WidgetTester tester) => tester.testTextInput.log
      .where((e) => e.method == 'TextInput.setEditingState')
      .map((e) => (e.arguments as Map<Object?, Object?>).cast<String, dynamic>())
      .toList();

  /// Zhuyin typed and not confirmed: the two characters are the composing text.
  Future<void> compose(WidgetTester tester, BBCodeEditorController controller) async {
    tester.testTextInput.updateEditingValue(_ime('你', caret: 1, composing: const TextRange(start: 0, end: 1)));
    await tester.pump();
    tester.testTextInput.updateEditingValue(_ime('你好', caret: 2, composing: const TextRange(start: 0, end: 2)));
    await tester.pump();
    expect(controller.document.toPlainText(), '你好\n');
    expect(calls(tester), isNot(contains('TextInput.clearClient')), reason: 'typing does not close the connection');
  }

  group('Windows, composing', () {
    testWidgets('a selection over the composing text closes the connection and opens it again', (tester) async {
      final controller = await pumpEditor(tester);
      await compose(tester, controller);

      // The caret of the input method moving inside its composing text (arrow keys) is its own update.
      tester.testTextInput.updateEditingValue(_ime('你好', caret: 1, composing: const TextRange(start: 0, end: 2)));
      await tester.pump();
      tester.testTextInput.updateEditingValue(_ime('你好', caret: 2, composing: const TextRange(start: 0, end: 2)));
      await tester.pump();
      expect(calls(tester), isNot(contains('TextInput.clearClient')));
      expect(calls(tester), isNot(contains('TextInput.setClient')));
      tester.testTextInput.log.clear();

      // The drag over the two characters.
      controller.updateSelection(const TextSelection(baseOffset: 0, extentOffset: 2), ChangeSource.local);
      expect(calls(tester), ['TextInput.clearClient'], reason: 'closed at once, nothing else is told');
      expect(tester.testTextInput.hasAnyClients, isFalse);

      await tester.pump();
      expect(count(tester, 'TextInput.clearClient'), 1);
      expect(count(tester, 'TextInput.setClient'), 1, reason: 'opened again after the frame');
      expect(tester.testTextInput.hasAnyClients, isTrue);
      final state = states(tester).last;
      expect(state['text'], '你好\n');
      expect(state['selectionBase'], 0);
      expect(state['selectionExtent'], 2);
      expect(state['composingBase'], -1);
      expect(state['composingExtent'], -1);
      expect(controller.document.toPlainText(), '你好\n', reason: 'the composed text stays as typed');
      expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 2));
      expect(node.hasFocus, isTrue);

      // The drag going on, and frames passing, do nothing more.
      tester.testTextInput.log.clear();
      controller.updateSelection(const TextSelection(baseOffset: 0, extentOffset: 1), ChangeSource.local);
      await tester.pump();
      await tester.pump();
      expect(calls(tester), isNot(contains('TextInput.clearClient')));
      expect(calls(tester), isNot(contains('TextInput.setClient')));

      // Typing goes on over the selection, composing again.
      tester.testTextInput.updateEditingValue(_ime('他好', caret: 1, composing: const TextRange(start: 0, end: 1)));
      await tester.pump();
      expect(controller.document.toPlainText(), '他好\n');
      tester.testTextInput.updateEditingValue(_ime('他好', caret: 1));
      await tester.pump();
      expect(calls(tester), isNot(contains('TextInput.clearClient')));

      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('a caret put elsewhere closes it, inside the composing text as well', (tester) async {
      final controller = await pumpEditor(tester);
      tester.testTextInput.updateEditingValue(_ime('ab', caret: 2));
      await tester.pump();
      tester.testTextInput.updateEditingValue(_ime('ab你好', caret: 4, composing: const TextRange(start: 2, end: 4)));
      await tester.pump();
      expect(calls(tester), isNot(contains('TextInput.clearClient')));

      // A click before the composing text.
      controller.updateSelection(const TextSelection.collapsed(offset: 0), ChangeSource.local);
      expect(count(tester, 'TextInput.clearClient'), 1);
      await tester.pump();
      expect(count(tester, 'TextInput.setClient'), 1);
      expect(states(tester).last['selectionBase'], 0);
      expect(controller.document.toPlainText(), 'ab你好\n');

      // Composing again at the start, then a click inside the composing text.
      tester.testTextInput.log.clear();
      tester.testTextInput.updateEditingValue(_ime('你好ab你好', caret: 2, composing: const TextRange(start: 0, end: 2)));
      await tester.pump();
      expect(calls(tester), isNot(contains('TextInput.clearClient')));
      controller.updateSelection(const TextSelection.collapsed(offset: 1), ChangeSource.local);
      expect(count(tester, 'TextInput.clearClient'), 1);
      await tester.pump();
      expect(count(tester, 'TextInput.setClient'), 1);
      expect(states(tester).last['selectionBase'], 1);
      expect(controller.document.toPlainText(), '你好ab你好\n');

      await tester.pumpWidget(const SizedBox());
    }, variant: _windows);

    testWidgets('text inserted by a button closes it; without focus it does not open again', (tester) async {
      final controller = await pumpEditor(tester);
      await compose(tester, controller);

      controller.replaceText(2, 0, 'x', const TextSelection.collapsed(offset: 3));
      expect(count(tester, 'TextInput.clearClient'), 1);
      await tester.pump();
      expect(count(tester, 'TextInput.setClient'), 1);
      expect(states(tester).last['text'], '你好x\n');
      expect(controller.document.toPlainText(), '你好x\n');

      // Composing again, a selection, and the focus gone before the frame.
      tester.testTextInput.log.clear();
      tester.testTextInput.updateEditingValue(_ime('你好x他', caret: 4, composing: const TextRange(start: 3, end: 4)));
      await tester.pump();
      controller.updateSelection(const TextSelection(baseOffset: 0, extentOffset: 4), ChangeSource.local);
      expect(count(tester, 'TextInput.clearClient'), 1);
      // The editor asks for the focus back when it loses it in the frame of a change; here it cannot have it.
      node.canRequestFocus = false;
      await tester.pump();
      await tester.pump();
      expect(node.hasFocus, isFalse);
      expect(calls(tester), isNot(contains('TextInput.setClient')));
      expect(tester.testTextInput.hasAnyClients, isFalse);

      // The focus back opens it the usual way.
      node
        ..canRequestFocus = true
        ..requestFocus();
      await tester.pump();
      expect(count(tester, 'TextInput.setClient'), 1);

      // Composing once more, a selection, and the editor gone before the frame.
      tester.testTextInput.log.clear();
      tester.testTextInput.updateEditingValue(_ime('你好x他們', caret: 5, composing: const TextRange(start: 4, end: 5)));
      await tester.pump();
      controller.updateSelection(const TextSelection(baseOffset: 0, extentOffset: 5), ChangeSource.local);
      expect(count(tester, 'TextInput.clearClient'), 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls(tester), isNot(contains('TextInput.setClient')));
    }, variant: _windows);
  });

  testWidgets('Windows, confirmed: a selection does nothing', (tester) async {
    final controller = await pumpEditor(tester);
    await compose(tester, controller);
    // Enter in the input method: the same text, no composing range.
    tester.testTextInput.updateEditingValue(_ime('你好', caret: 2));
    await tester.pump();
    tester.testTextInput.log.clear();

    controller.updateSelection(const TextSelection(baseOffset: 0, extentOffset: 2), ChangeSource.local);
    await tester.pump();
    controller.updateSelection(const TextSelection.collapsed(offset: 0), ChangeSource.local);
    await tester.pump();
    expect(calls(tester), isNot(contains('TextInput.clearClient')));
    expect(calls(tester), isNot(contains('TextInput.setClient')));
    expect(calls(tester), contains('TextInput.setEditingState'), reason: 'the selection is told the usual way');

    await tester.pumpWidget(const SizedBox());
  }, variant: _windows);

  testWidgets('the other platforms: a selection while composing does nothing', (tester) async {
    final controller = await pumpEditor(tester);
    await compose(tester, controller);
    tester.testTextInput.log.clear();

    controller.updateSelection(const TextSelection(baseOffset: 0, extentOffset: 2), ChangeSource.local);
    await tester.pump();
    controller.updateSelection(const TextSelection.collapsed(offset: 0), ChangeSource.local);
    await tester.pump();
    controller.replaceText(0, 0, 'x', const TextSelection.collapsed(offset: 1));
    await tester.pump();
    expect(calls(tester), isNot(contains('TextInput.clearClient')));
    expect(calls(tester), isNot(contains('TextInput.setClient')));
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(controller.document.toPlainText(), 'x你好\n');

    // Confirmed before the editor goes: flutter_quill asserts when it is disposed while composing.
    tester.testTextInput.updateEditingValue(_ime('x你好', caret: 1));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  }, variant: _others);
}

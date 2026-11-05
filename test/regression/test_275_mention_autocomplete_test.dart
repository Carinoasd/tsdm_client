/// Typing `@` in the editor of a thread suggests the authors of the loaded floors, over the editor like the candidate
/// row of a keyboard, filtered by what is typed on; a tap completes the `@` to the mention chip of the name.
///
/// 1. the suggestions: every author once in order of appearance, the account in use and anonymous floors left out,
///    two spellings the forum counts as one member (case, full-width letters) are one;
/// 2. the filter: contains, case and full-width letters do not matter, an empty query keeps everyone;
/// 3. the `@` fragment of the caret: `@` at the start or after whitespace, the typed part up to the caret;
/// 4. the suggester over a controller: opens on a typed `@`, filters, picks (chip and a space), closes on a space, on
///    the caret leaving the fragment, on the focus going away; pasted text does not open it; without suggestions
///    nothing opens;
/// 5. the bar in the editor: rows with the names, the tapped one becomes the chip, the picker sheet does not open
///    for that `@`; no bar without a scope.
///
/// Synthetic data only: no network, nothing is sent.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
// The editor package's own dependency: the selection is set with its change source.
// ignore: depend_on_referenced_packages
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource;
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggester.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggestions.dart';
import 'package:tsdm_client/features/editor/widgets/mention_picker.dart';
import 'package:tsdm_client/features/editor/widgets/mention_suggestion_bar.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Never answers: avatars are not fetched in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

Post _post(String pid, String name, {String? uid, String? avatar}) => Post(
  postID: pid,
  postFloor: int.parse(pid),
  author: User(name: name, url: 'u', uid: uid, avatarUrl: avatar),
  publishTime: DateTime(2026, 11, 5),
  data: '<p>hi</p>',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
);

const _alice = MentionSuggestion(username: 'Alice', uid: '1001', avatarUrl: 'https://example.com/a.jpg');
const _bob = MentionSuggestion(username: 'Bob', uid: '1002');
const _carol = MentionSuggestion(username: 'carol_x', uid: '1003');
const List<MentionSuggestion> _three = [_alice, _bob, _carol];

/// The mention chips in the document, by name.
List<String> _chips(BBCodeEditorController controller) => controller.document
    .toDelta()
    .toList()
    .where((op) => op.data is Map && (op.data! as Map).containsKey('bbcodeUserMention'))
    .map((op) => (op.data! as Map)['bbcodeUserMention'] as String)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the suggestions of a thread', () {
    test('every author once in order, without the account in use, anonymous floors and blank names', () {
      final posts = [
        _post('1', 'Alice', uid: '1001', avatar: 'https://example.com/a.jpg'),
        _post('2', 'Me', uid: '1000'),
        _post('3', 'Bob', uid: '1002'),
        _post('4', 'alice', uid: '1001'),
        _post('5', '匿名'),
        _post('6', '  '),
        _post('7', 'ＢＯＢ', uid: '1002'),
        _post('8', 'carol_x', uid: '1003'),
        _post('9', 'Alice', uid: '1001'),
      ];
      expect(threadMentionSuggestions(posts, selfUid: 1000, selfName: 'Me'), _three);
    });

    test('the account in use is told by name when a floor carries no uid, a guest is nobody', () {
      final posts = [_post('1', 'me'), _post('2', 'Bob', uid: '1002'), _post('3', '匿名', uid: '1')];
      expect(threadMentionSuggestions(posts, selfName: 'ME'), [
        _bob,
        const MentionSuggestion(username: '匿名', uid: '1'),
      ]);
      expect(threadMentionSuggestions(posts), [
        const MentionSuggestion(username: 'me'),
        _bob,
        const MentionSuggestion(username: '匿名', uid: '1'),
      ]);
    });

    test('the filter: contains, case and full-width letters do not matter, empty keeps everyone', () {
      expect(filterMentionSuggestions(_three, ''), _three);
      expect(filterMentionSuggestions(_three, 'o'), [_bob, _carol]);
      expect(filterMentionSuggestions(_three, 'ALI'), [_alice]);
      expect(filterMentionSuggestions(_three, 'ｂｏｂ'), [_bob]);
      expect(filterMentionSuggestions(_three, 'l_x'), [_carol]);
      expect(filterMentionSuggestions(_three, 'zz'), isEmpty);
    });

    test('the @ fragment of the caret', () {
      expect(mentionFragmentAt('@', 1), (atOffset: 0, query: ''));
      expect(mentionFragmentAt('hi @Al', 6), (atOffset: 3, query: 'Al'));
      expect(mentionFragmentAt('hi @Al', 4), (atOffset: 3, query: ''));
      expect(mentionFragmentAt('hi @Al', 3), isNull, reason: 'the caret is before the @');
      expect(mentionFragmentAt('hi @Al x', 8), isNull, reason: 'a space ended the fragment');
      expect(mentionFragmentAt('a@b', 3), isNull, reason: 'an address');
      expect(mentionFragmentAt('x\n@b', 4), (atOffset: 2, query: 'b'));
      expect(mentionFragmentAt('', 0), isNull);
      expect(mentionFragmentAt('ab', 5), isNull);
    });
  });

  group('the suggester over a controller', () {
    late FocusNode node;

    /// A focused node, so the suggester sees the editor focused.
    Future<void> pumpFocus(WidgetTester tester) async {
      node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Focus(focusNode: node, autofocus: true, child: const SizedBox()),
        ),
      );
      await tester.pump();
      expect(node.hasFocus, isTrue);
    }

    (BBCodeEditorController, MentionSuggester, List<int>) attach(List<MentionSuggestion> suggestions) {
      final controller = buildBBCodeEditorController();
      addTearDown(controller.dispose);
      final suggester = MentionSuggester(controller: controller, focusNode: node)
        ..suggestions = suggestions
        ..attach();
      addTearDown(suggester.dispose);
      final notified = <int>[];
      suggester.addListener(() => notified.add(suggester.visible.length));
      return (controller, suggester, notified);
    }

    testWidgets('a typed @ opens with everyone, typing on filters, a pick leaves the chip and a space', (tester) async {
      await pumpFocus(tester);
      final (controller, suggester, notified) = attach(_three);

      controller.insertPlainText('hi ');
      expect(suggester.isOpen, isFalse, reason: 'nothing typed yet');
      controller.insertPlainText('@');
      expect(suggester.visible, _three);
      expect(notified, [3]);

      controller.insertPlainText('O');
      expect(suggester.visible, [_bob, _carol]);
      controller.insertPlainText('b');
      expect(suggester.visible, [_bob]);
      controller.insertPlainText('z');
      expect(suggester.isOpen, isFalse, reason: 'nobody matches');
      controller.replaceText(6, 1, '', const TextSelection.collapsed(offset: 6));
      expect(suggester.visible, [_bob], reason: 'the backspace brings the match back');

      suggester.pick(_bob);
      expect(suggester.isOpen, isFalse);
      expect(controller.document.toPlainText(), isNot(contains('@')));
      expect(_chips(controller), ['{"username":"Bob"}']);
      expect(controller.toForumBBCode(), 'hi [@]Bob[/@] ');
      expect(toOfficialMentions(controller.toForumBBCode()), 'hi @⁣Bob⁣ ');
      expect(controller.selection, const TextSelection.collapsed(offset: 5), reason: 'after the chip and the space');

      controller.insertPlainText('@');
      expect(suggester.visible, _three, reason: 'opens again after the space');
    });

    testWidgets('a space closes, the caret leaving closes, the focus going away closes', (tester) async {
      await pumpFocus(tester);
      final (controller, suggester, _) = attach(_three);

      controller.insertPlainText('@');
      expect(suggester.isOpen, isTrue);
      controller.insertPlainText(' ');
      expect(suggester.isOpen, isFalse);
      controller.insertPlainText('x');
      expect(suggester.isOpen, isFalse, reason: 'does not open without an @ typed');

      controller.insertPlainText(' @a');
      expect(suggester.isOpen, isFalse, reason: 'a multi character insert is pasted, not typed');
      controller
        ..replaceText(6, 0, '', const TextSelection.collapsed(offset: 6))
        ..insertPlainText('l');
      expect(suggester.isOpen, isFalse, reason: 'typing on in a pasted fragment does not open it either');

      controller
        ..insertPlainText(' ')
        ..insertPlainText('@');
      expect(suggester.visible, _three);
      controller.updateSelection(const TextSelection.collapsed(offset: 2), ChangeSource.local);
      expect(suggester.isOpen, isFalse, reason: 'the caret left the fragment');
      controller.moveCursorToEnd();
      expect(suggester.isOpen, isFalse, reason: 'back in the fragment does not reopen: only a typed @ opens');

      controller
        ..insertPlainText(' ')
        ..insertPlainText('@');
      expect(suggester.isOpen, isTrue);
      node.unfocus();
      await tester.pump();
      expect(suggester.isOpen, isFalse);
      expect(controller.toForumBBCode(), '@ x @al @ @', reason: 'the text stays as typed');
    });

    testWidgets('without suggestions nothing opens, and they can arrive later', (tester) async {
      await pumpFocus(tester);
      final (controller, suggester, notified) = attach(const []);

      controller.insertPlainText('@');
      expect(suggester.isOpen, isFalse);
      expect(notified, isEmpty);

      suggester.suggestions = _three;
      expect(suggester.isOpen, isFalse, reason: 'the @ was typed before there was anyone');
      controller
        ..insertPlainText(' ')
        ..insertPlainText('@');
      expect(suggester.visible, _three);

      suggester.suggestions = const [_bob];
      expect(suggester.visible, [_bob], reason: 'the open bar follows the list');
      suggester.suggestions = const [];
      expect(suggester.isOpen, isFalse);
    });

    testWidgets('a pick over a fragment that is gone does nothing', (tester) async {
      await pumpFocus(tester);
      final (controller, suggester, _) = attach(_three);
      controller.insertPlainText('@');
      expect(suggester.isOpen, isTrue);
      controller
        ..setDocumentFromRawText('other')
        ..moveCursorToEnd();
      suggester.pick(_alice);
      expect(_chips(controller), isEmpty);
      expect(controller.toForumBBCode(), 'other');
    });
  });

  group('the bar in the editor', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late FocusNode node;

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

    Finder row(String name) => find.byKey(ValueKey('mention-suggestion-$name'));

    /// The editor at the bottom of a page, focused, under a scope with [suggestions] (none without).
    Future<BBCodeEditorController> pumpEditor(WidgetTester tester, {List<MentionSuggestion>? suggestions}) async {
      final controller = buildBBCodeEditorController();
      addTearDown(controller.dispose);
      Widget editor = SizedBox(
        height: 120,
        child: RichEditor(controller: controller, editorFocusNode: node),
      );
      if (suggestions != null) {
        editor = MentionSuggestionsScope(suggestions: suggestions, child: editor);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox()),
                editor,
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      return controller;
    }

    testWidgets('the typed @ shows the authors over the editor, typing filters, a tap completes', (tester) async {
      final controller = await pumpEditor(tester, suggestions: _three);
      expect(find.byType(MentionSuggestionBar), findsNothing, reason: 'nothing typed yet');

      controller.insertPlainText('hi ');
      await tester.pump();
      expect(row('Alice'), findsNothing);

      controller.insertPlainText('@');
      await tester.pump();
      expect(row('Alice'), findsOneWidget);
      expect(row('Bob'), findsOneWidget);
      expect(row('carol_x'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      // Over the editor: the bar ends where the editor starts.
      final editorTop = tester.getTopLeft(find.byType(BBCodeEditor)).dy;
      final bar = find.byType(MentionSuggestionBar);
      expect(tester.getBottomLeft(bar).dy, lessThanOrEqualTo(editorTop));
      expect(tester.getSize(bar).width, tester.getSize(find.byType(BBCodeEditor)).width);
      expect(tester.getTopLeft(row('Alice')).dy, lessThan(tester.getTopLeft(row('Bob')).dy));

      // The picker sheet of the typed @ does not open: the bar does the completing.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(MentionPickerSheet), findsNothing);
      expect(controller.toForumBBCode(), 'hi @');

      controller.insertPlainText('c');
      await tester.pump();
      expect(row('Alice'), findsOneWidget);
      expect(row('carol_x'), findsOneWidget);
      expect(row('Bob'), findsNothing);

      await tester.tap(row('carol_x'));
      await tester.pump();
      expect(find.byType(MentionSuggestionBar), findsNothing);
      expect(_chips(controller), ['{"username":"carol_x"}']);
      expect(controller.toForumBBCode(), 'hi [@]carol_x[/@] ');
      expect(node.hasFocus, isTrue, reason: 'the tap on the bar is not a tap outside the editor');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a space hides the bar, nobody matching hides it, no bar without a scope', (tester) async {
      final controller = await pumpEditor(tester, suggestions: _three);
      controller.insertPlainText('@');
      await tester.pump();
      expect(row('Alice'), findsOneWidget);
      controller.insertPlainText('zz');
      await tester.pump();
      expect(find.byType(MentionSuggestionBar), findsNothing);
      controller
        ..replaceText(1, 2, '', const TextSelection.collapsed(offset: 1))
        ..insertPlainText(' ');
      await tester.pump();
      expect(find.byType(MentionSuggestionBar), findsNothing);
      await tester.pumpWidget(const SizedBox());

      final bare = await pumpEditor(tester);
      bare.insertPlainText('@');
      await tester.pump();
      expect(find.byType(MentionSuggestionBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

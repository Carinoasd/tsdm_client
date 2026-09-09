import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/topics/widgets/group_moderators_row.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// GitHub #22: the web index lists the moderators of every group ("分区版主: a, b"); the app shows them on the group
/// tab.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('the group header moderators are parsed in the site order, the favorites panel has none', () {
    final groups = buildGroupListFromDocument(parseHtmlDocument(_data('forum_index_x5.html')));
    final byName = {for (final g in groups) g.name: g};
    expect(byName['我收藏的版块']?.moderators, isEmpty);
    expect(byName['天使·后花园']?.moderators, ['琴吹紬', '捕风巫', 'cu', '未梓林']);
    expect(byName['天使·综合区']?.moderators, ['雪色物語']);
  });

  testWidgets('the row lists the names after the label and disappears when empty', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                GroupModeratorsRow(moderators: ['Alice', 'Bob']),
                GroupModeratorsRow(moderators: []),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Moderators'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.byType(ActionChip), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Serves the captured Discuz! X5 guide page instead of the network.
class _FixtureRepository extends LatestThreadRepository {
  final requested = <String>[];

  @override
  AsyncEither<uh.Document> fetchDocument(String url) {
    requested.add(url);
    return AsyncEither.of(parseHtmlDocument(File('test/data/guide_new_x5.html').readAsStringSync()));
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('homepage latest replies section parses the X5 guide page', () async {
    final repo = _FixtureRepository();
    final bloc = LatestThreadBloc(latestThreadRepository: repo);
    addTearDown(bloc.close);
    final done = bloc.stream.firstWhere((s) => s.status == LatestThreadStatus.success);
    bloc.add(LatestThreadRefreshRequested(guideUrl('new')));
    final state = await done;

    expect(repo.requested, [guideUrl('new')]);
    expect(state.threadList, hasLength(12));
    for (final thread in state.threadList) {
      expect(thread.title ?? '', isNotEmpty);
      expect(thread.threadID ?? '', isNotEmpty);
      expect(thread.forumName ?? '', isNotEmpty);
      expect(thread.latestReplyAuthor?.name ?? '', isNotEmpty);
      expect(thread.latestReplyTime, isNotNull);
    }
    expect(state.nextPageUrl ?? '', contains('view=new'));
  });
}

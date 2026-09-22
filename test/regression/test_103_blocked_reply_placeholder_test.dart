import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

class _MemorySettings extends Fake implements StorageProvider {
  final rows = <String, List<String>>{};
  @override
  Future<List<String>?> getStringList(String key) async => rows[key];
  @override
  Future<void> saveStringList(String key, List<String> value) async {
    rows[key] = List.of(value);
  }

  @override
  Future<void> deleteKey(String key) async {
    rows.remove(key);
  }
}

/// A reply of a locally blocked author becomes a placeholder in place: the floor number stays, the body is not built,
/// and unblocking from the placeholder brings the body back.
const _alice = 1000;
const _bob = 1001;

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init();
    await LocaleSettings.setLocale(AppLocale.en);
  });
  testWidgets('actual blocked reply retains its floor and restores body only after unblock', (tester) async {
    final repository = UserBlockRepository(_MemorySettings());
    await repository.block(ownerUid: _alice, uid: _bob, username: 'Bob');
    final cubit = UserBlockCubit(
      repository: repository,
      currentUid: () => _alice,
      authStatus: const Stream<AuthStatus>.empty(),
    );
    addTearDown(() async {
      await cubit.close();
      await repository.dispose();
    });
    const post = Post(
      postID: '420',
      postFloor: 42,
      author: User(name: 'Bob', uid: '$_bob', url: 'home.php?mod=space&uid=$_bob'),
      publishTime: null,
      data: 'SHOULD_NOT_BE_VISIBLE',
      replyAction: null,
      rateAction: null,
      lastEditUsername: null,
      lastEditTime: null,
      shareLink: null,
      page: 3,
      isDraft: false,
      packetAllTaken: false,
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: BlocProvider.value(
            value: cubit,
            child: Scaffold(
              body: BlockAwarePost(post: post, postList: const [post], builder: (_, p) => Text(p.data)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SHOULD_NOT_BE_VISIBLE'), findsNothing);
    expect(find.text('#42'), findsOneWidget);
    expect(find.byType(BlockedPostPlaceholder), findsOneWidget);
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(find.text('SHOULD_NOT_BE_VISIBLE'), findsOneWidget);
    expect(find.byType(BlockedPostPlaceholder), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

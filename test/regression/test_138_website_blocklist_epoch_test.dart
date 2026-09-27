import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/cubit/website_blocklist_cubit.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'fixtures/website_blocklist_fixtures.dart';

class _Auth extends Fake implements AuthenticationRepository {
  @override
  UserLoginInfo? currentUser = const UserLoginInfo(uid: 1000, username: 'SyntheticA');
  final events = StreamController<AuthStatus>.broadcast(sync: true);
  @override
  Stream<AuthStatus> get status => events.stream;
  @override
  int? get effectiveCurrentUid => currentUser?.uid;
  void change(int uid) {
    currentUser = UserLoginInfo(uid: uid, username: 'Synthetic');
    events.add(AuthStatusAuthed(currentUser!));
  }
}

class _Storage extends Fake implements StorageProvider {
  @override
  Future<List<String>?> getStringList(String key) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  tearDown(getIt.reset);
  test('A-B-A during fresh lookup cancels obsolete confirmed operation before POST', () async {
    getIt
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver());
    final auth = _Auth();
    final local = UserBlockCubit(
      repository: UserBlockRepository(_Storage()),
      currentUid: () => auth.effectiveCurrentUid,
      authStatus: auth.status,
    );
    final gate = Completer<void>();
    final forum = BlocklistForum()..lookupGate = gate;
    final cubit = WebsiteBlocklistCubit(
      auth: auth,
      localBlocks: local,
      clientFactory: (_) => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
    );
    final operation = cubit.add(
      const WebsiteBlocklistLookup(uid: 2003, username: 'Charlie', alreadyListed: false, canAdd: true),
      generation: cubit.state.generation,
    );
    for (var i = 0; i < 100 && forum.gets.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(forum.gets, isNotEmpty);
    auth.change(1001);
    auth.change(1000);
    gate.complete();
    await operation;
    await cubit.close();
    await local.close();
    await auth.events.close();
    expect(forum.posts, isEmpty, reason: 'The old confirmation must not write after its account generation expired.');
  });
}

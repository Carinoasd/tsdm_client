import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

import 'draft_fixtures.dart';

Response<dynamic> _response(String data, {bool redirect = false}) => Response<dynamic>(
  requestOptions: RequestOptions(),
  data: data,
  statusCode: redirect ? 301 : 200,
  headers: Headers.fromMap({
    if (redirect) 'location': ['forum.php?mod=viewthread&tid=123'],
  }),
);

const _edit = PostEditCompleteEditRequested(
  formHash: 'synthetic-token',
  postTime: '100',
  delattachop: '0',
  wysiwyg: '0',
  fid: '4',
  tid: '123',
  pid: '456',
  page: '1',
  threadType: null,
  threadTitle: 'Synthetic subject',
  data: 'Synthetic body',
  options: [],
  save: '1',
  perm: null,
  price: null,
);

const _new = ThreadPublishInfo(
  formHash: 'synthetic-token',
  postTime: '100',
  delAttachOp: '0',
  wysiwyg: '0',
  fid: '4',
  threadType: null,
  checkbox: '0',
  subject: 'Synthetic subject',
  message: 'Synthetic body',
  price: null,
  perm: null,
  save: '1',
  options: [],
);

Future<void> _load(PostEditBloc bloc) async {
  final loaded = bloc.stream.firstWhere((state) => state.status == PostEditStatus.editing);
  bloc.add(const PostEditLoadDataRequested('forum.php?mod=post&action=edit&fid=4&tid=123&pid=456'));
  await loaded.timeout(const Duration(seconds: 3));
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  test('seeded and repeated same-account status preserve editable private content', () async {
    final auth = BehaviorSubject<AuthStatus>.seeded(const AuthStatusAuthed(UserLoginInfo(uid: 1000, username: 'Test')));
    addTearDown(auth.close);
    final repo = PostEditRepository.withTransport(
      currentUid: () => 1000,
      getPage: (_) async => right(_response(draftEditForm())),
      sendForm: (_, _) async => throw StateError('no post'),
    );
    final bloc = PostEditBloc(postEditRepository: repo, authenticationChanges: auth.stream);
    addTearDown(bloc.close);
    await _load(bloc);
    auth.add(const AuthStatusAuthed(UserLoginInfo(uid: 1000, username: 'Test')));
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.status, PostEditStatus.editing);
    expect(bloc.state.content!.data, 'Synthetic private body');
    expect(bloc.canSubmit, isTrue);
  });
  test('switching account erases form and cannot be undone by switching back', () async {
    var uid = 1000;
    var posts = 0;
    final auth = StreamController<AuthStatus>();
    addTearDown(auth.close);
    final repo = PostEditRepository.withTransport(
      currentUid: () => uid,
      getPage: (_) async => right(_response(draftEditForm())),
      sendForm: (_, _) async {
        posts++;
        return right(_response(''));
      },
    );
    final bloc = PostEditBloc(postEditRepository: repo, authenticationChanges: auth.stream);
    addTearDown(bloc.close);
    await _load(bloc);
    final invalidated = bloc.stream.firstWhere((state) => state.status == PostEditStatus.identityChanged);
    uid = 1001;
    auth.add(const AuthStatusAuthed(UserLoginInfo(uid: 1001, username: 'Other')));
    await invalidated;
    uid = 1000;
    bloc.add(_edit);
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.content, isNull);
    expect(bloc.canSubmit, isFalse);
    expect(posts, 0);
  });
  test('late form response after account switch never appears', () async {
    var uid = 1000;
    final pending = Completer<SyncEither<Response<dynamic>>>();
    final repo = PostEditRepository.withTransport(
      currentUid: () => uid,
      getPage: (_) => pending.future,
      sendForm: (_, _) async => throw StateError('no post'),
    );
    final response = repo.fetchData('forum.php').run();
    uid = 1001;
    pending.complete(right(_response(draftEditForm())));
    expect((await response).getLeft().toNullable(), isA<IdentityChangedException>());
  });
  test('duplicate save sends once and waits for GET draft confirmation', () async {
    var posts = 0;
    Map<String, String>? payload;
    final accepted = Completer<SyncEither<Response<dynamic>>>();
    final confirm = Completer<SyncEither<Response<dynamic>>>();
    final repo = PostEditRepository.withTransport(
      currentUid: () => 1000,
      getPage: (url) async => url.contains('viewthread')
          ? confirm.future
          : right(_response(draftEditForm(extra: '<input name="tags" value="a,b">'))),
      sendForm: (_, body) {
        posts++;
        payload = body;
        return accepted.future;
      },
    );
    final bloc = PostEditBloc(postEditRepository: repo);
    addTearDown(bloc.close);
    await _load(bloc);
    final completed = bloc.stream.firstWhere((s) => s.status == PostEditStatus.success);
    bloc
      ..add(_edit)
      ..add(_edit);
    await Future<void>.delayed(Duration.zero);
    expect(posts, 1);
    expect(payload!['save'], '1');
    expect(payload!['tid'], '123');
    expect(payload!['tags'], 'a,b');
    accepted.complete(right(_response('', redirect: true)));
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.status, PostEditStatus.uploading);
    confirm.complete(right(_response(draftThread())));
    await completed.timeout(const Duration(seconds: 3));
    expect(bloc.state.redirectTid, '123');
  });
  test('new draft success that enters moderation is never labelled saved draft', () async {
    final repo = PostEditRepository.withTransport(
      currentUid: () => 1000,
      getPage: (url) async =>
          right(_response(url.contains('viewthread') ? draftThread(draft: false) : draftEditForm())),
      sendForm: (_, _) async => right(_response('', redirect: true)),
    );
    final bloc = PostEditBloc(postEditRepository: repo);
    addTearDown(bloc.close);
    await _load(bloc);
    final completed = bloc.stream.firstWhere((s) => s.status == PostEditStatus.draftUnconfirmed);
    bloc.add(const ThreadPubPostThread(_new));
    await completed.timeout(const Duration(seconds: 3));
    expect(bloc.canSubmit, isFalse);
  });
  test('all transport failures leave uploading and do not retry silently', () async {
    var posts = 0;
    final repo = PostEditRepository.withTransport(
      currentUid: () => 1000,
      getPage: (_) async => right(_response(draftEditForm())),
      sendForm: (_, _) async {
        posts++;
        return left(ThreadPublishLocationNotFoundException());
      },
    );
    final bloc = PostEditBloc(postEditRepository: repo);
    addTearDown(bloc.close);
    await _load(bloc);
    final failure = bloc.stream.firstWhere((s) => s.status == PostEditStatus.failedToUpload);
    bloc.add(_edit);
    await failure.timeout(const Duration(seconds: 3));
    expect(posts, 1);
    expect(bloc.state.content!.data, 'Synthetic private body');
    expect(bloc.canSubmit, isTrue);
  });
}

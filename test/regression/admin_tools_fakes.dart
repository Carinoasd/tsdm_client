/// A forum answering the admin actions of the app API (plugin 3.9.0) from queues, for the admin tools' tests.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';

/// One request the fake forum got.
typedef AdminRequest = ({String method, String action, Map<String, String> data, Map<String, String> headers});

/// The fixture [name] of `test/data/tsdmapp_admin/` (a fresh mutable copy each time).
Map<String, dynamic> adminFixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_admin/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// A forum answering each action from its queue (the last answer repeats); an answer may be a function of the
/// request. Null is a failed request.
final class FakeAdminForum {
  /// Constructor.
  FakeAdminForum([Map<String, List<Object?>>? answers]) : answers = answers ?? {};

  /// The answers by `GET:action` or `POST:action`, or by action for both.
  final Map<String, List<Object?>> answers;

  /// What was asked, in order.
  final requests = <AdminRequest>[];

  /// The account in use.
  int uid = 96;

  /// The session (one per test).
  final session = AdminSession();

  Map<String, dynamic>? _answer(AdminRequest r) {
    final queue = answers['${r.method}:${r.action}'] ?? answers[r.action];
    if (queue == null || queue.isEmpty) {
      return null;
    }
    final next = queue.length > 1 ? queue.removeAt(0) : queue.first;
    final value = next is Function ? (next as Object? Function(AdminRequest))(r) : next;
    return value == null ? null : jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }

  /// A repository sending to this forum.
  AdminRepository repository() => AdminRepository(
    get: (action, query, headers) async {
      final r = (method: 'GET', action: action, data: {...query}, headers: {...headers});
      requests.add(r);
      return _answer(r);
    },
    post: (action, form, headers) async {
      final r = (method: 'POST', action: action, data: {...form}, headers: {...headers});
      requests.add(r);
      return _answer(r);
    },
    currentUid: () => uid,
    session: session,
    wait: (d) async => waits.add(d),
  );

  /// The waits the repository asked for.
  final waits = <Duration>[];

  /// The requests to [action] by [method].
  List<AdminRequest> of(String action, [String? method]) =>
      requests.where((r) => r.action == action && (method == null || r.method == method)).toList();
}

/// The answer of a successful admin login of account [uid] with [token].
Map<String, dynamic> adminLoginOk({
  int uid = 96,
  String token = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2',
}) => {
  'ok': 1,
  'api': 1,
  'time': 1700000000,
  'uid': uid,
  'formhash': 'f1f2f3f4',
  'type': 'admin',
  'schema': 25,
  'enabled': 1,
  'eligible': 1,
  'why': '',
  'op': 'login',
  'token': token,
  'header': 'X-Tsdmapp-Admin',
  'session': {'active': 1, 'expires': 1700000900, 'ttl': 900, 'max': 7200, 'checkip': 1},
  'login': {'locked': 0, 'retry_after': 0, 'tries_left': 4, 'secques': 0},
  'founder': 0,
  'actions': <String, Object?>{},
};

/// An admin error [error] with [extra] fields, as spec 3.9.0 §2 writes them.
Map<String, dynamic> adminError(String error, [Map<String, Object?> extra = const {}]) => {
  'ok': 0,
  'error': error,
  'uid': 96,
  'formhash': 'f1f2f3f4',
  ...extra,
};

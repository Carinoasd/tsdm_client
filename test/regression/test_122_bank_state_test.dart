import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/bank/cubit/bank_cubit.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/instance.dart';

// Every balance, identity and token in these fixtures is synthetic.
String _page(String content, {int uid = 1000}) =>
    '''
<html><head><script>var discuz_uid = '$uid';</script></head>
<body>$content</body></html>
''';

String _directory({int uid = 1000}) => _page('''
<table id="ttt"><thead><tr><th><h2>银行列表</h2></th></tr></thead><tbody>
<tr><td>Logo</td><td>银行名称：Synthetic bank one<br>银行行长：Test manager<br>银行简介：First test bank</td>
<td><a href="plugin.php?id=bank_ane:bank&amp;bankid=1">进入银行</a>（已开户）</td></tr>
<tr><td>Logo</td><td>银行名称：Synthetic bank two<br>银行行长：Test manager<br>银行简介：Second test bank</td>
<td><a href="plugin.php?id=bank_ane:bank&amp;bankid=2">进入银行</a>（已开户）</td></tr>
</tbody></table>
''', uid: uid);

String _savings({int bankId = 1, int uid = 1000, String token = 'old-token', bool withForm = true}) => _page('''
<div class="tbn"><ul><li><span><b>800</b></span>(银行货币)<font>测试币</font></li></ul></div>
<table id="ttt"><thead><tr><th><h2>活期储蓄</h2></th></tr></thead><tbody>
<tr><td class="footoperation">您当前的存款金额为 ${bankId * 100} ，活期利率为1‰，计息时间从2026-01-01开始。</td></tr>
<tr><td><p>您当前可得利息 5 <a href="plugin.php?id=bank_ane:bank">手动结息</a></p></td></tr>
${withForm ? '''
<tr><td><form method="post" action="plugin.php?id=bank_ane:bank">
<input type="hidden" name="bankid" value="$bankId">
<input type="hidden" name="action" value="cur">
<input type="hidden" name="formhash" value="$token">
<input type="text" name="banknum">
<input type="radio" name="op" value="in"><input type="radio" name="op" value="out">
<input type="password" name="bankpass">
<button type="submit" name="banksubmit" value="true">提交</button>
</form></td></tr>''' : ''}
</tbody></table>
''', uid: uid);

String _logs({int uid = 1000, String message = 'Synthetic deposit record'}) => _page('''
<table id="ttt"><thead><tr><th><h2>理财日志</h2></th></tr></thead><tbody>
<tr><td><table id="ttt"><tr><td>Info: $message</td><td>Time: 2026-01-01 12:00:00</td>
<td>Ip: 192.0.2.1</td></tr></table></td></tr></tbody></table>
''', uid: uid);

String _response(String url, {int uid = 1000}) {
  final query = Uri.parse(url).queryParameters;
  if (query['action'] == 'log') return _logs(uid: uid);
  if (query['action'] == 'cur') return _savings(bankId: int.parse(query['bankid']!), uid: uid);
  return _directory(uid: uid);
}

Future<BankCubit> _loadedCubit(BankRepository repository, {int? Function()? currentUid}) async {
  final cubit = BankCubit(currentUid: currentUid ?? () => 1000, repository: () => repository);
  addTearDown(cubit.close);
  await cubit.load();
  await cubit.selectBank(cubit.state.banks.first);
  expect(cubit.state.savings?.form, isNotNull);
  return cubit;
}

Future<void> _deposit(BankCubit cubit, BankSavings expected) => cubit.submit(
  expected: expected,
  operation: BankOperation.deposit,
  amount: '12',
  password: 'synthetic-bank-pass',
);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('bank repository identity', () {
    test('directory, savings and logs refuse pages served to another account', () async {
      final repository = BankRepository(
        getPage: (url) async => _response(url, uid: 1001),
        postForm: (_, _) async => throw StateError('A read must never submit'),
      );
      await expectLater(repository.fetchDirectory(1000), throwsException);
      await expectLater(repository.fetchSavings(1, 1000), throwsException);
      await expectLater(repository.fetchLogs(1, 1000), throwsException);
    });

    test('guest pages cannot supply even a structurally valid bank form', () async {
      final repository = BankRepository(
        getPage: (url) async => _response(url, uid: 0),
        postForm: (_, _) async => throw StateError('Guest data must never submit'),
      );
      await expectLater(repository.fetchDirectory(1000), throwsException);
      await expectLater(repository.fetchSavings(1, 1000), throwsException);
      await expectLater(repository.fetchLogs(1, 1000), throwsException);
    });

    test('a mismatched logged-in header takes precedence over a matching script uid', () async {
      final html = _savings().replaceFirst(
        '<body>',
        '<body><div id="inner_stat"><strong> '
            '<a href="home.php?mod=space&amp;uid=1001">Synthetic other user</a> '
            '</strong></div>',
      );
      final repository = BankRepository(getPage: (_) async => html, postForm: (_, _) async => '');
      await expectLater(repository.fetchSavings(1, 1000), throwsException);
    });

    test('matching script identity works without a theme-specific user header', () async {
      final repository = BankRepository(getPage: (url) async => _response(url), postForm: (_, _) async => '');
      expect((await repository.fetchDirectory(1000)).banks.map((bank) => bank.id), [1, 2]);
      expect((await repository.fetchSavings(1, 1000)).form, isNotNull);
      expect((await repository.fetchLogs(1, 1000)).entries.single.message, contains('Synthetic deposit record'));
    });
  });

  group('bank transaction state', () {
    test('logged-out load does not request any account data', () async {
      var requests = 0;
      final repository = BankRepository(
        getPage: (url) async {
          requests++;
          return _response(url);
        },
        postForm: (_, _) async => throw StateError('Logged-out requests cannot submit'),
      );
      final cubit = BankCubit(currentUid: () => null, repository: () => repository);
      addTearDown(cubit.close);
      await cubit.load();
      expect(requests, 0);
      expect(cubit.state.loginRequired, isTrue);
      expect(cubit.state.banks, isEmpty);
      expect(cubit.state.savings, isNull);
    });

    test('a guest response fails closed and drops the previous transaction form', () async {
      var servedUid = 1000;
      final repository = BankRepository(
        getPage: (url) async => _response(url, uid: servedUid),
        postForm: (_, _) async => throw StateError('Expired sessions cannot submit'),
      );
      final cubit = await _loadedCubit(repository);
      final expected = cubit.state.savings!;
      servedUid = 0;
      await cubit.refresh();
      expect(cubit.state.failed, isTrue);
      expect(cubit.state.savings, isNull);
      expect(cubit.isCurrent(expected), isFalse);
      await _deposit(cubit, expected);
    });

    test('double submit posts once with the fresh form and blocks navigation while POST is pending', () async {
      var revalidating = false;
      final gets = <String>[];
      final posts = <Map<String, String>>[];
      final reachedPost = Completer<void>();
      final pendingPost = Completer<String>();
      final repository = BankRepository(
        getPage: (url) async {
          gets.add(url);
          if (revalidating && Uri.parse(url).queryParameters['action'] == 'cur') {
            return _savings(token: 'fresh-token');
          }
          return _response(url);
        },
        postForm: (_, body) {
          posts.add(Map.of(body));
          reachedPost.complete();
          return pendingPost.future;
        },
      );
      final cubit = await _loadedCubit(repository);
      final expected = cubit.state.savings!;
      gets.clear();
      revalidating = true;
      final submission = _deposit(cubit, expected);
      await reachedPost.future;
      await _deposit(cubit, expected);
      await cubit.selectBank(cubit.state.banks.last);
      await cubit.loadLogs();
      await cubit.refresh();
      await cubit.load();
      expect(posts, hasLength(1));
      expect(posts.single['formhash'], 'fresh-token');
      expect(posts.single['bankid'], '1');
      expect(posts.single['action'], 'cur');
      expect(posts.single['banknum'], '12');
      expect(posts.single['op'], 'in');
      expect(posts.single['bankpass'], 'synthetic-bank-pass');
      expect(gets, hasLength(1));
      expect(cubit.state.bank?.id, 1);
      pendingPost.complete('<p>Successful operation</p>');
      await submission;
      expect(gets, hasLength(3));
      expect(cubit.state.unconfirmed, isTrue);
      expect(cubit.state.busy, isFalse);
      expect(cubit.isCurrent(expected), isFalse);
    });

    test('a POST timeout triggers only a GET refresh and remains unconfirmed', () async {
      var posts = 0;
      final requests = <String>[];
      final repository = BankRepository(
        getPage: (url) async {
          requests.add('GET');
          return _response(url);
        },
        postForm: (_, _) async {
          requests.add('POST');
          posts++;
          throw TimeoutException('Synthetic response lost');
        },
      );
      final cubit = await _loadedCubit(repository);
      requests.clear();
      await _deposit(cubit, cubit.state.savings!);
      expect(requests, ['GET', 'POST', 'GET', 'GET']);
      expect(cubit.state.unconfirmed, isTrue);
      expect(cubit.state.savings, isNotNull);
      await cubit.refresh();
      await cubit.loadLogs();
      expect(posts, 1);
      expect(requests.skip(4), everyElement('GET'));
    });

    test('a failed GET after POST clears the form and retrying performs no second POST', () async {
      var posted = false;
      var offline = false;
      var posts = 0;
      final repository = BankRepository(
        getPage: (url) async {
          if (posted && offline) throw TimeoutException('Synthetic offline read');
          return _response(url);
        },
        postForm: (_, _) async {
          posted = true;
          offline = true;
          posts++;
          return 'Unknown result';
        },
      );
      final cubit = await _loadedCubit(repository);
      final expected = cubit.state.savings!;
      await _deposit(cubit, expected);
      expect(cubit.state.failed, isTrue);
      expect(cubit.state.unconfirmed, isTrue);
      expect(cubit.state.savings, isNull);
      await _deposit(cubit, expected);
      offline = false;
      await cubit.refresh();
      expect(cubit.state.savings, isNotNull);
      expect(posts, 1);
    });

    for (final invalidFreshResponse in [
      'guest',
      'different identity',
      'different bank',
      'different currency',
      'missing form',
      'offline',
    ]) {
      test('submission stops before POST when fresh validation reports $invalidFreshResponse', () async {
        var checkFresh = false;
        var posts = 0;
        final repository = BankRepository(
          getPage: (url) async {
            if (!checkFresh) return _response(url);
            return switch (invalidFreshResponse) {
              'guest' => _savings(uid: 0),
              'different identity' => _savings(uid: 1001),
              'different bank' => _savings(bankId: 2),
              'different currency' => _savings().replaceAll('测试币', 'Other currency'),
              'missing form' => _savings(withForm: false),
              _ => throw TimeoutException('Synthetic validation timeout'),
            };
          },
          postForm: (_, _) async {
            posts++;
            return '';
          },
        );
        final cubit = await _loadedCubit(repository);
        final expected = cubit.state.savings!;
        checkFresh = true;
        await _deposit(cubit, expected);
        expect(posts, 0);
        expect(cubit.isCurrent(expected), isFalse);
        expect(cubit.state.savings?.form, isNull);
      });
    }

    test('a confirmation from before an ordinary refresh cannot submit the replacement form', () async {
      var posts = 0;
      final repository = BankRepository(
        getPage: (url) async => _response(url),
        postForm: (_, _) async {
          posts++;
          return '';
        },
      );
      final cubit = await _loadedCubit(repository);
      final expected = cubit.state.savings!;
      await cubit.refresh();
      expect(cubit.state.savings?.form, isNotNull);
      expect(cubit.isCurrent(expected), isFalse);
      await _deposit(cubit, expected);
      expect(posts, 0);
    });

    test('invalid input is refused before any validation GET or POST', () async {
      final requests = <String>[];
      final repository = BankRepository(
        getPage: (url) async {
          requests.add('GET');
          return _response(url);
        },
        postForm: (_, _) async {
          requests.add('POST');
          return '';
        },
      );
      final cubit = await _loadedCubit(repository);
      final expected = cubit.state.savings!;
      requests.clear();
      for (final amount in ['', '0', '-1', '1.5', '1e3', '9999999999999999999']) {
        await cubit.submit(
          expected: expected,
          operation: BankOperation.withdraw,
          amount: amount,
          password: 'synthetic-bank-pass',
        );
      }
      await cubit.submit(expected: expected, operation: BankOperation.withdraw, amount: '12', password: '');
      expect(requests, isEmpty);
      expect(cubit.isCurrent(expected), isTrue);
    });

    test('submission stays with the identity-bound client that loaded its confirmation', () async {
      var boundPosts = 0;
      var replacementRequests = 0;
      final boundRepository = BankRepository(
        getPage: (url) async => _response(url),
        postForm: (_, _) async {
          boundPosts++;
          return '';
        },
      );
      final replacementRepository = BankRepository(
        getPage: (url) async {
          replacementRequests++;
          return _response(url);
        },
        postForm: (_, _) async {
          replacementRequests++;
          return '';
        },
      );
      var currentRepository = boundRepository;
      final cubit = BankCubit(currentUid: () => 1000, repository: () => currentRepository);
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.selectBank(cubit.state.banks.first);
      final expected = cubit.state.savings!;
      currentRepository = replacementRepository;
      await _deposit(cubit, expected);
      expect(boundPosts, 1);
      expect(replacementRequests, 0);
      expect(cubit.state.unconfirmed, isTrue);
    });

    test('switching account invalidates an open confirmation even before the auth listener fires', () async {
      int? uid = 1000;
      var gets = 0;
      var posts = 0;
      final repository = BankRepository(
        getPage: (url) async {
          gets++;
          return _response(url);
        },
        postForm: (_, _) async {
          posts++;
          return '';
        },
      );
      final cubit = await _loadedCubit(repository, currentUid: () => uid);
      final expected = cubit.state.savings!;
      final previousGets = gets;
      uid = 1001;
      expect(cubit.isCurrent(expected), isFalse);
      await _deposit(cubit, expected);
      expect(gets, previousGets);
      expect(posts, 0);
      cubit.invalidate();
      expect(cubit.state.savings, isNull);
      expect(cubit.state.banks, isEmpty);
    });

    test('account switch during fresh form validation prevents the old account POST', () async {
      int? uid = 1000;
      var checkFresh = false;
      var posts = 0;
      final startedValidation = Completer<void>();
      final pendingValidation = Completer<String>();
      final repository = BankRepository(
        getPage: (url) {
          if (checkFresh) {
            startedValidation.complete();
            return pendingValidation.future;
          }
          return Future.value(_response(url));
        },
        postForm: (_, _) async {
          posts++;
          return '';
        },
      );
      final cubit = await _loadedCubit(repository, currentUid: () => uid);
      checkFresh = true;
      final submission = _deposit(cubit, cubit.state.savings!);
      await startedValidation.future;
      uid = 1001;
      cubit.invalidate();
      pendingValidation.complete(_savings());
      await submission;
      expect(posts, 0);
      expect(cubit.state.savings, isNull);
    });

    test('late POST completion cannot refresh or replace the newly selected account', () async {
      int? uid = 1000;
      final requests = <int?>[];
      final reachedPost = Completer<void>();
      final pendingPost = Completer<String>();
      final repository = BankRepository(
        getPage: (url) async {
          requests.add(uid);
          return _response(url, uid: uid!);
        },
        postForm: (_, _) {
          reachedPost.complete();
          return pendingPost.future;
        },
      );
      final cubit = await _loadedCubit(repository, currentUid: () => uid);
      final submission = _deposit(cubit, cubit.state.savings!);
      await reachedPost.future;
      uid = 1001;
      cubit.invalidate();
      await cubit.load();
      final beforeCompletion = requests.length;
      pendingPost.complete('Old account response');
      await submission;
      expect(requests, hasLength(beforeCompletion));
      expect(cubit.state.uid, 1001);
      expect(cubit.state.banks, hasLength(2));
      expect(cubit.state.savings, isNull);
    });
  });

  group('bank read races', () {
    test('a log failure preserves balance and a later explicit transaction still preflights once', () async {
      var posts = 0;
      final repository = BankRepository(
        getPage: (url) async {
          if (Uri.parse(url).queryParameters['action'] == 'log') {
            throw TimeoutException('Synthetic log timeout');
          }
          return _response(url);
        },
        postForm: (_, _) async {
          posts++;
          return '';
        },
      );
      final cubit = await _loadedCubit(repository);
      final expected = cubit.state.savings!;
      await cubit.loadLogs();
      expect(cubit.state.failed, isFalse);
      expect(cubit.state.logsFailed, isTrue);
      expect(cubit.state.savings, same(expected));
      expect(cubit.isCurrent(expected), isTrue);
      await _deposit(cubit, expected);
      expect(posts, 1);
      expect(cubit.state.savings, isNotNull);
      expect(cubit.state.logsFailed, isTrue);
      expect(cubit.state.unconfirmed, isTrue);
    });

    test('slow savings from the previous bank never replace the newly selected bank', () async {
      var delayFirstBank = false;
      final pending = Completer<String>();
      final repository = BankRepository(
        getPage: (url) {
          final query = Uri.parse(url).queryParameters;
          if (delayFirstBank && query['bankid'] == '1' && query['action'] == 'cur') return pending.future;
          return Future.value(_response(url));
        },
        postForm: (_, _) async => '',
      );
      final cubit = await _loadedCubit(repository);
      delayFirstBank = true;
      final oldRead = cubit.refresh();
      await cubit.selectBank(cubit.state.banks.last);
      expect(cubit.state.bank?.id, 2);
      expect(cubit.state.savings?.bankId, 2);
      pending.complete(_savings());
      await oldRead;
      expect(cubit.state.bank?.id, 2);
      expect(cubit.state.savings?.bankId, 2);
      expect(cubit.state.savings?.summary, contains('200'));
    });

    test('slow logs from the previous bank cannot appear under another bank', () async {
      final pendingLogs = Completer<String>();
      final repository = BankRepository(
        getPage: (url) {
          if (Uri.parse(url).queryParameters['action'] == 'log') return pendingLogs.future;
          return Future.value(_response(url));
        },
        postForm: (_, _) async => '',
      );
      final cubit = await _loadedCubit(repository);
      final oldRead = cubit.loadLogs();
      await cubit.selectBank(cubit.state.banks.last);
      pendingLogs.complete(_logs(message: 'Old bank private record'));
      await oldRead;
      expect(cubit.state.bank?.id, 2);
      expect(cubit.state.savings?.bankId, 2);
      expect(cubit.state.logs, isNull);
    });

    test('account invalidation discards a delayed bank directory response', () async {
      int? uid = 1000;
      final pending = Completer<String>();
      final repository = BankRepository(getPage: (_) => pending.future, postForm: (_, _) async => '');
      final cubit = BankCubit(currentUid: () => uid, repository: () => repository);
      addTearDown(cubit.close);
      final loading = cubit.load();
      uid = null;
      cubit.invalidate();
      pending.complete(_directory());
      await loading;
      expect(cubit.state.banks, isEmpty);
      expect(cubit.state.savings, isNull);
      expect(cubit.state.uid, isNull);
    });
  });
}

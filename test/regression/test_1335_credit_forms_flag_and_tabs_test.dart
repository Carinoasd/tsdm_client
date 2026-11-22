/// When the credits page offers the transfer and the exchange, and how (plugin 4.1.0, `status.credit_forms`).
///
/// * `credit_forms: 1` in a `status` of `v4: 1` turns [TsdmAppV4.creditForms] on; 0, any other value, a `status`
///   without it (plugin 4.0.x) and a `status` without `v4` leave it off. It goes with the other flags of `tsdmv=4`:
///   [TsdmAppApi.forgetStatus] forgets it.
/// * The buttons follow the tabs the forum shows the account: `tabs[].op` of `credit_base` (schema 52, 4.0.0), and
///   the `ul.tb` links of the web page for a plugin before 4.0.0. Neither asks anything more.
///
/// Fixtures: the `status` of 4.0.0 and the `credit_base` answers and page of the test forum (cleaned).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/points/bloc/points_bloc.dart';
import 'package:tsdm_client/features/points/models/credit_forms.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:universal_html/parsing.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

/// The `status` of 4.1.0: the recorded one of 4.0.0 with [creditForms] (null: left out).
Map<String, dynamic> _status(Object? creditForms) => v4Status({'version': '4.1.0', 'credit_forms': creditForms});

/// The web page of the credits with the tabs of the transfer and the exchange added after the first.
String _webPageWithForms() => v4Raw('g3_credit_base_web.html').replaceFirst(
  '<ul class="tb cl">',
  '<ul class="tb cl"><li><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=transfer">转账</a></li> '
      '<li><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=exchange">兑换</a></li>',
);

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);
  tearDown(TsdmAppApi.reset);

  group('status.credit_forms', () {
    test('only 1 in a status of v4 turns it on', () {
      knowV4Status(_status(1));
      expect(TsdmAppV4.creditForms, isTrue);
      for (final value in [null, 0, '1', true, 2]) {
        TsdmAppApi.reset();
        knowV4Status(_status(value));
        expect(TsdmAppV4.creditForms, isFalse, reason: '$value');
      }
      TsdmAppApi.reset();
      knowV4Status(v4Status({'credit_forms': 1, 'v4': null}));
      expect(TsdmAppV4.creditForms, isFalse, reason: 'a plugin that knows no tsdmv=4');
      TsdmAppApi.reset();
      knowV4Status();
      expect(TsdmAppV4.creditForms, isFalse, reason: 'the recorded status of 4.0.0');
    });

    test('a flag of its own: equality, and forgotten with the other flags', () {
      final on = TsdmAppV4Flags.fromStatus(_status(1));
      expect(on.creditForms, isTrue);
      expect(on, isNot(TsdmAppV4Flags.fromStatus(_status(null))));
      expect(on, TsdmAppV4Flags.fromStatus(_status(1)));
      expect(on.hashCode, TsdmAppV4Flags.fromStatus(_status(1)).hashCode);
      knowV4Status(_status(1));
      TsdmAppApi.forgetStatus();
      expect(TsdmAppV4.creditForms, isFalse);
    });
  });

  group('the tabs of the credits page', () {
    test('credit_base: the transfer and the exchange as the forum lists them', () {
      expect(pointsStatisticsFromApi(v4Json('credit_base_v52_forms.json')).forms, [
        CreditFormKind.transfer,
        CreditFormKind.exchange,
      ]);
      expect(pointsStatisticsFromApi(v4Json('g3_credit_base_v52.json')).forms, isEmpty, reason: 'a member group');
      final exchangeOnly = v4Json('credit_base_v52_forms.json');
      (exchangeOnly['tabs'] as List).removeWhere((e) => (e as Map)['op'] == 'transfer');
      expect(pointsStatisticsFromApi(exchangeOnly).forms, [CreditFormKind.exchange]);
      expect(creditFormsOfTabs(null), isEmpty);
      expect(creditFormsOfTabs('transfer'), isEmpty);
    });

    test('the web page: its tab links', () {
      expect(creditFormsOfDocument(parseHtmlDocument(_webPageWithForms())), [
        CreditFormKind.transfer,
        CreditFormKind.exchange,
      ]);
      expect(creditFormsOfDocument(parseHtmlDocument(v4Raw('g3_credit_base_web.html'))), isEmpty);
      // A link of the credit log (`op=log&optype=TFR`) is no tab.
      expect(
        creditFormsOfDocument(
          parseHtmlDocument('<ul class="tb"><li><a href="home.php?mod=spacecp&ac=credit&op=log">x</a></li></ul>'),
        ),
        isEmpty,
      );
    });

    test('the statistics carry them, and reading them asks nothing more', () async {
      knowV4Status(_status(1));
      final api = V4Forum((o) => V4Reply(v4Json('credit_base_v52_forms.json')));
      useV4Forum(api);
      final bloc = PointsStatisticsBloc(pointsRepository: PointsRepository(currentUid: () => _uid))
        ..add(PointsStatisticsRefreshRequested());
      final state = await bloc.stream.firstWhere((s) => s.status == PointsStatus.success);
      expect((state.canTransfer, state.canExchange), (true, true));
      expect(api.requests, hasLength(1));
      expect(api.requests.single.uri.queryParameters['op'], 'base');
      await bloc.close();

      TsdmAppApi.reset();
      knowV4Status(v4Status({'credit_pages': <String>[]}));
      final web = V4Forum((o) => V4Reply(_webPageWithForms()));
      useV4Forum(web);
      final stats = (await PointsRepository(currentUid: () => _uid).fetchStatistics().run()).getOrElse((e) => throw e);
      expect(stats.getRight().toNullable()?.forms, [CreditFormKind.transfer, CreditFormKind.exchange]);
      expect(web.requests, hasLength(1));
    });
  });
}

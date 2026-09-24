import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/root/bloc/points_changes_cubit.dart';

/// Reply and other actions that change credits (积分规则, e.g. 回复主题 威望+1
/// 天使币+1) are answered by Discuz! X5 through the `creditnotice` Set-Cookie,
/// a `D`-separated list like `0D1D1D0D0D0D0D0D0D2234424` (leading unknown, the
/// eight credit kinds, trailing uid). The app parses it into
/// [PointsChangesValue] and shows the changed kinds as a toast.
void main() {
  group('PointsChangesValue.fromCreditNotice', () {
    test('parses the reply reward (威望 +1, 天使币 +1)', () {
      final value = PointsChangesValue.fromCreditNotice('0D1D1D0D0D0D0D0D0D2234424');
      expect(value, isNotNull);
      expect(value!.ww, 1);
      expect(value.tsb, 1);
      expect(value.xc, 0);
      expect(value.tr, 0);
      expect(value.fh, 0);
      expect(value.jl, 0);
      expect(value.specialAttr, 0);
      expect(value.specialAttr2, 0);
    });

    test('parses every kind including negative and seasonal values', () {
      final value = PointsChangesValue.fromCreditNotice('0D2D-3D4D5D-6D7D8D9D42');
      expect(value, isNotNull);
      expect(value!.ww, 2);
      expect(value.tsb, -3);
      expect(value.xc, 4);
      expect(value.tr, 5);
      expect(value.fh, -6);
      expect(value.jl, 7);
      expect(value.specialAttr, 8);
      expect(value.specialAttr2, 9);
    });

    test('rejects a value that is not ten segments', () {
      expect(PointsChangesValue.fromCreditNotice('0D1D1D0D0D0D0D0D0'), isNull);
      expect(PointsChangesValue.fromCreditNotice(''), isNull);
      expect(PointsChangesValue.fromCreditNotice('0D1D1D0D0D0D0D0D0D0D2234424'), isNull);
    });

    test('rejects a value with a non-integer kind', () {
      expect(PointsChangesValue.fromCreditNotice('0DaD1D0D0D0D0D0D0D2234424'), isNull);
      expect(PointsChangesValue.fromCreditNotice('0D1DxD0D0D0D0D0D0D2234424'), isNull);
    });

    test('defaults a missing trailing seasonal value to zero', () {
      final value = PointsChangesValue.fromCreditNotice('0D1D1D0D0D0D0D0DD2234424');
      expect(value, isNotNull);
      expect(value!.specialAttr2, 0);
      expect(value.ww, 1);
    });
  });
}

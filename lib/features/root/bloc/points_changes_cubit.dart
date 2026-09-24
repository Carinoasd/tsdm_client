import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/extensions/string.dart';

part 'points_changes_cubit.mapper.dart';

/// What kinds of points changed and how much value changed.
@MappableClass()
final class PointsChangesValue with PointsChangesValueMappable {
  /// Constructor.
  const PointsChangesValue({
    this.ww = 0,
    this.tsb = 0,
    this.xc = 0,
    this.tr = 0,
    this.fh = 0,
    this.jl = 0,
    this.specialAttr = 0,
    this.specialAttr2 = 0,
  });

  /// The empty one.
  static const empty = PointsChangesValue();

  /// Parse a Discuz! `creditnotice` cookie value into a [PointsChangesValue].
  ///
  /// The value is ten `D`-separated segments: an unknown leading segment, 威望,
  /// 天使币, 宣传, 天然, 腹黑, 精灵, 福袋, 通关文牒 and the trailing uid. For
  /// example `0D1D1D0D0D0D0D0D0D2234424` is 威望 +1 and 天使币 +1. Returns null
  /// when the value is not in that shape.
  static PointsChangesValue? fromCreditNotice(String value) {
    final segments = value.split('D');
    if (segments.length != 10) {
      return null;
    }
    final ww = segments.elementAt(1).parseToInt();
    final tsb = segments.elementAt(2).parseToInt();
    final xc = segments.elementAt(3).parseToInt();
    final tr = segments.elementAt(4).parseToInt();
    final fh = segments.elementAt(5).parseToInt();
    final jl = segments.elementAt(6).parseToInt();
    final specialAttr = segments.elementAt(7).parseToInt();
    final specialAttr2 = segments.elementAt(8).parseToInt();
    if (ww == null || tsb == null || xc == null || tr == null || fh == null || jl == null || specialAttr == null) {
      return null;
    }
    return PointsChangesValue(
      ww: ww,
      tsb: tsb,
      xc: xc,
      tr: tr,
      fh: fh,
      jl: jl,
      specialAttr: specialAttr,
      specialAttr2: specialAttr2 ?? 0,
    );
  }

  /// 威望
  final int ww;

  /// 天使币
  final int tsb;

  /// 宣传
  final int xc;

  /// 天然
  final int tr;

  /// 腹黑
  final int fh;

  /// 精灵
  final int jl;

  /// Kind of attribute changes following seasons events.
  final int specialAttr;

  /// Another kind of attribute changes following seasons events.
  final int specialAttr2;
}

/// Cubit of user points changes events.
final class PointsChangesCubit extends Cubit<PointsChangesValue> {
  /// Constructor.
  PointsChangesCubit() : super(PointsChangesValue.empty);

  /// New points changes arrived.
  void recordsChanges(PointsChangesValue value) {
    if (value == PointsChangesValue.empty) {
      return;
    }
    // These are awards for individual actions, not a balance. Two replies can earn the same award;
    // reset the transient state so Cubit equality does not swallow the second notification.
    emit(PointsChangesValue.empty);
    emit(value);
  }
}

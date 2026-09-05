import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Repository of the forum's `hongbao` red packet plugin (`plugin.php?id=hongbao:ACTION`).
///
/// Every endpoint answers JSON and needs the login cookie; the thread page anti-theft sign is not involved.
final class RedPacketRepository {
  /// Constructor.
  const RedPacketRepository();

  static const _base = '$baseUrl/plugin.php?id=hongbao:';

  /// Url of the `open` endpoint.
  static String openUrl(String tid) => '${_base}open&tid=$tid';

  /// Url of the `record` endpoint.
  static String recordUrl(String tid) => '${_base}record&tid=$tid';

  /// Url of the `grab` endpoint.
  static const grabUrl = '${_base}grab';

  /// Url of the `daily` endpoint.
  static const dailyUrl = '${_base}daily';

  AsyncEither<Map<String, dynamic>> _json(AsyncEither<Response<dynamic>> request) => request.andThenHttp((resp) {
    final json = decodeJsonObject(resp.data);
    return json == null
        ? TaskEither<AppException, Map<String, dynamic>>.left(
            ServerRespondedErrorException('red packet api did not answer json'),
          )
        : TaskEither<AppException, Map<String, dynamic>>.right(json);
  });

  /// Ask the packet of thread [tid].
  AsyncEither<RedPacketOpenResult> open(String tid) =>
      _json(getIt.get<NetClientProvider>().get(openUrl(tid))).map(RedPacketOpenResult.fromJson);

  /// Claim a share of the packet in thread [tid]; [password] only for 口令 packets.
  AsyncEither<RedPacketGrabResult> grab({required String tid, required String formHash, String password = ''}) =>
      _json(
        getIt.get<NetClientProvider>().postForm(
          grabUrl,
          data: {'tid': tid, 'formhash': formHash, 'password': password},
        ),
      ).map(RedPacketGrabResult.fromJson);

  /// Ask the claimed shares of the packet in thread [tid].
  AsyncEither<RedPacketRecordsResult> records(String tid) =>
      _json(getIt.get<NetClientProvider>().get(recordUrl(tid))).map(RedPacketRecordsResult.fromJson);

  /// Claim today's daily red packet.
  AsyncEither<DailyRedPacketResult> claimDaily({required String formHash}) => _json(
    getIt.get<NetClientProvider>().postForm(dailyUrl, data: {'formhash': formHash}),
  ).map(DailyRedPacketResult.fromJson);
}

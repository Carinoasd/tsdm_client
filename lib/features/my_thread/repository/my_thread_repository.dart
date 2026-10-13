import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;

/// Repository of MyThread.
class MyThreadRepository {
  /// Fetch html document from [url].
  ///
  /// Asked in the JSON mode of the forum's app API, which answers the "my threads" pages (`do=thread`) since plugin
  /// 1.6.0 (roadmap item 3); an older plugin answers the web page, which parses the same.
  AsyncEither<uh.Document> fetchDocument(String url) =>
      getIt.get<NetClientProvider>().get(withTsdmAppJson(url)).mapHttp((v) => tsdmAppPageDocument(v.data));
}

import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/my_thread/utils/my_thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/list_preview.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Repository of MyThread.
class MyThreadRepository {
  /// Fetch the list page [url].
  ///
  /// Asked in the JSON mode of the forum's app API, which answers the "my threads" pages (`do=thread`) since plugin
  /// 1.6.0 (roadmap item 3). Plugin 2.4.0 answers them as structured fields (`schema: 9`, [myThreadApiAnswerOf]),
  /// kept as a [TsdmAppStructuredPage] for `myThreadsFromApi`; an older plugin answers the web page
  /// ([TsdmAppWebPage]), which parses as before. A list of threads (not the replies) asks for the previews of its rows
  /// too when they are wanted ([withTsdmAppListPreview], plugin 3.1.0).
  AsyncEither<TsdmAppPageAnswer> fetchPage(String url) => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppListPreview(withTsdmAppJson(url)))
      .mapHttpPageAnswer(myThreadApiAnswerOf);
}

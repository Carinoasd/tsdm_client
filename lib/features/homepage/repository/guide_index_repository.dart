import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/utils/parse_guide_index.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Fetches the modules of the forum guide index page shown on the homepage (GitHub #12).
class GuideIndexRepository {
  /// Constructor.
  const GuideIndexRepository();

  /// Fetch [guideIndexUrl] and parse its modules, in page order.
  ///
  /// A page without any module (guest landing on a login form, changed layout) is an empty list, not a failure.
  ///
  /// Asked in the JSON mode of the forum's app API, which answers the guide pages since plugin 1.6.0 (roadmap item 3):
  /// the homepage reads this page on every launch. An older plugin answers the web page, which parses the same.
  AsyncEither<List<GuideModule>> fetchGuideIndex() => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJson(guideIndexUrl))
      .mapHttp((v) => parseGuideIndex(tsdmAppPageDocument(v.data)));
}

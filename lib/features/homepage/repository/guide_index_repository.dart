import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/utils/parse_guide_index.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// Fetches the modules of the forum guide index page shown on the homepage (GitHub #12).
class GuideIndexRepository {
  /// Constructor.
  const GuideIndexRepository();

  /// Fetch [guideIndexUrl] and parse its modules, in page order.
  ///
  /// A page without any module (guest landing on a login form, changed layout) is an empty list, not a failure.
  AsyncEither<List<GuideModule>> fetchGuideIndex() => getIt
      .get<NetClientProvider>()
      .get(guideIndexUrl)
      .mapHttp((v) => parseGuideIndex(parseHtmlDocument(v.data as String)));
}

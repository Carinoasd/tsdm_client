import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/utils/guide_index_api.dart';
import 'package:tsdm_client/features/homepage/utils/parse_guide_index.dart';
import 'package:tsdm_client/features/latest_thread/utils/guide_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Fetches the modules of the forum guide index page shown on the homepage (GitHub #12).
class GuideIndexRepository {
  /// Constructor.
  const GuideIndexRepository();

  /// Fetch [guideIndexUrl] and parse its modules, in page order.
  ///
  /// A page without any module (guest landing on a login form, changed layout) is an empty list, not a failure; an
  /// answer without a page at all (an empty body) is one.
  ///
  /// Asked in the JSON mode of the forum's app API, which answers the guide pages since plugin 1.6.0 (roadmap item 3):
  /// the homepage reads this page on every launch. Plugin 2.4.0 answers the page as structured fields (`schema: 7`,
  /// [guideApiAnswerOf]), from which the modules are built ([guideModulesFromApi]); an older plugin answers the web
  /// page, which parses as before ([parseGuideIndex]).
  AsyncEither<List<GuideModule>> fetchGuideIndex() => fetchGuideIndexAnswer().map((e) => e.modules);

  /// [fetchGuideIndex] with the structured answer the modules were built from (null for the web page of an older
  /// plugin): the answer the homepage keeps for the next start (`GuideFeed`).
  AsyncEither<GuideIndexAnswer> fetchGuideIndexAnswer() => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJson(guideIndexUrl))
      .mapHttpPageAnswer(guideApiAnswerOf)
      .map(
        (answer) => switch (answer) {
          TsdmAppWebPage(:final document) => (modules: parseGuideIndex(document), json: null),
          TsdmAppStructuredPage(:final json) => (modules: guideModulesFromApi(json), json: json),
        },
      );
}

/// The modules of the guide index page and the structured answer they were built from, null for a web page.
typedef GuideIndexAnswer = ({List<GuideModule> modules, Map<String, dynamic>? json});

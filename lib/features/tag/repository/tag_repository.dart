import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/tag/models/forum_tag.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Repository of the tag cloud.
class TagRepository {
  /// Fetch the tags of the whole forum.
  ///
  /// The forum's app API has no answer for the tag pages: the web page is asked and parsed.
  AsyncEither<List<ForumTag>> fetchCloud() {
    return getIt.get<NetClientProvider>().get('$baseUrl/misc.php?mod=tag').mapHttpPage(parseTagCloud);
  }
}

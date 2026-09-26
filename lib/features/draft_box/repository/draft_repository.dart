import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Read-only access bound to one account's network client.
class DraftRepository {
  /// Injectable transport for deterministic tests.
  DraftRepository(this.getPage);

  /// Production transport.
  factory DraftRepository.network(NetClientProvider client) => DraftRepository(
    (url) async => switch (await client.get(url).run()) {
      Right(:final value) => value.data as String,
      Left(:final value) => throw value,
    },
  );

  /// No POST is performed by this repository.
  final Future<String> Function(String url) getPage;

  Future<uh.Document> _fetch(String url, int uid) async {
    final document = parseHtmlDocument(await getPage(url));
    if (uid <= 0 || parseLoggedUidFromDocument(document) != uid) {
      throw const FormatException('Draft login expired');
    }
    return document;
  }

  /// Fetch a validated page of drafts.
  Future<DraftPage> load(int uid, {int page = 1}) async => parseDraftPage(
    await _fetch(draftBoxUrl(page: page), uid),
    page: page,
    uid: uid,
  );

  /// Resolve an existing draft through GET only.
  Future<DraftEditTarget> resolve(DraftEntry entry, int uid) async =>
      parseDraftTarget(await _fetch(entry.url, uid), entry);
}

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// Account-bound access to a poll. No automatic POST retry or persisted forms.
class PollRepository {
  /// Inject transports in tests; production binds a client to the active identity.
  PollRepository({required this.getPage, required this.postForm});

  /// Build using the app's existing cookie, identity and error handling.
  factory PollRepository.network(NetClientProvider client) => PollRepository(
    getPage: (url) async => switch (await client.get(url).run()) {
      Right(:final value) => value.data as String,
      Left(:final value) => throw value,
    },
    postForm: (url, body) async => switch (await client.postForm(url, data: body).run()) {
      Right(:final value) => value.data as String,
      Left(:final value) => throw value,
    },
  );

  /// GET transport.
  final Future<String> Function(String url) getPage;

  /// POST transport. Indexed PHP array keys preserve every choice while keeping
  /// the string-valued map required by the Android Kotlin HTTP adapter.
  final Future<String> Function(String url, Map<String, String> body) postForm;

  /// Fetch a fresh form and verify which account the server rendered it for.
  Future<ForumPoll> fetch(String url, int? uid) async {
    final document = parseHtmlDocument(await getPage(url));
    final servedUid = parseLoggedUidFromDocument(document);
    if (servedUid != null && servedUid != uid) throw const FormatException('Poll identity changed');
    return parseForumPoll(document, loggedIn: uid != null && servedUid == uid);
  }

  /// Submit only the exact choices allowed by the latest form.
  ///
  /// The caller must refresh via GET afterwards even on error: a timed-out POST
  /// may have been accepted, and must never be retried automatically.
  Future<void> vote(ForumPoll poll, Set<String> choices) async {
    if (!poll.accepts(choices) || poll.action == null || poll.formHash == null) {
      throw const FormatException('Invalid poll selection');
    }
    final selected = choices.toList();
    final body = <String, String>{
      'formhash': poll.formHash!,
      'pollsubmit': 'true',
      for (var index = 0; index < selected.length; index++) 'pollanswers[$index]': selected[index],
    };
    // The response itself is not evidence of success. The next GET is authoritative.
    await postForm(poll.action!, body);
  }
}

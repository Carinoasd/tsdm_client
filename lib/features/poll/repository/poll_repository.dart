import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/models/poll_voters.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart' show currentLoginUid;
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Account-bound access to a poll. No automatic POST retry or persisted forms.
class PollRepository {
  /// Inject transports in tests; production binds a client to the active identity.
  PollRepository({required this.getPage, required this.postForm, this.getVoters, this.getVotersApi});

  /// Build using the app's existing cookie, identity and error handling.
  ///
  /// The poll's post is read in the JSON mode of the forum's app API (roadmap item 3): the `findpost` redirect is
  /// carried to the thread page. Its structured answer (plugin 2.1.0, `schema: 3`) gives the poll as fields since
  /// plugin 2.8.0 (`special`) and as the first floor's `poll_html` before ([pollOfApiAnswer]); an older plugin's
  /// answer, whose blocks hold the poll form and the `discuz_uid` the identity check reads, and the web page without
  /// the plugin are parsed as a page. A card in the thread page shows the poll of that page instead; it asks when it
  /// cannot, after a vote and after a login (see PollCard).
  ///
  /// An answer without a page (an empty body) fails the read ([fetchTsdmAppPageAnswer]) instead of being a page served
  /// to nobody, which the card would show as a poll to log in for.
  ///
  /// [currentUid] tells the account the voters page of the forum's app API is asked for (the account logged in now
  /// by default).
  factory PollRepository.network(NetClientProvider client, {int Function()? currentUid}) => PollRepository(
    getPage: (url) => fetchTsdmAppPageAnswer(client, url),
    getVoters: (url) async => switch (await client.get(url).run()) {
      Right(:final value) when value.data is String => value.data as String,
      Right(:final value) => throw HttpRequestFailedException(value.statusCode),
      Left(:final value) => throw value,
    },
    getVotersApi: (url) async => switch (await fetchTsdmAppV4Page(
      client,
      url,
      type: 'poll_voters',
      schema: 49,
      uid: (currentUid ?? currentLoginUid)(),
    ).run()) {
      Right(:final value) => value,
      Left(:final value) => throw value,
    },
    // The write result of the forum's app API (plugin 2.6.0) is read by [vote]; anything else is the forum's answer.
    postForm: (url, body) async => switch (await client.postForm(url, data: body).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
  );

  /// GET transport: the forum's answer, a page (text) or the JSON answer of the forum's app API.
  final Future<Object?> Function(String url) getPage;

  /// GET transport of the voters window (an ajax url, answered as xml text); null where voters are not read.
  final Future<String> Function(String url)? getVoters;

  /// GET transport of the voters page of the forum's app API (plugin 4.0.0, `poll_voters`, [fetchTsdmAppV4Page]): the
  /// answer read, null when it is not that page (the window is read then); null where it is not asked.
  final Future<TsdmAppV4Answer?> Function(String url)? getVotersApi;

  /// POST transport, the forum's answer. Indexed PHP array keys preserve every choice while keeping
  /// the string-valued map required by the Android Kotlin HTTP adapter.
  final Future<Object?> Function(String url, Map<String, String> body) postForm;

  /// Fetch a fresh form and verify which account the server rendered it for.
  Future<ForumPoll> fetch(String url, int? uid) async {
    final answer = await getPage(url);
    if (threadApiAnswerOf(answer) case final json?) {
      return pollOfApiAnswer(json, uid: uid);
    }
    final document = parseHtmlDocument(tsdmAppPageHtml(answer));
    return pollOfPage(document, servedUid: parseLoggedUidFromDocument(document), uid: uid);
  }

  /// Page [page] of the voters of option [optionId], from the poll's [votersUrl]. Throws [FormatException] when the
  /// url is not a voters page or the answer is not a voters window (the forum refused).
  ///
  /// Read from the forum's app API when it answers the page as fields (plugin 4.0.0: `thread_lists` names
  /// `poll_voters`, `type: poll_voters`, `schema` 49, [pollVotersPageFromApi]): the same voters, a next page while
  /// `page` is below `pages`. The forum's message (a poll whose voters only its starter sees…) and the plugin's
  /// `error: polloption` (an option that is not this poll's) throw as a window that is not the voters window does.
  /// Any other answer reads the window as before.
  Future<PollVotersPage> fetchVoters(String votersUrl, String optionId, {int page = 1}) async {
    final apiUrl = pollVotersApiPageUrl(votersUrl, optionId, page);
    final getApi = getVotersApi;
    if (apiUrl != null && getApi != null && TsdmAppV4.has(TsdmAppV4Group.threadLists, 'poll_voters')) {
      switch (await getApi(apiUrl)) {
        case TsdmAppV4Page(:final json):
          return pollVotersPageFromApi(json, optionId: optionId) ?? (throw const FormatException('Not this option'));
        case TsdmAppV4Message() || TsdmAppV4Refused():
          throw const FormatException('No voters window');
        case null:
          break;
      }
    }
    final url = pollVotersPageUrl(votersUrl, optionId, page);
    final get = getVoters;
    if (url == null || get == null) throw const FormatException('Invalid voters request');
    return parsePollVoters(await get(url)) ?? (throw const FormatException('No voters window'));
  }

  /// The poll of the structured thread page answer [json] ([threadApiAnswerOf]) for the account [uid] now in use:
  /// the page's `special` poll (plugin 2.8.0, [forumPollFromSpecial]), or the first floor's poll form (`poll_html`)
  /// before. Throws when the answer belongs to another account, as [pollOfPage]; the forum's message (no permission,
  /// log in) has no poll, as its page has no form.
  static ForumPoll pollOfApiAnswer(Map<String, dynamic> json, {required int? uid}) {
    final servedUid = threadApiViewerUid(json);
    if (servedUid != null && servedUid != uid) throw const FormatException('Poll identity changed');
    final loggedIn = uid != null && servedUid == uid;
    if (json['ok'] == 1) {
      final special = ThreadSpecial.fromApi(
        json['special'],
        formHash: tsdmAppText(json['formhash']),
        viewerUid: servedUid ?? 0,
        timeOffset: tsdmAppTimeOffset(json),
      );
      if (special is PollSpecial) {
        return forumPollFromSpecial(special, loggedIn: loggedIn);
      }
      final first = tsdmAppList(json['posts']).where((p) => tsdmAppInt(p['first']) == 1).firstOrNull;
      final form = tsdmAppText(first?['poll_html']);
      if (form.isNotEmpty) {
        return parseForumPoll(parseHtmlDocument(form), loggedIn: loggedIn);
      }
    }
    return parseForumPoll(parseHtmlDocument(''), loggedIn: loggedIn);
  }

  /// The poll of [document], a page the forum served to [servedUid] (null: a guest page, or one that does not say),
  /// for the account [uid] now in use. Throws when the page belongs to another account: its form and formhash are
  /// that account's.
  static ForumPoll pollOfPage(uh.Document document, {required int? servedUid, required int? uid}) {
    if (servedUid != null && servedUid != uid) throw const FormatException('Poll identity changed');
    return parseForumPoll(document, loggedIn: uid != null && servedUid == uid);
  }

  /// Submit only the exact choices allowed by the latest form.
  ///
  /// The caller must refresh via GET afterwards even on error: a timed-out POST
  /// may have been accepted, and must never be retried automatically.
  ///
  /// Returns the forum's verdict when the forum's app API (plugin 2.6.0) answered one ([tsdmAppWriteResultOf]): a vote
  /// taken (`thread_poll_succeed`, a redirect to the thread) or refused with the forum's message. Null for any other
  /// answer, which tells nothing: only the next GET does.
  Future<TsdmAppWriteResult?> vote(ForumPoll poll, Set<String> choices) async {
    if (!poll.accepts(choices) || poll.action == null || poll.formHash == null) {
      throw const FormatException('Invalid poll selection');
    }
    final selected = choices.toList();
    final body = <String, String>{
      'formhash': poll.formHash!,
      'pollsubmit': 'true',
      for (var index = 0; index < selected.length; index++) 'pollanswers[$index]': selected[index],
    };
    // Without the plugin's result the response itself is not evidence of success. The next GET is authoritative.
    return tsdmAppWriteResultOf(await postForm(poll.action!, body));
  }
}

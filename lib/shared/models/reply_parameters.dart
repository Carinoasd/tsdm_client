part of 'models.dart';

/// Model contains parameters to make a reply to:
///
/// * Thread.
/// * Post.
@MappableClass()
class ReplyParameters with ReplyParametersMappable {
  /// Constructor.
  const ReplyParameters({
    required this.fid,
    required this.tid,
    required this.postTime,
    required this.formHash,
    required this.subject,
    this.debate = false,
    this.debateStand,
    this.viewerUid,
    this.verification = false,
    this.secCheck,
  });

  /// Forum id.
  final String fid;

  /// Thread id.
  final String tid;

  /// Post time.
  final String? postTime;

  /// Form hash used in post request.
  final String formHash;

  /// Subject usually is an empty string.
  final String subject;

  /// The thread is a debate: a reply takes a side (`stand`: 0 neutral, 1 affirmative, 2 negative), as the forum's
  /// reply forms ask while the account took none.
  final bool debate;

  /// The side the account took in the debate with its first reply, as the forum tells it: 1 or 2 (the forum keeps it
  /// for every later reply), 0 none taken yet; null when the page does not tell (plugin 2.8.0: `reply.stand` on every
  /// debate page, or `special.reply_stand` on the first page only before it).
  final int? debateStand;

  /// The account the page was served to (the answer's `uid`), null for a guest or a page that does not say: the side
  /// of a debate belongs to it ([debateStand]).
  final int? viewerUid;

  /// The forum asks this account for a captcha or a security question to reply here, which only the website shows:
  /// the thread page said so (`reply.seccheck`, plugin 2.9.1; the placeholders of the quick reply form of the web
  /// page). The quick reply is then not sent from the app. False when the page does not tell, which does not mean the
  /// forum will not ask when the reply is posted (a site asking by the number of posts or their interval decides then).
  final bool verification;

  /// What the quick reply asks for, with the ids its answers go with, when the thread page told them ([verification]
  /// with the ids: `reply.seccheck` of plugin 2.9.1, the placeholders of the web page): the app asks them before
  /// sending. Null when nothing is asked, or the page did not tell the ids (the reply then needs the website).
  final SecCheck? secCheck;
}

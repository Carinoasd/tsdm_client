import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// How long a ban from posting can be chosen to last, in days; null is for ever (`banexpirynew` left empty).
const memberBanDays = <int?>[1, 3, 7, 30, null];

/// The hidden fields of the ban window sent back as they were served.
const memberBanServedFields = {'formhash', 'username', 'uid'};

/// The moderation panel's window banning member [memberUid] from posting, or lifting the ban
/// (`forum.php?mod=modcp&action=member&op=ban&uid=UID`, the website's 禁止用户 of a floor's author column), as served
/// to account [uid].
///
/// The forum bans a member site-wide (the user group 禁止发言, `bannew` 4) for some days (`banexpirynew`, empty for
/// ever), and lifts it by putting the member back where the member was (`bannew` 0); the radios it serves tell which
/// one the window offers. Banning from visiting (`bannew` 5) is never sent.
final class MemberBanForm {
  /// Constructor.
  const MemberBanForm({required this.memberUid, required this.uid, required this.fields, required this.banned});

  /// The member.
  final int memberUid;

  /// The account the window was served to.
  final int uid;

  /// The hidden fields served ([memberBanServedFields]).
  final Map<String, String> fields;

  /// The member is banned now (the window offers the normal state, `bannew` 0): sending it lifts the ban.
  final bool banned;

  /// The url the window is posted to.
  static String get submitUrl => '$baseUrl/forum.php?mod=modcp&action=member&op=ban';

  /// The url the window for member [memberUid] is asked at.
  static String windowUrl(int memberUid) => '$baseUrl/forum.php?mod=modcp&action=member&op=ban&uid=$memberUid';

  /// The window for member [memberUid] read from page [doc], served to [uid]; null when [doc] has none: no form
  /// posting to the ban with the member's uid among its hidden fields (the panel's search form has a uid too, but not
  /// hidden), a form hash missing, or neither the ban from posting nor its lifting offered.
  static MemberBanForm? parse(uh.Document doc, {required int memberUid, required int uid}) {
    for (final form in doc.querySelectorAll('form')) {
      if (!isMemberBanUrl(form.attributes['action'] ?? '')) {
        continue;
      }
      final fields = <String, String>{};
      for (final input in form.querySelectorAll('input[type="hidden"]')) {
        final name = input.attributes['name'] ?? '';
        if (memberBanServedFields.contains(name)) {
          fields[name] = input.attributes['value'] ?? '';
        }
      }
      if (fields['uid'] != '$memberUid') {
        continue;
      }
      if ((fields['formhash'] ?? '').isEmpty) {
        return null;
      }
      final choices = form
          .querySelectorAll('input[type="radio"][name="bannew"]')
          .map((e) => e.attributes['value'])
          .toSet();
      final banned = choices.contains('0');
      if (!banned && !choices.contains('4')) {
        return null;
      }
      return MemberBanForm(memberUid: memberUid, uid: uid, fields: fields, banned: banned);
    }
    return null;
  }

  /// The form body: the served fields, the ban from posting for [days] (null for ever) or its lifting when the member
  /// is [banned], and the [reason].
  Map<String, String> body({int? days, String reason = ''}) => {
    ...fields,
    'bannew': banned ? '0' : '4',
    'banexpirynew': banned || days == null ? '' : '$days',
    'reason': reason.trim(),
    'bansubmit': 'true',
  };
}

/// What the moderation panel answered when asked for the ban window of a member.
sealed class MemberBanWindow {
  const MemberBanWindow();
}

/// The window, ready to fill in.
final class MemberBanWindowReady extends MemberBanWindow {
  /// Constructor.
  const MemberBanWindowReady(this.form);

  /// The window.
  final MemberBanForm form;
}

/// The panel asks the moderator's password again (the first visit, or after an hour idle): its login form.
final class MemberBanNeedsLogin extends MemberBanWindow {
  /// Constructor.
  const MemberBanNeedsLogin({required this.formHash});

  /// The form hash of the login form.
  final String formHash;
}

/// The panel refused, in its own words [message] (no access to the panel, a member of a group that can not be banned
/// directly, an administrator); empty when it gave none.
final class MemberBanWindowRefused extends MemberBanWindow {
  /// Constructor.
  const MemberBanWindowRefused(this.message);

  /// The forum's message.
  final String message;
}

/// What the panel answered a ban sent.
sealed class MemberBanOutcome {
  const MemberBanOutcome();
}

/// The ban, or its lifting, was carried out; [message] is the forum's words ("用户资料成功更新"), empty when it gave
/// none.
final class MemberBanDone extends MemberBanOutcome {
  /// Constructor.
  const MemberBanDone(this.message);

  /// The forum's message.
  final String message;
}

/// The panel refused it, in its own words [message] (a reason is required, no permission); empty when the answer said
/// nothing the app can show.
final class MemberBanRefused extends MemberBanOutcome {
  /// Constructor.
  const MemberBanRefused(this.message);

  /// The forum's message.
  final String message;
}

/// The ban was sent, but the answer tells nothing of it (a redirect the forum does not answer a ban with: a proxy's,
/// the site's own); it may have been carried out.
final class MemberBanUnknown extends MemberBanOutcome {
  /// Constructor.
  const MemberBanUnknown();
}

/// The panel's session ended before the ban was sent: it answered its login form, and nothing was done.
final class MemberBanSessionEnded extends MemberBanOutcome {
  /// Constructor.
  const MemberBanSessionEnded({required this.formHash});

  /// The form hash of the login form.
  final String formHash;
}

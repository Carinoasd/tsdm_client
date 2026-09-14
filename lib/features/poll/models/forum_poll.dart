import 'package:tsdm_client/constants/url.dart';
import 'package:universal_html/html.dart' as uh;

/// Server-reported availability of an ordinary Discuz poll.
enum PollAvailability {
  /// The form accepts votes.
  available,

  /// A vote has already been recorded.
  voted,

  /// Voting has ended.
  closed,

  /// Authentication is required.
  loginRequired,

  /// This user cannot vote.
  denied,

  /// The form is not an ordinary supported poll.
  unsupported,
}

/// One option and its result, only when the server actually supplies it.
final class PollOption {
  /// Constructor.
  const PollOption({required this.label, this.id, this.result});

  /// Submission identifier; absent when the server doesn't offer a choice.
  final String? id;

  /// Original option text.
  final String label;

  /// Original visible result. Never inferred from missing markup.
  final String? result;
}

/// A snapshot of a poll, including a session-bound form that is never persisted.
final class ForumPoll {
  /// Constructor.
  const ForumPoll({
    required this.availability,
    this.options = const [],
    this.summary = '',
    this.deadline = '',
    this.notice = '',
    this.maxChoices,
    this.action,
    this.formHash,
  });

  /// Current permission/state.
  final PollAvailability availability;

  /// Options in forum order.
  final List<PollOption> options;

  /// Server description (selection limit, visibility, participants).
  final String summary;

  /// Server-provided closing time or remaining time.
  final String deadline;

  /// Privacy/permission notice from the form footer.
  final String notice;

  /// Maximum selected options. Null when unknown.
  final int? maxChoices;

  /// Validated same-origin vote action.
  final String? action;

  /// CSRF token from the same page/session.
  final String? formHash;

  /// Whether [ids] is a valid selection for this exact form.
  bool accepts(Set<String> ids) =>
      availability == PollAvailability.available &&
      ids.isNotEmpty &&
      maxChoices != null &&
      ids.length <= maxChoices! &&
      ids.every((id) => options.any((option) => option.id == id));
}

String _text(uh.Element? element) {
  if (element == null) return '';
  final clone = element.clone(true) as uh.Element;
  for (final node in clone.querySelectorAll('script, style, textarea, button, [hidden], .pollshare_box')) {
    node.remove();
  }
  return clone.text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
}

/// Parses the real X5 `form#poll` and fails closed on unknown form structures.
ForumPoll parseForumPoll(uh.Document document, {required bool loggedIn}) {
  final form = document.querySelector('form#poll');
  if (form == null) {
    return ForumPoll(availability: loggedIn ? PollAvailability.unsupported : PollAvailability.loginRequired);
  }
  final summary = _text(form.querySelector('.pinf'));
  final deadline = _text(form.querySelector('.ptmr'));
  final footer = form.querySelector('table')?.querySelectorAll('tr').lastOrNull;
  final notice = _text(footer).replaceFirst(RegExp(r'^提交\s*'), '');
  final inputs = form.querySelectorAll('input[name="pollanswers[]"]');
  final isSingle = inputs.isNotEmpty && inputs.every((e) => e.getAttribute('type') == 'radio');
  final maximum = isSingle ? 1 : int.tryParse(RegExp(r'最多可[选選]\s*(\d+)').firstMatch(summary)?.group(1) ?? '');
  final options = <PollOption>[];
  for (final cell in form.querySelectorAll('td.pvt')) {
    final row = cell.parent;
    final input = row?.querySelector('input[name="pollanswers[]"]');
    final resultRow = row?.nextElementSibling;
    final result = summary.contains('投票后结果可见') || resultRow?.querySelector('.pbg') == null
        ? null
        : _text(resultRow?.querySelectorAll('td').lastOrNull);
    options.add(PollOption(label: _text(cell), id: input?.getAttribute('value'), result: result));
  }
  final hash = form.querySelector('input[name="formhash"]')?.getAttribute('value');
  final rawAction = Uri.tryParse(form.getAttribute('action') ?? '');
  final uri = rawAction == null ? null : Uri.parse(baseUrl).resolveUri(rawAction);
  final validAction =
      uri != null &&
      uri.scheme == 'https' &&
      uri.origin == Uri.parse(baseUrl).origin &&
      uri.path == '/forum.php' &&
      uri.queryParameters['mod'] == 'misc' &&
      uri.queryParameters['action'] == 'votepoll' &&
      int.tryParse(uri.queryParameters['tid'] ?? '') != null &&
      uri.userInfo.isEmpty &&
      form.getAttribute('method')?.toLowerCase() == 'post' &&
      uri.queryParameters.keys.every({'mod', 'action', 'fid', 'tid', 'pollsubmit', 'quickforward'}.contains);
  final plain = '$deadline $notice';
  final PollAvailability availability;
  if (!loggedIn) {
    availability = PollAvailability.loginRequired;
  } else if (RegExp('已经投过票|已經投過票|您已投票|已经投票').hasMatch(plain)) {
    availability = PollAvailability.voted;
  } else if (RegExp('投票已.{0,4}(结束|結束|关闭|關閉)|投票已经过期').hasMatch(plain)) {
    availability = PollAvailability.closed;
  } else if (RegExp('没有投票权限|沒有投票權限|无权|無權').hasMatch(plain)) {
    availability = PollAvailability.denied;
  } else if (validAction &&
      hash != null &&
      hash.isNotEmpty &&
      maximum != null &&
      maximum > 0 &&
      inputs.isNotEmpty &&
      inputs.length == options.length &&
      inputs.every((e) => !e.hasAttribute('disabled') && ['radio', 'checkbox'].contains(e.getAttribute('type'))) &&
      options.every((e) => int.tryParse(e.id ?? '') != null && e.label.isNotEmpty) &&
      form.querySelector('#pollsubmit') != null) {
    // X5 disables the submit button until a choice is made; it is not a permission flag.
    availability = PollAvailability.available;
  } else {
    availability = PollAvailability.unsupported;
  }
  return ForumPoll(
    availability: availability,
    options: List.unmodifiable(options),
    summary: summary,
    deadline: deadline,
    notice: notice,
    maxChoices: maximum,
    action: validAction ? uri.toString() : null,
    formHash: hash,
  );
}

import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/purchase/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// Repository of purchasing.
final class PurchaseRepository with LoggerMixin {
  /// Constructor; [currentUid] tells the account a window is asked for (the logged in account by default).
  PurchaseRepository({int Function()? currentUid}) : _currentUid = currentUid ?? currentLoginUid;

  final int Function() _currentUid;

  // Keep the same host as every other request: the forum's cookies are
  // host-only (bound to `www.tsdm39.com`), so the bare `tsdm39.com` host would
  // be treated as a guest and the purchase would fail.
  static const _purchaseTarget = '$baseUrl/forum.php?mod=misc&action=pay&paysubmit=yes&infloat=yes&inajax=1';

  /// Parse the purchase confirm dialog.
  ///
  /// The response is an ajax xml document with html wrapped in CDATA:
  ///
  /// ```html
  /// <form id="payform" ...>
  ///   <input type="hidden" name="formhash" value="${FORM_HASH}" />
  ///   <input type="hidden" name="referer" value="${REFERER}" />
  ///   <input type="hidden" name="tid" value="${TID}" />
  ///   <input type="hidden" name="handlekey" value="pay" />
  ///   <table class="list">
  ///     <tr><th>作者</th><td><a href="home.php?mod=space&uid=${UID}">${AUTHOR}</a></td></tr>
  ///     <tr><th>售价(天使币)</th><td>${PRICE} </td></tr>
  ///     <tr><th>作者所得(天使币)</th><td>${AUTHOR_PROFIT} </td></tr>
  ///     <tr><th>购买后余额(天使币)</th><td>${COINS_LAST} </td></tr>
  ///   </table>
  /// </form>
  /// ```
  ///
  /// With the forum's app API (plugin 2.6.0) [data] is its write result ([tsdmAppWriteResultOf]): the dialog as a
  /// `page`, the forum's refusal (bought already, not logged in…) as a `handle` or `message` without a form.
  static Either<AppException, PurchaseConfirmInfo> _parsePurchaseDialog(Object? data, {required String tid}) {
    final result = tsdmAppWriteResultOf(data);
    if (result != null && result.kind != TsdmAppWriteKind.page) {
      return left(PurchaseInfoInvalidNoticeException());
    }
    final text = tsdmAppAnswerText(data);
    String? htmlData;
    if (result == null) {
      try {
        htmlData = parseXmlDocument(text).documentElement?.nodes.firstOrNull?.text;
      } on Object catch (_) {
        // Not xml, maybe a plain html document (the xml parser throws a state error on a whole page).
        htmlData = null;
      }
    }
    final doc = result?.document ?? parseHtmlDocument(htmlData ?? text);
    final formNode = doc.querySelector('form#payform') ?? doc.querySelector('form');
    if (formNode == null) {
      final errorText = doc.querySelector('div.alert_error')?.innerText.trim();
      if (errorText != null && errorText.isNotEmpty) {
        return left(PurchaseInfoInvalidNoticeException());
      }
      return left(PurchaseInfoInvalidParameterCountException());
    }

    String? inputValue(String name) => formNode.querySelector('input[name="$name"]')?.attributes['value'];
    final formHash = inputValue('formhash');
    final referer = inputValue('referer');
    final tidInDialog = inputValue('tid');
    final handleKey = inputValue('handlekey');
    if (formHash == null || referer == null || tidInDialog == null || handleKey == null) {
      return left(PurchaseInfoIncompleteException());
    }

    // Rows in table.
    final rows = formNode.querySelectorAll('table.list tr').map((tr) {
      final th = tr.querySelector('th')?.innerText.trim() ?? '';
      final td = tr.querySelector('td');
      return (th, td);
    }).toList();
    final firstNumber = RegExp(r'\d+');
    String? author;
    String? price;
    String? authorProfit;
    String? coinsLast;
    for (final (th, td) in rows) {
      if (td == null) {
        continue;
      }
      final number = firstNumber.firstMatch(td.innerText)?.group(0);
      if (th.startsWith('作者所得')) {
        authorProfit = number;
      } else if (th.startsWith('购买后余额')) {
        coinsLast = number;
      } else if (th.startsWith('售价')) {
        price = number;
      } else if (th.startsWith('作者')) {
        author = td.querySelector('a')?.innerText.trim() ?? td.innerText.trim();
      }
    }
    // Fallback to row positions if headers are unrecognized.
    if (rows.length >= 4 && author == null && price == null && authorProfit == null && coinsLast == null) {
      author = rows[0].$2?.innerText.trim();
      price = firstNumber.firstMatch(rows[1].$2?.innerText ?? '')?.group(0);
      authorProfit = firstNumber.firstMatch(rows[2].$2?.innerText ?? '')?.group(0);
      coinsLast = firstNumber.firstMatch(rows[3].$2?.innerText ?? '')?.group(0);
    }

    return right(
      PurchaseConfirmInfo(
        author: author,
        price: price,
        authorProfit: authorProfit,
        coinsLast: coinsLast,
        formHash: formHash,
        referer: referer,
        tid: tidInDialog.isNotEmpty ? tidInDialog : tid,
        handleKey: handleKey,
      ),
    );
  }

  /// The purchase window of the forum's app API (plugin 3.0.0, `type: form`, `form: buy`) [form] for thread [tid]:
  /// the author, the price, what the author gets and the balance after buying as the forum printed them (`price`,
  /// `net`, `balance`, which may be negative), and the form as served. Null when the answer misses what a purchase
  /// needs (a form hash, a target that is not the pay url, another thread): the window is then read as before.
  static PurchaseConfirmInfo? purchaseConfirmInfoFromApi(SmallFormFields form, {required String tid}) {
    final json = form.json;
    final fields = form.submitFields;
    final url = form.submitUrl('forum.php', const {'mod': 'misc', 'action': 'pay', 'paysubmit': 'yes'});
    final formHash = fields['formhash'] ?? '';
    final served = tsdmAppInt(json['tid']);
    final price = json['price'];
    final net = json['net'];
    final balance = json['balance'];
    if (url == null ||
        formHash.isEmpty ||
        served <= 0 ||
        '$served' != tid ||
        fields['tid'] != tid ||
        price is! num ||
        net is! num ||
        balance is! num) {
      return null;
    }
    return PurchaseConfirmInfo(
      author: tsdmAppText(tsdmAppMap(json['author'])['name']),
      price: '$price',
      authorProfit: '$net',
      coinsLast: '$balance',
      formHash: formHash,
      referer: fields['referer'] ?? '',
      tid: tid,
      handleKey: fields['handlekey'] ?? '',
      submitUrl: url,
      submitFields: fields,
    );
  }

  /// Fetch confirm info before purchase post [pid] in thread [tid].
  ///
  /// MUST call this function before purchase.
  ///
  /// The window is asked as a small form of the forum's app API ([withTsdmAppForm], plugin 3.0.0): the form as
  /// structured fields ([purchaseConfirmInfoFromApi]) or the forum's message instead of it (bought already, not enough
  /// credits, the login prompt: [PurchaseRefusedException] with the forum's text), served to the account that asked
  /// ([_currentUid]) or never used. An older plugin answers the window as its write result and the forum without the
  /// plugin its AJAX fragment, parsed as before; a form the plugin could not tell, or with fields the app does not
  /// know, is asked again the way it always was.
  AsyncEither<PurchaseConfirmInfo> fetchPurchaseConfirmInfo({required String tid, required String pid}) => AsyncEither(
    () async {
      final url = formatPurchaseDialogUrl(tid, pid);
      final uid = _currentUid();
      final respEither = await getIt.get<NetClientProvider>().get(withTsdmAppForm(url)).run();
      if (respEither.isLeft()) {
        return left(respEither.unwrapErr());
      }
      final resp = respEither.unwrap();
      if (resp.statusCode != HttpStatus.ok) {
        // Network error.
        error('fetch purchase dialog failed: code${resp.statusCode}');
        return left(HttpRequestFailedException(resp.statusCode));
      }
      switch (smallFormAnswerOf(resp.data, SmallFormKind.buy)) {
        case final SmallFormAnswer answer when answer.identityProblem(uid) != null:
          return left(PurchaseRefusedException(answer.identityProblem(uid)!));
        case final SmallFormMessage message:
          return left(
            message.reason.isNotEmpty ? PurchaseRefusedException(message.reason) : PurchaseInfoInvalidNoticeException(),
          );
        case final SmallFormFields form when form.usable:
          if (purchaseConfirmInfoFromApi(form, tid: tid) case final info?) {
            return right(info);
          }
          return _fetchAsBefore(url, tid: tid);
        case SmallFormFields():
          return _fetchAsBefore(url, tid: tid);
        case null when isSmallFormUnknown(resp.data):
          return _fetchAsBefore(url, tid: tid);
        case null:
          break;
      }
      final result = _parsePurchaseDialog(resp.data, tid: tid);
      if (result.isLeft()) {
        error('parse purchase dialog failed: ${result.unwrapErr()}');
      }
      return result;
    },
  );

  /// The window [url] asked as before plugin 3.0.0 (the write result of plugin 2.6.0, or the AJAX fragment).
  Future<Either<AppException, PurchaseConfirmInfo>> _fetchAsBefore(String url, {required String tid}) async {
    final respEither = await getIt.get<NetClientProvider>().get(withTsdmAppJsonWrite(url)).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }
    return _parsePurchaseDialog(resp.data, tid: tid);
  }

  /// Purchase with given parameters.
  ///
  /// The forum's app API (plugin 2.6.0) answers the result as JSON ([tsdmAppWriteResultOf]): the success hook
  /// (`thread_pay_succeed`, "购买成功") is the success, anything else failed; an older plugin answers the AJAX
  /// fragment, read as before.
  ///
  /// A window of the forum's app API (plugin 3.0.0, [PurchaseConfirmInfo.submitFields]) posts what it served to
  /// its `submit.url` with `inajax=1`, as the website does. A refusal carries the forum's message
  /// ([PurchaseActionFailedException.reason]); "bought already" (`credits_buy_thread`) is a success.
  ///
  /// Sent once, never retried by the transport (a purchase moves credits).
  AsyncVoidEither purchase(PurchaseConfirmInfo info) => AsyncVoidEither(() async {
    final served = info.submitFields;
    final target = info.submitUrl;
    final body = served != null && target != null
        ? served
        : {'formhash': info.formHash, 'referer': info.referer, 'tid': info.tid, 'handlekey': info.handleKey};
    final url = served != null && target != null ? withSmallFormInAjax(target) : _purchaseTarget;
    final respEither = await getIt.get<NetClientProvider>().postForm(url, data: body, singleAttempt: true).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }

    if (tsdmAppWriteResultOf(resp.data) case final result?) {
      // Told by the language key, not by the words: `thread_pay_succeed`, or `credits_buy_thread` (bought already:
      // an earlier send of this purchase went through), which shows the thread the same way.
      final bought =
          (result.kind == TsdmAppWriteKind.handle && result.succeeded) ||
          result.messageKey == 'thread_pay_succeed' ||
          result.messageKey == 'credits_buy_thread';
      if (bought) {
        return rightVoid();
      }
      return left(
        PurchaseActionFailedException(reason: result.reason.isNotEmpty ? result.reason : null),
      );
    }
    if (!(resp.data is String && (resp.data as String).contains('购买成功'))) {
      return left(PurchaseActionFailedException());
    }
    return rightVoid();
  });
}

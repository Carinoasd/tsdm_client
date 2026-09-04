import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/purchase/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// Repository of purchasing.
final class PurchaseRepository with LoggerMixin {
  static const _purchaseTarget = 'https://tsdm39.com/forum.php?mod=misc&action=pay&paysubmit=yes&infloat=yes&inajax=1';

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
  static Either<AppException, PurchaseConfirmInfo> _parsePurchaseDialog(String data, {required String tid}) {
    String? htmlData;
    try {
      htmlData = parseXmlDocument(data).documentElement?.nodes.firstOrNull?.text;
    } on Exception catch (_) {
      // Not xml, maybe a plain html document.
      htmlData = null;
    }
    final doc = parseHtmlDocument(htmlData ?? data);
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

  /// Fetch confirm info before purchase post [pid] in thread [tid].
  ///
  /// MUST call this function before purchase.
  AsyncEither<PurchaseConfirmInfo> fetchPurchaseConfirmInfo({required String tid, required String pid}) =>
      AsyncEither(() async {
        final respEither = await getIt.get<NetClientProvider>().get(formatPurchaseDialogUrl(tid, pid)).run();
        if (respEither.isLeft()) {
          return left(respEither.unwrapErr());
        }
        final resp = respEither.unwrap();
        if (resp.statusCode != HttpStatus.ok) {
          // Network error.
          error('fetch purchase dialog failed: code${resp.statusCode}');
          return left(HttpRequestFailedException(resp.statusCode));
        }
        final result = _parsePurchaseDialog(resp.data as String, tid: tid);
        if (result.isLeft()) {
          error('parse purchase dialog failed: ${result.unwrapErr()}');
        }
        return result;
      });

  /// Purchase with given parameters.
  AsyncVoidEither purchase({
    required String formHash,
    required String referer,
    required String tid,
    required String handleKey,
  }) => AsyncVoidEither(() async {
    final body = {'formhash': formHash, 'referer': referer, 'tid': tid, 'handlekey': handleKey};
    final respEither = await getIt.get<NetClientProvider>().postForm(_purchaseTarget, data: body).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }

    if (!(resp.data as String).contains('购买成功')) {
      return left(PurchaseActionFailedException());
    }
    return rightVoid();
  });
}

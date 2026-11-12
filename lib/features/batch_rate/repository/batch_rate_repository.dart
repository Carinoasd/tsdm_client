import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What the forum answered a batch rate request with.
sealed class BatchRateReply<T> {
  const BatchRateReply();
}

/// The answer read.
final class BatchRateAnswered<T> extends BatchRateReply<T> {
  /// Constructor.
  const BatchRateAnswered(this.value);

  /// The answer.
  final T value;
}

/// The plugin refused, with its sentence (`error: message`, no language key); or the forum asks to log in.
final class BatchRateRefused<T> extends BatchRateReply<T> {
  /// Constructor.
  const BatchRateRefused(this.message, {this.login = false});

  /// The plugin's sentence, as served; empty when there is none.
  final String message;

  /// The forum asks to log in.
  final bool login;
}

/// No answer could be read (a failed request, a page that is not the plugin's JSON): nothing is known of a write.
final class BatchRateFailed<T> extends BatchRateReply<T> {
  /// Constructor.
  const BatchRateFailed();
}

/// Asks `batchrate` of the forum's app API and reads and posts the batch rate plugin's own pages (with `tsdmapp=json`),
/// bound to the account logged in: an answer served to another account is dropped ([IdentityChangedException]), and
/// nothing is sent once the account changed. Every write is sent once (no transport retry, no retry here).
class BatchRateRepository {
  /// Transports are injected so the pages are tested without a forum.
  BatchRateRepository({required this.ask, required this.get, required this.post, int Function()? currentUid})
    : _currentUid = currentUid ?? currentLoginUid;

  /// Uses the account-bound [client].
  factory BatchRateRepository.network(NetClientProvider client) => BatchRateRepository(
    ask: (query) => TsdmAppApi.askWaiting(client, 'batchrate', query),
    // A GET follows a redirect: running on a batch already done answers the result's page that way.
    get: (url) async => switch (await client.get(withTsdmAppJson(url)).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
    // One attempt: a write is never sent twice. `tsdmapp=json` is added by `postForm`.
    post: (url, data) async => switch (await client.postForm(url, data: data, singleAttempt: true).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
  );

  /// Ask `batchrate` with the query given; null when it can not answer.
  final Future<Map<String, dynamic>?> Function(Map<String, String> query) ask;

  /// GET a page of the plugin (`tsdmapp=json` added); the answer as it came.
  final Future<Object?> Function(String url) get;

  /// POST a form once; the answer as it came.
  final Future<Object?> Function(String url, Map<String, String> data) post;

  final int Function() _currentUid;

  /// The account in use, checked before a request is sent.
  int _uid() {
    final uid = _currentUid();
    if (uid <= 0) {
      throw IdentityChangedException();
    }
    return uid;
  }

  /// [json] was served to [uid], still the account in use; else the answer is dropped.
  void _check(Map<String, dynamic> json, int uid) {
    final served = tsdmAppInt(json['uid']);
    if ((served > 0 && served != uid) || _currentUid() != uid) {
      throw IdentityChangedException();
    }
  }

  /// [data] read with [parse], the plugin's refusal, or a failure.
  BatchRateReply<T> _read<T>(Object? data, int uid, T? Function(Map<String, dynamic> json) parse) {
    final json = tsdmAppAnswerJson(data);
    if (json == null) {
      return const BatchRateFailed();
    }
    _check(json, uid);
    if (json['ok'] != 1) {
      return switch (json['error']) {
        'message' => BatchRateRefused(tsdmAppText(json['message']), login: json['login'] == 1),
        'login' => const BatchRateRefused('', login: true),
        _ => const BatchRateFailed(),
      };
    }
    return switch (parse(json)) {
      final T value => BatchRateAnswered(value),
      null => const BatchRateFailed(),
    };
  }

  Future<BatchRateReply<T>> _getPage<T>(String url, T? Function(Map<String, dynamic> json) parse) async {
    final uid = _uid();
    final Object? data;
    try {
      data = await get(url);
    } on IdentityChangedException {
      rethrow;
    } on Exception {
      return const BatchRateFailed();
    }
    return _read(data, uid, parse);
  }

  Future<BatchRateReply<T>> _post<T>(
    String url,
    Map<String, String> body,
    T? Function(Map<String, dynamic> json) parse,
  ) async {
    final uid = _uid();
    final Object? data;
    try {
      data = await post(url, body);
    } on IdentityChangedException {
      rethrow;
    } on Exception {
      return const BatchRateFailed();
    }
    return _read(data, uid, parse);
  }

  /// What the account may do in forum [fid] (thread [tid]); without [fid], only whether it may read the batches.
  Future<BatchRateInfo?> info({int? fid, int? tid}) async {
    final uid = _uid();
    final json = await ask({if (fid != null) 'fid': '$fid', if (tid != null) 'tid': '$tid'});
    if (json == null) {
      return null;
    }
    _check(json, uid);
    return BatchRateInfo.fromJson(json);
  }

  /// The confirmation of [selection] with the forum's defaults, posted to [info]'s form.
  Future<BatchRateReply<BatchRateConfirm>> confirm(BatchRateInfo info, BatchRateSelection selection) async {
    final url = info.confirmUrl;
    if (url == null) {
      return const BatchRateFailed();
    }
    return _post(url, {'formhash': info.formHash, ...selection.fields}, BatchRateConfirm.fromJson);
  }

  /// [confirm] computed again with [settings].
  Future<BatchRateReply<BatchRateConfirm>> recalc(BatchRateConfirm confirm, BatchRateSettings settings) =>
      _post(confirm.submit.url, settings.fields(confirm, submit: false), BatchRateConfirm.fromJson);

  /// Send [confirm] with [settings], once: the batch made ([BatchRateBatchPage], to be run), or the confirmation again
  /// with the plugin's reasons when its checks failed.
  Future<BatchRateReply<BatchRatePosted>> submit(BatchRateConfirm confirm, BatchRateSettings settings) => _post(
    confirm.submit.url,
    settings.fields(confirm, submit: true),
    (json) => BatchRateBatchPage.fromJson(json) ?? BatchRateConfirm.fromJson(json),
  );

  /// The answer of a run or a taking back in [data] (a write result, `kind: handle`, [handleKey]).
  BatchRateReply<BatchRateStep> _step(Object? data, int uid, String handleKey) {
    final result = tsdmAppWriteResultOf(data);
    if (result == null) {
      // The plugin's own JSON when the forum's app API did not classify it.
      final json = tsdmAppAnswerJson(data);
      if (json != null && json['type'] == null && json.containsKey('ok') && json['ok'] is bool) {
        if (_currentUid() != uid) {
          throw IdentityChangedException();
        }
        final ok = json['ok'] == true;
        return BatchRateAnswered(_stepOf(ok, {for (final e in json.entries) e.key: '${e.value}'}));
      }
      return _read<BatchRateStep>(data, uid, (_) => null);
    }
    if ((result.uid > 0 && result.uid != uid) || _currentUid() != uid) {
      throw IdentityChangedException();
    }
    if (result.login) {
      return BatchRateRefused(result.message, login: true);
    }
    if (result.kind != TsdmAppWriteKind.handle || result.handleKey != handleKey) {
      return result.message.isEmpty ? const BatchRateFailed() : BatchRateRefused(result.message);
    }
    return BatchRateAnswered(_stepOf(result.ok, {...result.values, 'error': result.message}));
  }

  static BatchRateStep _stepOf(bool ok, Map<String, String> v) {
    int n(String k) => int.tryParse(v[k] ?? '') ?? 0;
    final finished = v['finished'];
    return (
      ok: ok,
      done: n('done'),
      total: n('total'),
      remaining: int.tryParse(v['remaining'] ?? ''),
      finished: ok && (finished == '1' || finished == 'true'),
      message: ok ? '' : (v['error'] ?? ''),
    );
  }

  Future<BatchRateReply<BatchRateStep>> _postStep(BatchRateForm form, Map<String, String> extra, String key) async {
    final uid = _uid();
    final Object? data;
    try {
      data = await post(form.url, form.body(extra));
    } on IdentityChangedException {
      rethrow;
    } on Exception {
      return const BatchRateFailed();
    }
    return _step(data, uid, key);
  }

  /// Run one part of batch [batchId] with [form] (the batch's `run`), once.
  Future<BatchRateReply<BatchRateStep>> run(BatchRateForm form, int batchId) =>
      _postStep(form, {'batchid': '$batchId'}, 'batchrate_run');

  /// Take the rate of item [itemId] back with [form], once.
  Future<BatchRateReply<BatchRateStep>> undoItem(BatchRateForm form, int itemId) =>
      _postStep(form, {'itemid': '$itemId'}, 'batchrate_undo_item');

  /// Take one part of batch [batchId] back with [form], once.
  Future<BatchRateReply<BatchRateStep>> undoBatch(BatchRateForm form, int batchId) =>
      _postStep(form, {'batchid': '$batchId'}, 'batchrate_undo_batch');

  /// A batch's page at [url] (its result, its detail, running it on).
  Future<BatchRateReply<BatchRateBatchPage>> batchPage(String url) => _getPage(url, BatchRateBatchPage.fromJson);

  /// The detail of batch [batchId] (the batches' page at [listUrl]).
  Future<BatchRateReply<BatchRateBatchPage>> detail(String listUrl, int batchId) =>
      batchPage('${_base(listUrl)}&bract=detail&batchid=$batchId');

  /// Run batch [batchId] on (the batches' page at [listUrl]): to run ([BatchRateBatchPage.run]), or its result when it
  /// is done.
  Future<BatchRateReply<BatchRateBatchPage>> resume(String listUrl, int batchId) =>
      batchPage('${_base(listUrl)}&bract=continue&batchid=$batchId');

  /// Page [page] of the batches at [listUrl].
  Future<BatchRateReply<BatchRateBatches>> list(String listUrl, {int page = 1}) =>
      _getPage(page > 1 ? '${_base(listUrl)}&page=$page' : _base(listUrl), BatchRateBatches.fromJson);

  /// The detail of batch [batchId] in the plugin's batches page.
  static String? detailUrlOf(int batchId) =>
      BatchRateForm.urlOf('plugin.php?id=batchrate:list&bract=detail&batchid=$batchId');

  /// [listUrl] without the parameters of a page or a batch.
  static String _base(String listUrl) => Uri.parse(listUrl).replace(query: 'id=batchrate:list').toString();
}

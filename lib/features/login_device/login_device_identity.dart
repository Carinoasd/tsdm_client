import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:uuid/uuid.dart';

/// The id of this app installation the forum's app API keeps the logins by (plugin 3.6.0, the `device` action): a
/// random UUID made once and stored on this device, the same for every account, sent in [header] with the requests to
/// the forum ([LoginDeviceInterceptor]) once `status` said the plugin keeps devices ([TsdmAppApi.knowsDevice]).
///
/// A new one is made when the forum answers that this device was logged out of an account ([renew]): the old one is
/// logged out for that account for good. Not in a backup ([storageKey] is dropped from an export) nor in the
/// cross-device sync: two installations with the same id would be logged out together.
abstract final class LoginDeviceIdentity {
  /// The header carrying [id].
  static const header = 'X-Tsdmapp-Device';

  /// Name of the settings row holding [id].
  static const storageKey = 'loginDeviceId';

  static final _format = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  /// Whether [value] is an id as the plugin takes it (a UUID, lower case as the plugin stores it).
  static bool isValid(String value) => _format.hasMatch(value);

  static String? _id;

  /// The id, null until [load] ran (an isolate that never loads it, the tests: no header is sent). Set by the tests.
  static String? get id => _id;

  @visibleForTesting
  static set id(String? value) => _id = value;

  /// Called with the account and the id of every answer `device_revoked` that names an account
  /// ([LoginDeviceInterceptor]); set by the `LoginDeviceCoordinator` of the app, which tells the answers of the ids
  /// this device used apart (the id in use, and those it replaced in this run) and each account once.
  static void Function(int uid, String device)? onRevoked;

  static final _retired = <String>{};

  /// Whether [device] is the id in use, or one [renew] replaced in this run: the answers of the requests in flight
  /// when it was replaced still name it, for every account they were sent as.
  static bool isOwn(String device) => device == _id || _retired.contains(device);

  /// Read the stored id, or make one and store it.
  static Future<void> load(StorageProvider storage) async {
    final stored = (await storage.getString(storageKey))?.toLowerCase();
    if (stored != null && isValid(stored)) {
      _id = stored;
      return;
    }
    await renew(storage);
  }

  /// Make a new id, in use at once, and store it.
  static Future<String> renew(StorageProvider storage) async {
    final next = const Uuid().v4().toLowerCase();
    if (_id case final previous?) {
      _retired.add(previous);
    }
    _id = next;
    await storage.saveString(storageKey, next);
    return next;
  }
}

/// The account and the device of an answer `{"ok":0,"error":"device_revoked","uid":…,"device":"…"}` (plugin 3.6.0),
/// null for any other answer [data]: a JSON object dio decoded, or text (the Android client, a plain response).
///
/// Text is only decoded when it is a JSON object that names the error: the pages of the forum are never decoded here.
({int uid, String device})? loginDeviceRevokedOf(Object? data) {
  Map<dynamic, dynamic>? json;
  if (data is Map) {
    json = data;
  } else if (data is String && data.trimLeft().startsWith('{') && data.contains('"device_revoked"')) {
    try {
      final decoded = jsonDecode(data);
      json = decoded is Map ? decoded : null;
    } on FormatException {
      json = null;
    }
  }
  if (json == null || json['ok'] != 0 || json['error'] != 'device_revoked') {
    return null;
  }
  final device = json['device'];
  return (uid: tsdmAppInt(json['uid']), device: device is String ? device.toLowerCase() : '');
}

/// Sends [LoginDeviceIdentity.id] in [LoginDeviceIdentity.header] with every request to the forum while the plugin
/// keeps devices ([TsdmAppApi.knowsDevice]), and turns an answer `device_revoked` into a failed request
/// ([LoginDeviceRevokedException]): the forum did not handle it, and the answer is no page any reader knows.
///
/// A request that sets the header itself keeps it (the `register` names the id it registers). Every answer naming an
/// account is told to [LoginDeviceIdentity.onRevoked], which decides what to do of it; nothing waits here: the logout
/// runs on its own.
final class LoginDeviceInterceptor extends Interceptor with LoggerMixin {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final id = LoginDeviceIdentity.id;
    final host = options.uri.host;
    if (id != null &&
        TsdmAppApi.knowsDevice &&
        (host == baseHost || host == baseHostAlt) &&
        !options.headers.keys.any((k) => k.toLowerCase() == LoginDeviceIdentity.header.toLowerCase())) {
      options.headers[LoginDeviceIdentity.header] = id;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final revoked = loginDeviceRevokedOf(response.data);
    if (revoked == null) {
      handler.next(response);
      return;
    }
    warning('the forum answered that this device was logged out of the account: ${response.requestOptions.uri.path}');
    if (revoked.uid > 0 && revoked.device.isNotEmpty) {
      LoginDeviceIdentity.onRevoked?.call(revoked.uid, revoked.device);
    }
    handler.reject(
      DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: LoginDeviceRevokedException(revoked.uid),
        message: 'device logged out of the account',
      ),
    );
  }
}

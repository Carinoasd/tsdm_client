import 'dart:async';

import 'package:tsdm_client/features/login_device/models/login_device.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What the `device` action answered.
sealed class LoginDeviceResult<T> {
  const LoginDeviceResult();
}

/// Done: [value] is the list, or the device written.
final class LoginDeviceDone<T> extends LoginDeviceResult<T> {
  /// Constructor.
  const LoginDeviceDone(this.value);

  /// The answer's value.
  final T value;
}

/// The forum keeps no devices: an older plugin, the table missing, the forum's switch off (`supported: 0`).
final class LoginDeviceUnsupported<T> extends LoginDeviceResult<T> {
  /// Constructor.
  const LoginDeviceUnsupported();
}

/// Not done: [error] is the plugin's (`login`, `nodevice`, `notrevoked`, `busy`…), empty for a failed request.
final class LoginDeviceFailed<T> extends LoginDeviceResult<T> {
  /// Constructor.
  const LoginDeviceFailed(this.error);

  /// The plugin's error.
  final String error;
}

/// The devices of an account, through the forum's app API (plugin 3.6.0, `plugin.php?id=tsdmapp:api&action=device`).
///
/// Every call is for one account ([NetClientProvider.build] bound to it): once another account is in use its answer is
/// dropped and the call fails. The writes (`register`, `revoke`, `remove`) carry the form hash of the session and are
/// sent once; an answer "too soon" (HTTP 429, the plugin takes one write per account every few seconds, a `register`
/// and a `revoke` alike) is waited for and the write sent again, which the plugin did not handle.
final class LoginDeviceRepository with LoggerMixin {
  /// Constructor; [buildClient] builds the client of an account (the tests).
  LoginDeviceRepository({NetClientProvider Function(int uid)? buildClient}) : _buildClient = buildClient ?? _clientOf;

  static NetClientProvider _clientOf(int uid) =>
      NetClientProvider.build(userLoginInfo: UserLoginInfo(username: null, uid: uid));

  final NetClientProvider Function(int uid) _buildClient;

  /// The action.
  static const action = 'device';

  /// The longest "too soon" waited for before a write is sent again.
  static const maxBusyWait = 10;

  /// The devices of [uid].
  Future<LoginDeviceResult<LoginDeviceList>> list(int uid) async {
    final json = await TsdmAppApi.askWaitingKeepingAction(_buildClient(uid), action);
    if (json == null) {
      return const LoginDeviceFailed('');
    }
    if (json['ok'] != 1) {
      return json['error'] == 'action' ? const LoginDeviceUnsupported() : LoginDeviceFailed(tsdmAppText(json['error']));
    }
    if (json['supported'] != 1) {
      return const LoginDeviceUnsupported();
    }
    return LoginDeviceDone(
      LoginDeviceList(
        uid: tsdmAppInt(json['uid']),
        devices: tsdmAppList(json['devices']).map(LoginDevice.fromJson).whereType<LoginDevice>().toList(),
        formHash: tsdmAppText(json['formhash']),
      ),
    );
  }

  /// Register [device] for [uid] (after a login): its platform, the app's version and the device's name.
  ///
  /// The form hash comes from `status`, which tells whether the forum keeps devices (`device: 1`) at the same time.
  /// [stillCurrent] is asked right before the write: false (the id was replaced meanwhile) sends nothing.
  Future<LoginDeviceResult<LoginDevice>> register(
    int uid, {
    required String device,
    required String platform,
    required String appVersion,
    required String name,
    bool Function()? stillCurrent,
  }) async {
    final client = _buildClient(uid);
    final status = await TsdmAppApi.askWaiting(client, 'status');
    if (status == null) {
      return const LoginDeviceFailed('');
    }
    if (status['ok'] != 1) {
      return LoginDeviceFailed(tsdmAppText(status['error']));
    }
    if (status['device'] != 1) {
      return const LoginDeviceUnsupported();
    }
    if (stillCurrent != null && !stillCurrent()) {
      return const LoginDeviceFailed('replaced');
    }
    return _write(client, {
      'formhash': tsdmAppText(status['formhash']),
      'op': 'register',
      'device': device,
      'platform': platform,
      'app_version': appVersion,
      // Without a name the plugin keeps the one it has; an empty one would clear it.
      if (name.isNotEmpty) 'name': name,
    });
  }

  /// Log [device] out of [uid].
  Future<LoginDeviceResult<LoginDevice>> revoke(int uid, {required String formHash, required String device}) =>
      _write(_buildClient(uid), {'formhash': formHash, 'op': 'revoke', 'device': device});

  /// Take [device], logged out already, off the list of [uid]. An answer `nodevice` (gone already: the write was sent
  /// again after a "too soon", or another device removed it) is done as well.
  Future<LoginDeviceResult<void>> remove(int uid, {required String formHash, required String device}) async =>
      switch (await _send(_buildClient(uid), {'formhash': formHash, 'op': 'remove', 'device': device})) {
        null => const LoginDeviceFailed(''),
        final json when json['ok'] == 1 || json['error'] == 'nodevice' => const LoginDeviceDone(null),
        final json => LoginDeviceFailed(tsdmAppText(json['error'])),
      };

  Future<LoginDeviceResult<LoginDevice>> _write(NetClientProvider client, Map<String, String> form) async {
    final json = await _send(client, form);
    if (json == null) {
      return const LoginDeviceFailed('');
    }
    if (json['ok'] != 1) {
      return LoginDeviceFailed(tsdmAppText(json['error']));
    }
    if (json['supported'] != 1) {
      return const LoginDeviceUnsupported();
    }
    final device = LoginDevice.fromJson(tsdmAppMap(json['device']));
    return device == null ? const LoginDeviceFailed('') : LoginDeviceDone(device);
  }

  Future<Map<String, dynamic>?> _send(NetClientProvider client, Map<String, String> form, {bool again = true}) async {
    final json = await TsdmAppApi.post(client, action, form, acceptStatus: const {429});
    if (json != null && json['ok'] == 0 && json['error'] == 'busy') {
      final wait = tsdmAppInt(json['retry_after']);
      if (!again || wait > maxBusyWait) {
        debug('device ${form['op']}: busy for ${wait}s');
        return json;
      }
      await Future<void>.delayed(Duration(milliseconds: (wait < 0 ? 0 : wait) * 1000 + 300));
      return _send(client, form, again: false);
    }
    return json;
  }
}

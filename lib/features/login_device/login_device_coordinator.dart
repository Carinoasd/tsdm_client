import 'dart:async';
import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/login_device/login_device_identity.dart';
import 'package:tsdm_client/features/login_device/repository/login_device_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/git_info.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// The account the forum logged this device out of, as the app tells the user.
typedef LoginDeviceRevocation = ({int uid, String? username});

/// Keeps this device registered with the forum's app API (plugin 3.6.0) and follows the answer that it was logged out
/// of an account from another device.
///
/// * Each account in use is registered once per run and id ([LoginDeviceIdentity.id]): at the start with an account,
///   and at every login or switch (`AuthStatusAuthed`, also told at every homepage load: only a failed request is
///   asked again then). The plugin keeps the last activity from then on; a device it was never told of is not kept.
/// * An answer `device_revoked` for the id in use ([LoginDeviceIdentity.onRevoked]): a new id first (the old one stays
///   logged out for that account), then the login of that account is dropped from this device (the account in use
///   goes back to no account, another stored one loses its saved login), then [revocations] tells it. The account is
///   not registered again with the new id until it is logged in again: a register with the cookie that is still
///   valid on the forum would undo the logout (the plugin refuses the old id, not a new one).
final class LoginDeviceCoordinator with LoggerMixin {
  /// Constructor.
  LoginDeviceCoordinator({
    required AuthenticationRepository authentication,
    required StorageProvider storage,
    LoginDeviceRepository? repository,
    Future<String> Function()? deviceName,
  }) : _authentication = authentication,
       _storage = storage,
       _repository = repository ?? LoginDeviceRepository(),
       _deviceName = deviceName ?? loginDeviceName;

  final AuthenticationRepository _authentication;
  final StorageProvider _storage;
  final LoginDeviceRepository _repository;
  final Future<String> Function() _deviceName;

  StreamSubscription<AuthStatus>? _authSub;

  /// `uid/id` registered (or being registered) in this run.
  final _registered = <String>{};

  /// Accounts logged out of this device in this run and not logged in again since.
  final _revoked = <int>{};

  /// Of [_revoked], those whose login was dropped already: a login of one of them after that is a new one.
  final _dropped = <int>{};

  /// The check of the other stored accounts with an id replaced ([_checkOthers]) while it runs: no account is
  /// registered with the new id before it is done.
  Future<void>? _checking;

  /// `uid/id` of every answer `device_revoked` followed in this run: a late answer of a request sent before is not
  /// followed again, after a new login of the account neither.
  final _followed = <String>{};

  final _revocations = StreamController<LoginDeviceRevocation>.broadcast();

  /// The accounts the forum logged this device out of, as they are dropped.
  Stream<LoginDeviceRevocation> get revocations => _revocations.stream;

  /// The repository (the devices page).
  LoginDeviceRepository get repository => _repository;

  /// Load the id and start following the account.
  Future<void> start() async {
    LoginDeviceIdentity.onRevoked = _onRevoked;
    await LoginDeviceIdentity.load(_storage);
    _authSub = _authentication.status.listen(_onStatus);
  }

  void _onStatus(AuthStatus status) {
    if (status is! AuthStatusAuthed) {
      return;
    }
    final uid = status.userInfo.uid;
    if (uid == null) {
      return;
    }
    if (_revoked.contains(uid)) {
      // Before its login is dropped the account may still be verified with its cookie (the homepage): no login.
      if (!_dropped.contains(uid)) {
        return;
      }
      _revoked.remove(uid);
      _dropped.remove(uid);
    }
    unawaited(register(uid));
  }

  /// The errors of a register that refuse its fields, the same whenever it is sent again.
  static const _refusals = {'platform', 'app_version', 'device', 'limit'};

  /// Register this device for [uid], once per run and id. Does nothing on a platform the plugin does not know.
  Future<void> register(int uid) async {
    // A register asked while the other accounts are checked with an id replaced waits for the check.
    for (var checking = _checking; checking != null;) {
      await checking;
      checking = identical(_checking, checking) ? null : _checking;
    }
    final id = LoginDeviceIdentity.id;
    final platform = loginDevicePlatform;
    if (id == null || platform == null || _revoked.contains(uid) || !_registered.add('$uid/$id')) {
      return;
    }
    final name = await _deviceName();
    final result = await _repository.register(
      uid,
      device: id,
      platform: platform,
      appVersion: appVersion,
      name: name,
      stillCurrent: () => LoginDeviceIdentity.id == id && !_revoked.contains(uid),
    );
    switch (result) {
      case LoginDeviceDone():
        debug('device registered for the account');
      case LoginDeviceUnsupported():
        // Not asked again in this run: every homepage load tells the account authenticated again, and a forum
        // without devices would get a `status` for each.
        debug('the forum keeps no devices');
      case LoginDeviceFailed(:final error) when _refusals.contains(error):
        // The plugin refused what this device sends: not again in this run, it would refuse again.
        debug('device register refused: $error');
      case LoginDeviceFailed(:final error):
        // The request failed, or the session did (`login`, `formhash`, `busy`): asked again at the next homepage
        // load or login.
        debug('device register failed: $error');
        _registered.remove('$uid/$id');
    }
  }

  void _onRevoked(int uid, String device) {
    // Another id is no answer to this device; an account is followed once for each of its ids. Two accounts logged
    // out together (the polls of every account) both name the old id: the second one is dropped too, or it would go
    // on with the new id, which the forum does not refuse.
    if (!LoginDeviceIdentity.isOwn(device) || !_followed.add('$uid/$device')) {
      return;
    }
    _revoked.add(uid);
    _dropped.remove(uid);
    unawaited(_dropLogin(uid, renew: device == LoginDeviceIdentity.id));
  }

  Future<void> _dropLogin(int uid, {required bool renew}) async {
    final old = LoginDeviceIdentity.id;
    try {
      // The new id first, at once: every request from now on carries it. Only when the id in use was logged out.
      if (renew) {
        await LoginDeviceIdentity.renew(_storage);
      }
      _registered.removeWhere((e) => e.startsWith('$uid/'));
      String? username;
      if (uid == _authentication.effectiveCurrentUid) {
        username = _authentication.effectiveCurrentUser?.username;
        info('this device was logged out of the account in use, removing its login');
        if ((await _authentication.forgetCurrentUser(uid: uid).run()).isLeft()) {
          // Another account came in use meanwhile: the saved login of this one goes all the same.
          await _storage.deleteCookieByUid(uid);
        }
      } else {
        final accounts = await _storage.allAccountsStream().first;
        username = accounts.where((e) => e.user.uid == uid).firstOrNull?.user.username;
        info('this device was logged out of a stored account, removing its login');
        await _storage.deleteCookieByUid(uid);
      }
      _dropped.add(uid);
      if (!_revocations.isClosed) {
        _revocations.add((uid: uid, username: username));
      }
      // The other stored accounts may be logged out with the old id too: their requests carry the new one from now
      // on, which the forum does not refuse, so each is asked once with the old one (an answer `device_revoked` drops
      // it as this one), before the account in use is registered with the new id.
      if (renew && old != null) {
        final checking = _checking = _checkOthers(uid, old);
        try {
          await checking;
        } finally {
          if (identical(_checking, checking)) {
            _checking = null;
          }
        }
      }
      // The account in use goes on with the new id, which the forum only keeps once registered.
      final current = _authentication.effectiveCurrentUid;
      if (current != null && current != uid) {
        unawaited(register(current));
      }
    } on Object catch (e, st) {
      error('failed to drop the login of a device logged out: $e', e, st);
    }
  }

  /// Ask every stored account but [uid] (the account in use too: it may be logged out with [old] as well) with [old].
  Future<void> _checkOthers(int uid, String old) async {
    final List<StoredAccount> accounts;
    try {
      accounts = await _storage.allAccountsStream().first;
    } on Object catch (e, st) {
      error('device: failed to read the stored accounts: $e', e, st);
      return;
    }
    for (final account in accounts) {
      final other = account.user.uid;
      if (other == null || other == uid || _revoked.contains(other) || _followed.contains('$other/$old')) {
        continue;
      }
      try {
        if (!await _repository.probe(account.user, old)) {
          // Logged out with it too (dropped by now), or the request failed.
          debug('device: a stored account not confirmed with the id replaced');
        }
      } on Object catch (e, st) {
        // One account that could not be asked does not keep the others from it.
        error('device: failed to ask a stored account with the id replaced: $e', e, st);
      }
    }
  }

  /// Stop.
  Future<void> dispose() async {
    if (LoginDeviceIdentity.onRevoked == _onRevoked) {
      LoginDeviceIdentity.onRevoked = null;
    }
    await _authSub?.cancel();
    await _revocations.close();
  }
}

/// The platform as the plugin names it, null for one it does not know.
String? get loginDevicePlatform {
  if (isWeb) {
    return null;
  }
  return switch (Platform.operatingSystem) {
    final os && ('android' || 'ios' || 'windows' || 'macos' || 'linux') => os,
    _ => null,
  };
}

/// The name of this device the devices page shows: the maker and the model on Android, the host name on a desktop,
/// nothing on iOS (its host name says nothing more than the platform). Empty when the system does not tell.
Future<String> loginDeviceName() async {
  try {
    if (isAndroid) {
      return (await androidDeviceName()).trim();
    }
    if (isDesktop) {
      return Platform.localHostname.trim();
    }
  } on Object catch (e) {
    talker.debug('device name not available: $e');
  }
  return '';
}

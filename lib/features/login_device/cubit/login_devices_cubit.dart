import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/login_device/models/login_device.dart';
import 'package:tsdm_client/features/login_device/repository/login_device_repository.dart';

/// Where the devices page is.
enum LoginDevicesStatus {
  /// Reading the list.
  loading,

  /// The list is there.
  ready,

  /// The list could not be read.
  failed,

  /// The forum keeps no devices.
  unsupported,
}

/// State of the devices page.
@immutable
final class LoginDevicesState {
  /// Constructor.
  const LoginDevicesState({
    this.status = LoginDevicesStatus.loading,
    this.devices = const [],
    this.formHash = '',
    this.writing = const {},
    this.writeSeq = 0,
  });

  /// Where the page is.
  final LoginDevicesStatus status;

  /// The devices, this one first, then the others as the forum lists them (latest activity first).
  final List<LoginDevice> devices;

  /// The form hash of the session, for the writes.
  final String formHash;

  /// Ids of the devices a write is on its way for.
  final Set<String> writing;

  /// Grows by one for every write, or reading again, that failed (the list is as before); the page shows a hint on
  /// its change.
  final int writeSeq;

  /// The devices still logged in.
  List<LoginDevice> get active => devices.where((e) => !e.revoked).toList();

  /// The devices logged out.
  List<LoginDevice> get revoked => devices.where((e) => e.revoked).toList();

  /// Copy with.
  LoginDevicesState copyWith({
    LoginDevicesStatus? status,
    List<LoginDevice>? devices,
    String? formHash,
    Set<String>? writing,
    int? writeSeq,
  }) => LoginDevicesState(
    status: status ?? this.status,
    devices: devices ?? this.devices,
    formHash: formHash ?? this.formHash,
    writing: writing ?? this.writing,
    writeSeq: writeSeq ?? this.writeSeq,
  );
}

/// The devices of account [uid]: the list, logging one out, removing one logged out.
final class LoginDevicesCubit extends Cubit<LoginDevicesState> {
  /// Constructor.
  LoginDevicesCubit({required LoginDeviceRepository repository, required this.uid})
    : _repository = repository,
      super(const LoginDevicesState());

  final LoginDeviceRepository _repository;

  /// The account.
  final int uid;

  /// This device first, the order of the forum after it.
  static List<LoginDevice> _ordered(List<LoginDevice> devices) => [
    ...devices.where((e) => e.current),
    ...devices.where((e) => !e.current),
  ];

  /// Read the list. Read again (pulled down) the list stays while it is asked, and a failure keeps it with a hint.
  Future<void> load() async {
    final again = state.status == LoginDevicesStatus.ready;
    if (!again) {
      emit(state.copyWith(status: LoginDevicesStatus.loading));
    }
    final result = await _repository.list(uid);
    if (isClosed) {
      return;
    }
    if (again && result is LoginDeviceFailed) {
      emit(state.copyWith(writeSeq: state.writeSeq + 1));
      return;
    }
    emit(switch (result) {
      LoginDeviceDone(:final value) => state.copyWith(
        status: LoginDevicesStatus.ready,
        devices: _ordered(value.devices),
        formHash: value.formHash,
      ),
      LoginDeviceUnsupported() => state.copyWith(status: LoginDevicesStatus.unsupported),
      LoginDeviceFailed() => state.copyWith(status: LoginDevicesStatus.failed),
    });
  }

  /// Log [device] out of the account.
  Future<void> revoke(LoginDevice device) async {
    if (!_begin(device)) {
      return;
    }
    final result = await _repository.revoke(uid, formHash: state.formHash, device: device.id);
    if (isClosed) {
      return;
    }
    switch (result) {
      case LoginDeviceDone(:final value):
        _end(device, [
          for (final e in state.devices) e.id == value.id ? value : e,
        ]);
      case LoginDeviceFailed(error: 'nodevice'):
        // Removed meanwhile (from another device).
        _end(device, state.devices.where((e) => e.id != device.id).toList());
      case LoginDeviceUnsupported() || LoginDeviceFailed():
        _fail(device);
    }
  }

  /// Take [device], logged out, off the list.
  Future<void> remove(LoginDevice device) async {
    if (!_begin(device)) {
      return;
    }
    final result = await _repository.remove(uid, formHash: state.formHash, device: device.id);
    if (isClosed) {
      return;
    }
    switch (result) {
      case LoginDeviceDone():
        _end(device, state.devices.where((e) => e.id != device.id).toList());
      case LoginDeviceUnsupported() || LoginDeviceFailed():
        _fail(device);
    }
  }

  bool _begin(LoginDevice device) {
    if (state.status != LoginDevicesStatus.ready || state.writing.contains(device.id)) {
      return false;
    }
    emit(state.copyWith(writing: {...state.writing, device.id}));
    return true;
  }

  void _end(LoginDevice device, List<LoginDevice> devices) =>
      emit(state.copyWith(devices: devices, writing: {...state.writing}..remove(device.id)));

  void _fail(LoginDevice device) => emit(
    state.copyWith(
      writing: {...state.writing}..remove(device.id),
      writeSeq: state.writeSeq + 1,
    ),
  );
}

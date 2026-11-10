import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/account_security/models/account_security.dart';
import 'package:tsdm_client/features/account_security/repository/account_security_repository.dart';

/// Where a page of the account is.
enum AccountPageStatus {
  /// Reading.
  loading,

  /// Read.
  ready,

  /// Could not be read.
  failed,
}

/// The account center page of account [uid]: its rows.
final class AccountSecurityCubit extends Cubit<(AccountPageStatus, AccountSecurityOverview?)> {
  /// Constructor.
  AccountSecurityCubit({required AccountSecurityRepository repository, required this.uid})
    : _repository = repository,
      super(const (AccountPageStatus.loading, null));

  final AccountSecurityRepository _repository;

  /// The account.
  final int uid;

  /// Read the page.
  Future<void> load() async {
    emit((AccountPageStatus.loading, state.$2));
    final overview = await _repository.overview(uid);
    if (isClosed) {
      return;
    }
    emit(overview == null ? (AccountPageStatus.failed, state.$2) : (AccountPageStatus.ready, overview));
  }
}

/// Where the form of a way of the account center is.
enum AccountFormStatus {
  /// Opening the way.
  opening,

  /// The forum asks for the current password first.
  needsPassword,

  /// The forum only offers a check the web page does.
  otherCheck,

  /// The form is there.
  ready,

  /// Posting.
  submitting,

  /// Changed.
  done,

  /// Opening failed.
  failed,
}

/// State of the form of a way: never holds what the user typed (the passwords stay in the text fields).
@immutable
final class AccountFormState {
  /// Constructor.
  const AccountFormState({this.status = AccountFormStatus.opening, this.form, this.message = '', this.messageSeq = 0});

  /// Where the form is.
  final AccountFormStatus status;

  /// The forum's form, once opened.
  final AccountMethodForm? form;

  /// The forum's last message (a refusal, the success), empty for none or an unknown result.
  final String message;

  /// Grows by one for every message to show (a refusal of the check or of the form, an unknown result).
  final int messageSeq;

  /// Copy with.
  AccountFormState copyWith({AccountFormStatus? status, AccountMethodForm? form, String? message, int? messageSeq}) =>
      AccountFormState(
        status: status ?? this.status,
        form: form ?? this.form,
        message: message ?? this.message,
        messageSeq: messageSeq ?? this.messageSeq,
      );
}

/// The form of [method] in the account center of account [uid], opened with the form hash [formHash].
final class AccountFormCubit extends Cubit<AccountFormState> {
  /// Constructor.
  AccountFormCubit({
    required AccountSecurityRepository repository,
    required this.uid,
    required this.method,
    required this.formHash,
  }) : _repository = repository,
       super(const AccountFormState());

  final AccountSecurityRepository _repository;

  /// The account.
  final int uid;

  /// The way.
  final AccountMethod method;

  /// The form hash of the account center.
  final String formHash;

  /// Open the way, checking [currentPassword] when the forum asks for it.
  Future<void> open({String? currentPassword}) async {
    if (state.status == AccountFormStatus.submitting) {
      return;
    }
    final asked = state.status == AccountFormStatus.needsPassword;
    emit(state.copyWith(status: AccountFormStatus.opening));
    final result = await _repository.open(uid, method, formHash: formHash, currentPassword: currentPassword);
    if (isClosed) {
      return;
    }
    emit(switch (result) {
      AccountOpenForm(:final form) => state.copyWith(status: AccountFormStatus.ready, form: form),
      AccountOpenNeedsPassword() => state.copyWith(status: AccountFormStatus.needsPassword),
      AccountOpenOtherCheck() => state.copyWith(status: AccountFormStatus.otherCheck),
      // A wrong password keeps the field for another try.
      AccountOpenFailed(:final message) when asked || currentPassword != null => state.copyWith(
        status: AccountFormStatus.needsPassword,
        message: message,
        messageSeq: state.messageSeq + 1,
      ),
      AccountOpenFailed(:final message) => state.copyWith(status: AccountFormStatus.failed, message: message),
    });
  }

  /// Post the form with [values] (field name to value). Sent once; a refusal keeps the form for another try.
  Future<void> submit(Map<String, String> values) async {
    final form = state.form;
    if (form == null || state.status != AccountFormStatus.ready) {
      return;
    }
    emit(state.copyWith(status: AccountFormStatus.submitting));
    final result = await _repository.submit(uid, form, values);
    if (isClosed) {
      return;
    }
    emit(switch (result) {
      AccountSubmitDone(:final message) => state.copyWith(status: AccountFormStatus.done, message: message),
      AccountSubmitRefused(:final message) => state.copyWith(
        status: AccountFormStatus.ready,
        message: message,
        messageSeq: state.messageSeq + 1,
      ),
      AccountSubmitUnknown() => state.copyWith(
        status: AccountFormStatus.ready,
        message: '',
        messageSeq: state.messageSeq + 1,
      ),
    });
  }
}

/// The privacy settings of an account: the tabs as read, the changes not saved yet.
@immutable
final class PrivacySettingsState {
  /// Constructor.
  const PrivacySettingsState({
    this.status = AccountPageStatus.loading,
    this.saved = const [],
    this.edited = const [],
    this.saving = false,
    this.resultSeq = 0,
    this.lastSaveOk = false,
  });

  /// Where the page is.
  final AccountPageStatus status;

  /// The tabs as the forum has them.
  final PrivacySettings saved;

  /// The tabs with the changes of the user.
  final PrivacySettings edited;

  /// Saving.
  final bool saving;

  /// Grows by one for every save that ended.
  final int resultSeq;

  /// The last save went through.
  final bool lastSaveOk;

  /// The ops of the tabs changed and not saved.
  Set<String> get changed => {
    for (final (i, e) in edited.indexed)
      if (e.section != null &&
          i < saved.length &&
          !mapEquals(e.section!.values, saved[i].section?.values ?? const <String, String>{}))
        e.tab.op,
  };

  /// Copy with.
  PrivacySettingsState copyWith({
    AccountPageStatus? status,
    PrivacySettings? saved,
    PrivacySettings? edited,
    bool? saving,
    int? resultSeq,
    bool? lastSaveOk,
  }) => PrivacySettingsState(
    status: status ?? this.status,
    saved: saved ?? this.saved,
    edited: edited ?? this.edited,
    saving: saving ?? this.saving,
    resultSeq: resultSeq ?? this.resultSeq,
    lastSaveOk: lastSaveOk ?? this.lastSaveOk,
  );
}

/// The privacy page of account [uid]: read every tab, change settings, save the changed tabs at once.
final class PrivacySettingsCubit extends Cubit<PrivacySettingsState> {
  /// Constructor.
  PrivacySettingsCubit({required AccountSecurityRepository repository, required this.uid})
    : _repository = repository,
      super(const PrivacySettingsState());

  final AccountSecurityRepository _repository;

  /// The account.
  final int uid;

  /// Read the tabs; changes not saved are dropped.
  Future<void> load() async {
    emit(state.copyWith(status: AccountPageStatus.loading));
    final settings = await _repository.privacy(uid);
    if (isClosed) {
      return;
    }
    emit(
      settings == null
          ? state.copyWith(status: AccountPageStatus.failed)
          : state.copyWith(status: AccountPageStatus.ready, saved: settings, edited: settings),
    );
  }

  /// Set [item] of the tab [op] (a changed copy of one of its items).
  void change(String op, PrivacyItem item) {
    if (state.saving) {
      return;
    }
    emit(
      state.copyWith(
        edited: [
          for (final e in state.edited)
            if (e.tab.op == op && e.section != null)
              (
                tab: e.tab,
                section: e.section!.withItems([for (final i in e.section!.items) i.name == item.name ? item : i]),
              )
            else
              e,
        ],
      ),
    );
  }

  /// Save every changed tab, then read them again: done when the forum has what was asked.
  Future<void> save() async {
    final changed = state.changed;
    if (state.saving || changed.isEmpty) {
      return;
    }
    emit(state.copyWith(saving: true));
    final wanted = {
      for (final e in state.edited)
        if (changed.contains(e.tab.op)) e.tab.op: e.section!,
    };
    for (final section in wanted.values) {
      if (!await _repository.savePrivacy(uid, section)) {
        break;
      }
      if (isClosed) {
        return;
      }
    }
    final now = await _repository.privacy(uid);
    if (isClosed) {
      return;
    }
    if (now == null) {
      emit(state.copyWith(saving: false, resultSeq: state.resultSeq + 1, lastSaveOk: false));
      return;
    }
    final ok = wanted.entries.every(
      (w) => mapEquals(now.where((e) => e.tab.op == w.key).firstOrNull?.section?.values, w.value.values),
    );
    // What the forum has now; the changes it did not take are kept for another try.
    final edited = [
      for (final e in now)
        if (!ok && wanted.containsKey(e.tab.op) && e.section != null)
          (tab: e.tab, section: e.section!.withItems(wanted[e.tab.op]!.items))
        else
          e,
    ];
    emit(
      state.copyWith(
        status: AccountPageStatus.ready,
        saved: now,
        edited: edited,
        saving: false,
        resultSeq: state.resultSeq + 1,
        lastSaveOk: ok,
      ),
    );
  }
}

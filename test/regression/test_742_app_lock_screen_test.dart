/// The lock screen covers the whole app, pages pushed under it included, until the right PIN is entered on its pad
/// or a keyboard; the back button does not reach the app meanwhile. "Forgot PIN" asks twice, then removes every
/// account and turns the lock off; when the accounts could not all be removed the lock stays. An unlock asked before
/// an action (an account switch) can be cancelled.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/app_lock/repository/biometric_authenticator.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/features/app_lock/widgets/app_lock_gate.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

final class _NoBiometrics implements BiometricAuthenticator {
  @override
  Future<bool> authenticate(String reason) async => false;

  @override
  Future<bool> isAvailable() async => false;
}

const _hasher = PinHasher(iterations: 10, offUiIsolate: false);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  late AppLockCubit cubit;
  late AppLockStore store;
  late int forgetCalls;
  late bool forgetResult;
  late AppLockBackGuard guard;

  Future<void> pumpApp(WidgetTester tester) async {
    store = AppLockStore.memory();
    final pin = await _hasher.hash('1234');
    cubit = AppLockCubit(
      config: AppLockConfig(method: AppLockMethod.pin, pin: pin),
      store: store,
      biometrics: _NoBiometrics(),
      hasher: _hasher,
    );
    forgetCalls = 0;
    forgetResult = true;
    // Before the app, like main(): first in line for the back button.
    guard = AppLockBackGuard(cubit);
    tester.binding.addObserver(guard);
    addTearDown(() => tester.binding.removeObserver(guard));
    addTearDown(cubit.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('second page')))),
                  child: const Text('content'),
                ),
              ),
            ),
          ),
          builder: (context, child) => AppLockGate(
            cubit: cubit,
            forgetAccounts: (_) async {
              forgetCalls += 1;
              return forgetResult;
            },
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String pin) async {
    for (final d in pin.split('')) {
      await tester.tap(find.byKey(ValueKey('app-lock-digit-$d')));
      await tester.pump();
    }
    if (pin.length < appLockPinMaxLength) {
      await tester.tap(find.byKey(const ValueKey('app-lock-submit')));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('covers the app until the right PIN is entered', (tester) async {
    await pumpApp(tester);
    final tr = t.appLock;
    expect(find.text(tr.lockScreen.enterPin), findsOneWidget);
    expect(find.text('content').hitTestable(), findsNothing, reason: 'the app underneath takes no tap');

    await enter(tester, '0000');
    expect(find.text(tr.lockScreen.wrongPin), findsOneWidget);
    expect(cubit.state.locked, isTrue);

    await enter(tester, '1234');
    expect(cubit.state.locked, isFalse);
    expect(find.text(tr.lockScreen.enterPin), findsNothing);
    await tester.tap(find.text('content'));
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsOneWidget);

    // Locked again over a pushed page, unlocked with the keyboard this time.
    cubit.lock();
    await tester.pumpAndSettle();
    expect(find.text(tr.lockScreen.enterPin), findsOneWidget);
    expect(find.text('second page').hitTestable(), findsNothing);
    for (final key in [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.enter,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(cubit.state.locked, isFalse);
    expect(find.text('second page'), findsOneWidget, reason: 'the page under the lock is still there');
  });

  testWidgets('the back button does not reach the app while locked', (tester) async {
    await pumpApp(tester);
    await enter(tester, '1234');
    await tester.tap(find.text('content'));
    await tester.pumpAndSettle();
    cubit.lock();
    await tester.pumpAndSettle();

    expect(await guard.didPopRoute(), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await enter(tester, '1234');
    expect(find.text('second page'), findsOneWidget, reason: 'the back presses while locked popped nothing');

    expect(await guard.didPopRoute(), isFalse, reason: 'unlocked, the app gets it');
  });

  testWidgets('"forgot PIN" asks twice, then removes the accounts and turns the lock off', (tester) async {
    await pumpApp(tester);
    final tr = t.appLock.forgot;

    // Cancelled at the second question: nothing happens.
    await tester.tap(find.byKey(const ValueKey('app-lock-forgot')));
    await tester.pumpAndSettle();
    expect(find.text(tr.detail), findsOneWidget);
    await tester.tap(find.text(t.general.ok));
    await tester.pumpAndSettle();
    expect(find.text(tr.confirmDetail), findsOneWidget);
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(forgetCalls, 0);
    expect(cubit.state.locked, isTrue);

    // The accounts could not all be removed: the lock stays.
    forgetResult = false;
    await tester.tap(find.byKey(const ValueKey('app-lock-forgot')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.ok));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.ok));
    await tester.pumpAndSettle();
    expect(forgetCalls, 1);
    expect(cubit.state.locked, isTrue);
    expect(find.text(tr.failed), findsOneWidget);

    forgetResult = true;
    await tester.tap(find.byKey(const ValueKey('app-lock-forgot')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.ok));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.ok));
    await tester.pumpAndSettle();
    expect(forgetCalls, 2);
    expect(cubit.state.covering, isFalse);
    expect(find.text('content').hitTestable(), findsOneWidget);
    await cubit.pendingWrites;
    expect((await store.load()).enabled, isFalse, reason: 'the PIN is forgotten');
  });

  testWidgets('an unlock asked before an action can be cancelled', (tester) async {
    await pumpApp(tester);
    await enter(tester, '1234');

    var result = cubit.requestVerification(always: true);
    await tester.pumpAndSettle();
    expect(find.text(t.appLock.lockScreen.enterPin), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-lock-cancel')));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(find.text(t.appLock.lockScreen.enterPin), findsNothing);

    result = cubit.requestVerification(always: true);
    await tester.pumpAndSettle();
    expect(await guard.didPopRoute(), isTrue, reason: 'back cancels it too');
    expect(await result, isFalse);

    result = cubit.requestVerification(always: true);
    await tester.pumpAndSettle();
    await enter(tester, '1234');
    expect(await result, isTrue);
  });
}

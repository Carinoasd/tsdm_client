// Isolated emulator entry point, never used by release workflows.
// Exercises the production update page/downloader/native installer without a forum account.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/update/cubit/update_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/view/update_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  talker = TalkerFlutter.init();
  await LocaleSettings.setLocale(AppLocale.en);
  // Pinned public release: only version discovery is seeded. The production repository
  // fetches the real GitHub release, downloads its APK and verifies its published digest.
  const info = LatestVersionInfo(
    version: '1.30.0',
    versionCode: 120,
    changelog: 'Android emulator verification against public v1.30.0.',
  );
  final updates = UpdateCubit()..emit(const UpdateCubitState(latestVersionInfo: info));
  runApp(
    TranslationProvider(
      child: BlocProvider.value(
        value: updates,
        child: MaterialApp(theme: ThemeData(useMaterial3: true), home: const UpdatePage()),
      ),
    ),
  );
  // Same recovery called after production version discovery. Never installs by itself.
  unawaited(updates.download.restore(info));
}

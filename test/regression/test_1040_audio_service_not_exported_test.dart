// The audio service (audio_service, just_audio_background) is not exported: the Bluetooth stack bound every exported
// media browser service at boot, which made the app's engine and ran `main()` with no activity (PR #379). What the
// app needs of it goes through the media session or through this package only, so the manifest reads accordingly.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';

XmlElement _component(XmlDocument manifest, String tag, String name) => manifest
    .findAllElements(tag)
    .singleWhere((e) => e.getAttribute('name', namespace: _android) == name, orElse: () => throw StateError(name));

List<String> _actions(XmlElement component) =>
    component.findAllElements('action').map((e) => e.getAttribute('name', namespace: _android)!).toList();

void main() {
  final manifest = XmlDocument.parse(File('android/app/src/main/AndroidManifest.xml').readAsStringSync());

  test('the audio service is not exported', () {
    final service = _component(manifest, 'service', 'com.ryanheise.audioservice.AudioService');
    expect(service.getAttribute('exported', namespace: _android), 'false');
    // Still the media playback foreground service the player runs in.
    expect(service.getAttribute('foregroundServiceType', namespace: _android), 'mediaPlayback');
  });

  test('the audio service keeps its media browser action, which the media button receiver looks it up by', () {
    // androidx MediaButtonReceiver.getServiceComponentByAction: queryIntentServices with this action and setPackage
    // (this app), which finds a service of the same package exported or not. Without the filter a media button
    // pressed with the process dead would throw.
    final service = _component(manifest, 'service', 'com.ryanheise.audioservice.AudioService');
    expect(_actions(service), ['android.media.browse.MediaBrowserService']);
  });

  test('the media button receiver stays exported: the system delivers the media buttons to it', () {
    final receiver = _component(manifest, 'receiver', 'com.ryanheise.audioservice.MediaButtonReceiver');
    expect(receiver.getAttribute('exported', namespace: _android), 'true');
    expect(_actions(receiver), ['android.intent.action.MEDIA_BUTTON']);
  });

  test('the app offers nothing to browse or resume: the resumption card lost by not exporting had nothing to play', () {
    // The media browser's children and "play from a media id" are what the system's resumption card and the car and
    // watch browsers use. Should the app ever offer them, exporting the service is a choice to make again.
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      if (RegExp(r'\b(getChildren|playFromMediaId|prepareFromMediaId|playFromSearch)\s*\(').hasMatch(text)) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty);
  });
}

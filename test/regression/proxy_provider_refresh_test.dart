import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/shared/providers/proxy_provider/proxy_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/system_network_proxy');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('system proxy refresh clears the old address when the proxy is disabled', () async {
    var enabled = true;
    var server = '127.0.0.1:8080';
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'getProxyEnable' => enabled,
        'getProxyServer' => server,
        _ => throw MissingPluginException(),
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final provider = ProxyProvider();
    await provider.updateProxy();
    expect(provider.proxyEnabled, isTrue);
    expect(provider.proxy, server);

    enabled = false;
    await provider.updateProxy();
    expect(provider.proxyEnabled, isFalse);
    expect(provider.proxy, isEmpty, reason: 'a background tick must not reuse the disconnected network proxy');

    enabled = true;
    server = '127.0.0.1:9090';
    await provider.updateProxy();
    expect(provider.proxyEnabled, isTrue);
    expect(provider.proxy, server);
  });
}

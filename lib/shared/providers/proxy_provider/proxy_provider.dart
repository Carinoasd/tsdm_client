import 'package:native_flutter_proxy/native_flutter_proxy.dart';
import 'package:system_network_proxy/system_network_proxy.dart';
import 'package:tsdm_client/utils/platform.dart';

/// The provider holding current system proxy state.
final class ProxyProvider {
  /// Proxy is enabled in system or not.
  bool _proxyEnabled = false;

  /// Proxy settings value.
  String _proxy = '';

  /// Proxy is enabled in system or not.
  bool get proxyEnabled => _proxyEnabled;

  /// Proxy settings value.
  String get proxy => _proxy;

  /// Update proxy state.
  Future<void> updateProxy() async {
    if (isMobile) {
      final proxy = await NativeProxyReader.proxySetting;
      _proxyEnabled = proxy.enabled;
      // One platform snapshot: a network change between two reads must not combine an old flag with a new address.
      _proxy = proxy.enabled ? '${proxy.host}:${proxy.port}' : '';
    } else if (isDesktop) {
      final enabled = await SystemNetworkProxy.getProxyEnable();
      final address = enabled ? await SystemNetworkProxy.getProxyServer() : '';
      _proxyEnabled = enabled;
      _proxy = address;
    } else {
      throw UnimplementedError('Proxy utility is not implemented on this platform');
    }
  }
}

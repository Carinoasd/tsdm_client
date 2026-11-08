import 'package:flutter/foundation.dart';

/// A kind of online storage service, recognised by the host of a link.
@immutable
final class NetdiskProvider {
  /// Constructor.
  const NetdiskProvider({required this.name, required this.hosts, this.codeParam});

  /// Name shown on the chip.
  final String name;

  /// Host suffixes of the service: a link belongs to the provider when its host equals one or ends with `.<host>`.
  final List<String> hosts;

  /// Query parameter that carries the extract code in a link opening the share directly, null when the service has no
  /// such parameter (the code is copied before opening instead).
  final String? codeParam;
}

/// One online storage link found in a post, with the codes written near it.
@immutable
final class NetdiskLink {
  /// Constructor.
  const NetdiskLink({required this.url, required this.provider, this.extractCode, this.unzipPassword});

  /// The link as written in the post.
  final String url;

  /// The service the link points to.
  final NetdiskProvider provider;

  /// Extract (access) code of the share.
  final String? extractCode;

  /// Password of the archive downloaded from the share.
  final String? unzipPassword;

  /// The url to open: carries the extract code when [NetdiskProvider.codeParam] allows it, the one shown on the chip
  /// even where the url itself holds another.
  String get openUrl {
    final param = provider.codeParam;
    final code = extractCode;
    if (param == null || code == null) {
      return url;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.queryParameters[param] == code) {
      return url;
    }
    return uri.replace(queryParameters: {...uri.queryParameters, param: code}).toString();
  }

  /// Whether [extractCode] has to be copied by hand before opening: it is not part of [openUrl].
  bool get needsCopyBeforeOpen => extractCode != null && provider.codeParam == null;

  @override
  bool operator ==(Object other) =>
      other is NetdiskLink &&
      other.url == url &&
      other.provider == provider &&
      other.extractCode == extractCode &&
      other.unzipPassword == unzipPassword;

  @override
  int get hashCode => Object.hash(url, provider, extractCode, unzipPassword);

  @override
  String toString() => 'NetdiskLink($url, $extractCode, $unzipPassword)';
}

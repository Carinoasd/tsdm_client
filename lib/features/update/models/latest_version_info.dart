import 'dart:convert';

import 'package:dart_mappable/dart_mappable.dart';

part 'latest_version_info.mapper.dart';

/// The info about latest version fetched from server.
@MappableClass()
final class LatestVersionInfo with LatestVersionInfoMappable {
  /// Constructor.
  const LatestVersionInfo({required this.version, required this.versionCode, required this.changelog});

  /// Version name.
  final String version;

  /// Version code.
  final int versionCode;

  /// Changelog on the latest version.
  final String changelog;
}

/// Build a [LatestVersionInfo] from whatever the HTTP client handed back for `version.json`.
///
/// Depending on the platform client and the `Content-Type` the server sends, the body arrives as an already decoded
/// map, a JSON string or raw bytes. Anything else, or JSON that does not describe a version, throws a
/// [FormatException].
LatestVersionInfo parseLatestVersionInfo(Object? data) {
  final Object? decoded = switch (data) {
    final Map<dynamic, dynamic> m => m,
    final String s => jsonDecode(s),
    final List<int> b => jsonDecode(utf8.decode(b)),
    _ => throw FormatException('unexpected version info payload: ${data.runtimeType}'),
  };
  if (decoded is! Map<dynamic, dynamic>) {
    throw const FormatException('version info is not a JSON object');
  }
  final version = decoded['version'];
  final versionCode = decoded['versionCode'];
  final changelog = decoded['changelog'];
  if (version is! String || version.isEmpty || versionCode is! int || changelog is! String) {
    throw const FormatException('version info misses version, versionCode or changelog');
  }
  return LatestVersionInfo(version: version, versionCode: versionCode, changelog: changelog);
}

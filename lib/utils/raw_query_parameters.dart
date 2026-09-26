final _brokenEscape = RegExp('%(?![0-9A-Fa-f]{2})');

/// Query pairs decoded without the form-encoding rule that turns `+` into a space (base64 values use `+`).
///
/// Null when a name repeats (ambiguous), an escape is malformed or an escape is not UTF-8.
Map<String, String>? rawQueryParameters(String query) {
  if (_brokenEscape.hasMatch(query)) return null;
  final params = <String, String>{};
  for (final part in query.split('&')) {
    if (part.isEmpty) continue;
    final separator = part.indexOf('=');
    try {
      final key = Uri.decodeComponent(separator < 0 ? part : part.substring(0, separator));
      final value = separator < 0 ? '' : Uri.decodeComponent(part.substring(separator + 1));
      if (params.containsKey(key)) return null;
      params[key] = value;
    } on FormatException {
      return null;
    }
  }
  return params;
}

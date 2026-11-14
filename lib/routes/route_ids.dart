/// The id parameters of the app's routes: the ids of the forum (threads, forums, members, posts, attachments…) that a
/// page puts into the urls it requests.
///
/// A route parsed from a link ([isRouteIdValue]) only ever carries an integer there: a link of a page, a shared text or
/// another app (`fid=1%26action%3Dx`) must not add parameters of its own to the urls the page builds with it.
library;

/// The path and query parameters of the routes that hold an id of the forum.
const routeIdParameters = {
  'tid',
  'fid',
  'gid',
  'uid',
  'pid',
  'aid',
  'ctid',
  'pmid',
  'cid',
  'doid',
  'blogId',
  'albumId',
  'taskId',
  'onlyVisibleUid',
  'pageNumber',
  'threadTypeID',
};

final _integer = RegExp(r'^-?\d+$');

/// Whether [value] may be the value of an id parameter ([routeIdParameters]): an integer (digits; `-1` is the album of
/// the pictures in no album), or nothing (a link without the value, which names no other id either).
bool isRouteIdValue(String value) => value.isEmpty || _integer.hasMatch(value);

/// Whether every id parameter among [parameters] holds an id ([isRouteIdValue]).
bool routeIdsValid(Map<String, String> parameters) =>
    parameters.entries.every((e) => !routeIdParameters.contains(e.key) || isRouteIdValue(e.value));

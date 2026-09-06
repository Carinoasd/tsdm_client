/// Repair the nesting the editor produces around block markers.
///
/// The editor keeps `[spoiler]`, `[hide]` and `[free]` as a head piece and a tail piece with ordinary content in
/// between. When a style such as a colour is applied across one of those pieces, the exported BBCode wraps the piece
/// alone in the style tag, e.g. `[color=#0cc][spoiler=title][/color] ... [color=#0cc][/spoiler][/color]`. The forum
/// still pairs the two pieces, but the editor does not when that text is loaded again: the head turns into a second
/// tail and the post is saved with two `[/spoiler]` and no head. This unwraps every style tag that holds nothing but a
/// marker, so the text going into the editor and out to the forum always has bare markers.
library;

/// A style tag wrapping exactly one block marker: `[style]` + optional whitespace + marker + optional whitespace +
/// `[/style]`, where the marker is a head (`[spoiler=...]`, `[hide]`, ...) or a tail (`[/spoiler]`, ...).
final RegExp _wrappedMarker = RegExp(
  r'\[(color|size|font|backcolor|b|i|u|s)(?:=[^\]]*)?\]\s*(\[(?:spoiler|hide|free)(?:=[^\]]*)?\]|\[/(?:spoiler|hide|free)\])\s*\[/\1\]',
  caseSensitive: false,
);

/// Return [bbcode] with every style tag that wraps nothing but a block marker removed, keeping the marker.
///
/// Nested wrappers (`[size=3][color=red][spoiler=x][/color][/size]`) are peeled one layer per pass until nothing
/// changes, so the result is stable under a second call. Text without such wrappers is returned unchanged.
String normalizeBlockMarkerNesting(String bbcode) {
  var current = bbcode;
  String previous;
  do {
    previous = current;
    current = current.replaceAllMapped(_wrappedMarker, (m) => m.group(2)!);
  } while (current != previous);
  return current;
}

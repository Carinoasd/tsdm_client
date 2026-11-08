import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/features/thread/v1/utils/post_export.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Marks the plain text conversion writes in place of what is not read as it is; swapped for the spoken words
/// afterwards. Private-use characters: no post text carries them.
const _imageMark = '';
const _foldMark = '';
const _hiddenMark = '';
const _mediaMark = '';

/// The words said in place of what a floor shows but is not read out.
@immutable
final class SpeechLabels {
  /// Constructor.
  const SpeechLabels({
    this.image = '图片',
    this.fold = '折叠',
    this.hidden = '隐藏内容',
    this.media = '媒体',
  });

  /// Said for an image.
  final String image;

  /// Said for a fold.
  final String fold;

  /// Said for the content the forum hides.
  final String hidden;

  /// Said for a player or other media.
  final String media;
}

/// Longest text handed to the speech engine at once: Android refuses an input of 4000 characters and more.
const maxSpeechChunk = 1500;

final _urlPattern = RegExp(r'(?:https?://|mailto:|ftp://)[^\s)）]+', caseSensitive: false);
final _emptyParens = RegExp(r'[(（]\s*[)）]');
final _quoteLead = RegExp(r'^[ \t]*(?:>[ \t]?)+', multiLine: true);
final _listLead = RegExp(r'^[ \t]*(?:[-*+]|\d+\.)[ \t]+', multiLine: true);

/// The text of the floor with [html] as it is read aloud: the plain text of the floor without the addresses of links,
/// the marks of lists and quotes, and the smileys' brackets; an image is [SpeechLabels.image].
String speechTextOfHtml(String html, {SpeechLabels labels = const SpeechLabels()}) {
  final plain = postHtmlToText(
    html,
    format: PostExportFormat.plainText,
    labels: const PostExportLabels(
      fold: _foldMark,
      hidden: _hiddenMark,
      image: _imageMark,
      media: _mediaMark,
    ),
  );
  final text = plain
      // The addresses are not read; an image is `mark address`.
      .replaceAll(_urlPattern, ' ')
      .replaceAll(_emptyParens, ' ')
      .replaceAll(_quoteLead, '')
      .replaceAll(_listLead, '')
      .replaceAll('[', '')
      .replaceAll(']', '')
      .replaceAll(_imageMark, ' ${labels.image} ')
      .replaceAll(_foldMark, ' ${labels.fold} ')
      .replaceAll(_hiddenMark, ' ${labels.hidden} ')
      .replaceAll(_mediaMark, ' ${labels.media} ');
  // One line each, no runs of blanks.
  return text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\u3000]+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

/// [text] cut into parts of at most [maxLength] characters, at a line end, a sentence end or a blank when there is one.
List<String> chunkSpeech(String text, {int maxLength = maxSpeechChunk}) {
  final out = <String>[];
  var rest = text.trim();
  while (rest.length > maxLength) {
    var cut = _cutPoint(rest, maxLength);
    if (cut <= 0) {
      cut = maxLength;
    }
    final head = rest.substring(0, cut).trim();
    if (head.isNotEmpty) {
      out.add(head);
    }
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) {
    out.add(rest);
  }
  return out;
}

int _cutPoint(String text, int maxLength) {
  final window = text.substring(0, maxLength);
  final floor = maxLength ~/ 3;
  final newline = window.lastIndexOf('\n');
  if (newline > floor) {
    return newline + 1;
  }
  // A sentence end first, then a pause, then any blank.
  for (final marks in const [
    ['。', '！', '？', '；', '. ', '! ', '? '],
    ['，', '、', ', '],
    [' '],
  ]) {
    var best = -1;
    for (final mark in marks) {
      final at = window.lastIndexOf(mark);
      if (at > floor && at + mark.length > best) {
        best = at + mark.length;
      }
    }
    if (best > 0) {
      return best;
    }
  }
  return -1;
}

/// What is said for a floor: the heading, then the content in parts the engine takes.
@immutable
final class FloorSpeech {
  /// Constructor.
  const FloorSpeech(this.utterances);

  /// The parts, said one after the other; never empty.
  final List<String> utterances;
}

/// What is said for [post]; [heading] is the first part (floor and author).
FloorSpeech floorSpeechOf(Post post, {required String heading, SpeechLabels labels = const SpeechLabels()}) {
  final body = speechTextOfHtml(post.data, labels: labels);
  return FloorSpeech([heading, ...chunkSpeech(body)]);
}

import 'package:flutter/foundation.dart';

/// Where a track is fetched from.
enum AudioTrackSource {
  /// An attachment of a floor (`forum.php?mod=attachment&aid=…`), fetched with the account's cookie.
  attachment,

  /// A song of NetEase Cloud Music, fetched from its public outer url without a cookie; most songs are not public.
  netease,
}

/// One sound the app plays itself: an audio attachment of a floor, or a public song of NetEase Cloud Music.
@immutable
final class AudioTrack {
  /// Constructor.
  const AudioTrack({
    required this.id,
    required this.title,
    required this.url,
    required this.source,
    this.filesize = 0,
    this.tid,
    this.threadTitle,
  });

  /// An attachment [aid] named [filename] at [url].
  factory AudioTrack.attachment({
    required int aid,
    required String filename,
    required String url,
    int filesize = 0,
    String? tid,
    String? threadTitle,
  }) => AudioTrack(
    id: 'attach:$aid',
    title: filename,
    url: url,
    source: AudioTrackSource.attachment,
    filesize: filesize,
    tid: tid,
    threadTitle: threadTitle,
  );

  /// The song [songId] of NetEase Cloud Music, [title] when the page names it.
  factory AudioTrack.netease(String songId, {String? title, String? tid, String? threadTitle}) => AudioTrack(
    id: 'netease:$songId',
    title: title ?? songId,
    url: neteaseOuterUrl(songId),
    source: AudioTrackSource.netease,
    tid: tid,
    threadTitle: threadTitle,
  );

  /// The public address NetEase Cloud Music redirects to the file of a song it lets everyone play, and to a page
  /// saying it is not found for the others.
  static String neteaseOuterUrl(String songId) => 'https://music.163.com/song/media/outer/url?id=$songId.mp3';

  /// Unique for what is played: `attach:<aid>`, `netease:<song id>`.
  final String id;

  /// The name shown: the file name of an attachment, the song of NetEase Cloud Music.
  final String title;

  /// Where it is fetched from.
  final String url;

  /// How it is fetched.
  final AudioTrackSource source;

  /// Size in bytes, 0 when unknown.
  final int filesize;

  /// The thread it is in, when known.
  final String? tid;

  /// The title of the thread it is in, when known.
  final String? threadTitle;

  /// The same track for the thread [tid] titled [threadTitle].
  AudioTrack inThread(String? tid, String? threadTitle) => AudioTrack(
    id: id,
    title: title,
    url: url,
    source: source,
    filesize: filesize,
    tid: tid ?? this.tid,
    threadTitle: threadTitle ?? this.threadTitle,
  );

  @override
  bool operator ==(Object other) => other is AudioTrack && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AudioTrack($id)';
}

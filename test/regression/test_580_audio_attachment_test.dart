/// The audio attachments of a floor are played in the app: which of the forum's attachment blocks are one (the inline
/// `span#attach_N` and the listed `dl.tattl`, an audio file the account may download), their id, name, size and
/// address; the order they are played in across floors; the links to a song of NetEase Cloud Music
/// (`/song?id=`, `/#/song?id=`).
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';
import 'package:tsdm_client/features/audio_player/utils/audio_attachment.dart';
import 'package:universal_html/parsing.dart';

/// A floor of the test forum with three audio attachments (two in the message, one listed), a paid one and a zip.
final String _floor = File('test/data/audio_attachment_post_x5.html').readAsStringSync();

void main() {
  group('PostAudioAttachment.allOf', () {
    test('finds the inline and the listed audio attachments in the order of the page', () {
      final all = PostAudioAttachment.allOf(_floor);
      expect(all.map((e) => e.aid), [1610, 1608, 1609]);
      expect(all.map((e) => e.filename), ['测试 歌曲.mp3', 'sine_b.flac', 'sine_c.m4a']);
      expect(all.map((e) => e.sizeText), ['36.73 KB', '88.36 KB', '35.23 KB']);
      expect(all.map((e) => e.description), [null, null, '第二首']);
      expect(
        all.first.url,
        'https://www.tsdm39.com/forum.php?mod=attachment&aid=MTYxMHxmMWYyZjNmNHwxNzAwMDAwMDAwfDMxfDEwMA%3D%3D',
      );
    });

    test('leaves out an attachment to buy, a file that is not audio, a picture', () {
      final all = PostAudioAttachment.allOf(_floor);
      expect(all.where((e) => e.filename == 'paid.mp3' || e.filename == 'pack.zip'), isEmpty);
      const picture =
          '<ignore_js_op><img id="aimg_9" aid="9" src="static/image/common/none.gif" '
          'zoomfile="forum.php?mod=attachment&amp;aid=OXxhfDF8MXwx&amp;noupdate=yes&amp;nothumb=yes" />'
          '<a href="forum.php?mod=attachment&amp;aid=OXxhfDF8MXwx&amp;nothumb=yes">cover.mp3</a></ignore_js_op>';
      expect(PostAudioAttachment.allOf(picture), isEmpty);
    });

    test('a block holding a block: the inner one alone, the text around it kept out of the card', () {
      const nested =
          '<ignore_js_op>曲目 <ignore_js_op><a href="forum.php?mod=attachment&amp;aid=3" id="aid3">a.mp3</a>'
          '</ignore_js_op> 说明</ignore_js_op>';
      final outer = parseHtmlDocument(nested).querySelector('ignore_js_op')!;
      expect(PostAudioAttachment.of(outer), isNull);
      expect(PostAudioAttachment.allOf(nested).map((e) => e.aid), [3]);
    });

    test('a block of two attachments is none of them', () {
      const two =
          '<ignore_js_op><a href="forum.php?mod=attachment&amp;aid=1">a.mp3</a>'
          '<a href="forum.php?mod=attachment&amp;aid=2">b.mp3</a></ignore_js_op>';
      expect(PostAudioAttachment.allOf(two), isEmpty);
    });

    test("Apple's player: no Ogg, no Opus", () {
      const ogg = '<ignore_js_op><a href="forum.php?mod=attachment&amp;aid=5" id="aid5">a.ogg</a></ignore_js_op>';
      expect(PostAudioAttachment.allOf(ogg).map((e) => e.aid), [5]);
      expect(PostAudioAttachment.allOf(ogg, apple: true), isEmpty);
      expect(isPlayableAudioFile('A.FLAC', apple: true), isTrue);
      expect(isPlayableAudioFile('song.wma'), isFalse);
      expect(isPlayableAudioFile('.mp3'), isFalse);
    });

    test('html that cannot be read gives none', () {
      expect(PostAudioAttachment.allOf(''), isEmpty);
      expect(PostAudioAttachment.of(parseHtmlDocument('<p>x</p>').body!), isNull);
    });
  });

  group('aidOfAttachmentUrl', () {
    test('reads the id from the encoded and the plain aid', () {
      expect(aidOfAttachmentUrl('forum.php?mod=attachment&aid=MTYxMHxmMWYyZjNmNHwxNzAwMDAwMDAwfDMxfDEwMA%3D%3D'), 1610);
      expect(aidOfAttachmentUrl('forum.php?mod=attachment&aid=MTYxMHxmMWYyZjNmNHwxNzAwMDAwMDAwfDMxfDEwMA'), 1610);
      expect(aidOfAttachmentUrl('forum.php?mod=attachment&aid=42'), 42);
      expect(aidOfAttachmentUrl('forum.php?mod=attachment&aid=@@@'), isNull);
      expect(aidOfAttachmentUrl('forum.php?mod=attachment'), isNull);
    });
  });

  group('audioTracksOfHtml', () {
    test('every floor in its order, an attachment quoted again once', () {
      const second =
          '<ignore_js_op><a href="forum.php?mod=attachment&amp;aid=77" id="aid77">next.mp3</a></ignore_js_op>';
      final tracks = audioTracksOfHtml([_floor, second, _floor], tid: '100', threadTitle: 'T');
      expect(tracks.map((e) => e.id), ['attach:1610', 'attach:1608', 'attach:1609', 'attach:77']);
      expect(tracks.every((e) => e.tid == '100' && e.threadTitle == 'T'), isTrue);
      expect(tracks.every((e) => e.source == AudioTrackSource.attachment), isTrue);
    });
  });

  group('neteaseSongIdOf', () {
    test('the song pages, the route in the fragment too', () {
      expect(neteaseSongIdOf('https://music.163.com/song?id=186016'), '186016');
      expect(neteaseSongIdOf('https://music.163.com/#/song?id=1974443814'), '1974443814');
      expect(neteaseSongIdOf('http://music.163.com/song/?id=1&userid=2'), '1');
      expect(neteaseSongIdOf('https://y.music.163.com/m/song?id=33894312'), '33894312');
    });

    test('anything else is none', () {
      expect(neteaseSongIdOf('https://music.163.com/#/playlist?id=1'), isNull);
      expect(neteaseSongIdOf('https://music.163.com/album?id=1'), isNull);
      expect(neteaseSongIdOf('https://music.163.com.evil.example/song?id=1'), isNull);
      expect(neteaseSongIdOf('https://music.163.com/song?id=abc'), isNull);
      expect(neteaseSongIdOf('javascript:alert(1)'), isNull);
      expect(neteaseSongIdOf('forum.php?mod=viewthread&tid=1'), isNull);
    });

    test('the outer url of a song', () {
      expect(AudioTrack.netease('186016').url, 'https://music.163.com/song/media/outer/url?id=186016.mp3');
    });
  });
}

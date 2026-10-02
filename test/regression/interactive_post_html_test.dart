import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/thread/v1/utils/interactive_post_html.dart';

String _fixture(String name) => File('test/data/$name').readAsStringSync();

String _message(String html, {String id = '42'}) => '<div class="t_f" id="postmessage_$id">$html</div>';

void main() {
  group('interactivePostHtml message isolation', () {
    test('keeps the authored source unchanged and excludes forum scripts and styles', () {
      const authored = '''
<style>.card { color: red; }</style>
<button data-label='a&amp;b' onclick="run('a&b')">開始</button>
<script>const value = '<tag>';\nrun(value);</script>''';
      final data = '<style>.forum { color: blue; }</style>${_message(authored)}<script>forumOnly();</script>';
      expect(interactivePostHtml(data, postId: '42'), authored);
    });

    test('selects the exact floor even when another message is present', () {
      final data = '${_message('<canvas></canvas>', id: '1')}${_message('<button>Start</button>')}';
      expect(interactivePostHtml(data, postId: '42'), '<button>Start</button>');
    });

    test('supports the known legacy mismatch with one t_f message', () {
      final data = '<script>outside();</script>${_message('<canvas></canvas>', id: '999')}';
      expect(interactivePostHtml(data, postId: '42'), '<canvas></canvas>');
    });

    test('does not guess between mismatched floors or duplicate exact ids', () {
      expect(
        interactivePostHtml(
          '${_message('<canvas></canvas>', id: '1')}${_message('<svg></svg>', id: '2')}',
          postId: '42',
        ),
        isNull,
      );
      expect(interactivePostHtml('${_message('<canvas></canvas>')}${_message('<svg></svg>')}', postId: '42'), isNull);
    });

    test('does not export an unclosed message with unknown boundaries', () {
      expect(interactivePostHtml('<div id="postmessage_42"><canvas></canvas>', postId: '42'), isNull);
    });

    test('keeps leading style and script in bare fragments byte for byte', () {
      const data =
          '  <style>.c { color: red; }</style>\n<script>start();</script><div class=c>Content &amp; text</div>  ';
      expect(interactivePostHtml(data, postId: '42'), data);
    });

    test('preserves a standalone table-cell message and omits its following script', () {
      const data = '<td class="t_f" id="postmessage_42"><canvas></canvas></td><script>outside();</script>';
      expect(interactivePostHtml(data, postId: '42'), '<canvas></canvas>');
    });

    test('ordinary authored message remains ordinary beside interactive forum markup', () {
      final data = '<style>.forum{}</style><script>forum();</script>${_message('<p>Hello</p>')}';
      expect(interactivePostHtml(data, postId: '42'), isNull);
    });
  });

  group('interactivePostHtml detection', () {
    for (final html in [
      '<style>.custom { display: grid; }</style><div class="custom">Layout</div>',
      '<svg viewBox="0 0 10 10"><path d="M0 0L10 10"/></svg>',
      '<canvas width="200" height="100"></canvas>',
      '<script src="custom.js"></script>',
      '<form action="custom.php"><input name="choice"></form>',
      '<input type="range" min="0" max="10">',
      '<select><option>A</option></select>',
      '<textarea>Custom input</textarea>',
      '<button>Play</button>',
      '<div onclick="play()">Play</div>',
      '<a href="#" onclick="customAction()">Play</a>',
      '<img src="picture.png" onclick="zoom(this); customAction()">',
      '<iframe src="https://example.com/game"></iframe>',
    ]) {
      test('recognizes $html', () {
        expect(interactivePostHtml(_message(html), postId: '42'), html);
      });
    }

    for (final html in [
      '',
      '<p>Ordinary text &amp; formatting</p>',
      '<div style="color: red; display: flex">Inline formatting</div>',
      '<img src="picture.png" onclick="zoom(this, this.src, 0, 0, 0)">',
      '<a href="forum.php" onclick="showWindow(\'view\', this.href);return false;">Link</a>',
      '<iframe src="https://music.163.com/outchain/player?type=2&amp;id=123"></iframe>',
      '<details><summary>More</summary><p>Hidden text</p></details>',
      '<input type="hidden" name="formhash" value="hash">',
      '<div onclick=" ">No action</div>',
      '<pre>&lt;script&gt;example()&lt;/script&gt;</pre>',
      '<div class="blockcode"><code>&lt;canvas&gt;</code><em onclick="copycode(this)">Copy</em></div>',
      '<div class="spoiler"><input class="spoiler_btn" type="button" onclick="toggle()"><div>Text</div></div>',
      '<form id="poll" onsubmit="vote()"><input type="checkbox"><button>Vote</button></form>',
      '<div class="hb-entry" onclick="hongbaoOpen(this)">Packet</div><div id="hb_mask"><button>Open</button></div>',
    ]) {
      test('leaves native content alone: $html', () {
        expect(interactivePostHtml(_message(html), postId: '42'), isNull);
      });
    }

    test('still detects authored interactions inside a spoiler body', () {
      const html =
          '<div class="spoiler"><input class="spoilerbutton" type="button" onclick="toggle()">\n'
          '<div class="spoilerbody"><canvas></canvas></div></div>';
      expect(interactivePostHtml(_message(html), postId: '42'), html);
    });
  });

  group('interactivePostHtml existing forum fixtures', () {
    test('preserves the FES form fixture and its real inline handler from thread 1266801', () {
      final html = File('android/app/src/androidTest/assets/fes_interactive_fixture.html').readAsStringSync();
      final data = '<script>forumOnly();</script>${_message(html, id: '78060680')}<button>Forum controls</button>';
      expect(interactivePostHtml(data, postId: '78060680'), html);
    });

    test('ordinary image zoom and code copy do not produce an entry', () {
      expect(interactivePostHtml(_fixture('post_div_align_x5.html'), postId: '1000'), isNull);
    });

    test('both supported spoiler structures do not produce an entry', () {
      expect(interactivePostHtml(_fixture('spoiler_post_x5.html'), postId: '1000'), isNull);
    });

    test('red packet controls and decoration outside the message do not produce an entry', () {
      expect(interactivePostHtml(_fixture('red_packet_post_x5.html'), postId: '77980494'), isNull);
    });

    test('a bare native poll fixture does not produce an entry', () {
      expect(interactivePostHtml(_fixture('poll_multiple_x5.html'), postId: '78025860'), isNull);
    });

    for (final name in ['poll_multiple_x5.html', 'poll_guest_x5.html', 'poll_voted_x5.html']) {
      test('$name remains outside the authored message', () {
        final data = '${_fixture(name)}${_message('<p>My poll</p>')}';
        expect(interactivePostHtml(data, postId: '42'), isNull);
      });
    }
  });
}

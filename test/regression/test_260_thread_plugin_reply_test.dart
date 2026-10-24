/// GitHub #239, 1.48.0: a reply to a thread of a thread plugin (`special` 127, fid 17 on the forum) was sent to the
/// browser ("这个回复表单有 App 暂不支持的栏位"): plugins before 3.2.0 list `threadplugin` in `unsupported` for every
/// form of such a thread, though the forum prints the plugin's fields only on a new thread and on the edit of its
/// first post (newthread.php, editpost.php `$isfirstpost && $specialextra`); a reply, the reply window or the edit of
/// another post of the thread has none.
///
/// The fixtures `post_v16_*.json` (plugin 2.9.0 answers on the test forum) as a thread plugin's thread serves them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';

const _dir = 'test/data/tsdmapp';

/// The fixture `post_v16_[name].json` as a form of a thread plugin's thread: `special` 127 with the plugin's id, and
/// [unsupported] as the plugin lists it; no other plugin's fields (`hook_fields`, tested elsewhere).
PostForm _pluginForm(String name, {List<String> unsupported = const ['threadplugin']}) {
  final json = jsonDecode(File('$_dir/post_v16_$name.json').readAsStringSync()) as Map<String, dynamic>;
  final special = Map<String, dynamic>.from(json['special'] as Map? ?? const {});
  json
    ..['special'] = {...special, 'current': 127, 'specialextra': 'sample_plugin'}
    ..['unsupported'] = unsupported
    ..['hook_fields'] = <Object?>[];
  return PostForm.fromJson(json)!;
}

void main() {
  group('a thread of a thread plugin', () {
    test('a reply (the page, the quoting reply, the reply window) is posted in the app', () {
      for (final name in ['reply', 'reply_quote', 'reply_float']) {
        final form = _pluginForm(name);
        expect(form.unsupported, ['threadplugin'], reason: name);
        expect(form.editorSupport('reply'), PostFormSupport.supported, reason: name);
      }
    });

    test('the edit of a post other than the first is taken by the editor', () {
      expect(_pluginForm('edit_reply').editorSupport('edit'), PostFormSupport.supported);
    });

    test("a new thread and the edit of the first post, which carry the plugin's fields, go to the website", () {
      expect(_pluginForm('newthread').editorSupport('newthread'), PostFormSupport.unsupported);
      expect(_pluginForm('edit_first').editorSupport('edit'), PostFormSupport.unsupported);
      // The reason alone is enough there, whatever `special` says.
      for (final (name, action) in [('newthread', 'newthread'), ('edit_first', 'edit')]) {
        final json = jsonDecode(File('$_dir/post_v16_$name.json').readAsStringSync()) as Map<String, dynamic>
          ..['unsupported'] = ['threadplugin']
          ..['hook_fields'] = <Object?>[];
        expect(PostForm.fromJson(json)!.editorSupport(action), PostFormSupport.unsupported, reason: name);
      }
    });

    test('other reasons still send a reply to the website', () {
      for (final reasons in [
        ['threadplugin', 'jsoneditor'],
        ['threadplugin', 'editorhook'],
        ['jsoneditor'],
      ]) {
        expect(
          _pluginForm('reply', unsupported: reasons).editorSupport('reply'),
          PostFormSupport.unsupported,
          reason: '$reasons',
        );
      }
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/cloudflare_email.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:universal_html/parsing.dart';

/// `[email=]` links come through Cloudflare's email obfuscation as `/cdn-cgi/l/email-protection#HASH` links that
/// opened a Cloudflare page in the browser instead of the mail app. The app decodes them like the browser script does.
///
/// Fixture: a post captured on 2026-09-06 with a test account, addresses are example.com.
String _data(String name) => File('test/data/$name').readAsStringSync();

/// Obfuscate [text] the way Cloudflare does, to build hashes for texts that must be rejected.
String _encode(int key, String text) =>
    [key, ...utf8.encode(text).map((b) => b ^ key)].map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('decodeCloudflareEmail', () {
    test('decodes the hashes of a real post', () {
      expect(decodeCloudflareEmail('c1a0ada8a2a481a4b9a0acb1ada4efa2aeac'), 'alice@example.com');
      expect(decodeCloudflareEmail('a8cac7cae8cdd0c9c5d8c4cd86cbc7c5'), 'bob@example.com');
      expect(decodeCloudflareEmail('e4868b86a4819c8589948881ca878b89'), 'bob@example.com');
      expect(decodeCloudflareEmail('82e1e3f0edeec2e7fae3eff2eee7ace1edef'), 'carol@example.com');
    });

    test('round trip with any key', () {
      expect(decodeCloudflareEmail(_encode(0x00, 'dave@example.org')), 'dave@example.org');
      expect(decodeCloudflareEmail(_encode(0xff, 'eve.smith+tag@sub.example.co')), 'eve.smith+tag@sub.example.co');
    });

    test('rejects malformed hashes', () {
      expect(decodeCloudflareEmail(''), isNull);
      expect(decodeCloudflareEmail('00'), isNull, reason: 'key only');
      expect(decodeCloudflareEmail('c1a0ada8a2a481a4b9a0acb1ada4efa2aea'), isNull, reason: 'odd length');
      expect(decodeCloudflareEmail('zz' * 10), isNull, reason: 'not hex');
      expect(decodeCloudflareEmail('${_encode(0x11, 'x')}ff'), isNull, reason: 'invalid utf-8 or not an address');
    });

    test('rejects text that is not an address, whatever a post tries to hide in it', () {
      for (final text in [
        'javascript:alert(1)',
        'https://evil.example/steal',
        'alice@example.com?subject=hi&body=x',
        'alice@example.com\nbcc:bob@example.com',
        'alice example.com',
        '@example.com',
        'alice@',
        'alice@localhost',
        '天使@例子.中国',
      ]) {
        expect(decodeCloudflareEmail(_encode(0x5a, text)), isNull, reason: text);
      }
    });
  });

  group('cloudflareEmailFromUrl', () {
    test('reads the hash of relative and absolute protection links', () {
      expect(cloudflareEmailFromUrl('/cdn-cgi/l/email-protection#c1a0ada8a2a481a4b9a0acb1ada4efa2aeac'), 'alice@example.com');
      expect(
        cloudflareEmailFromUrl('https://www.tsdm39.com/cdn-cgi/l/email-protection#c1a0ada8a2a481a4b9a0acb1ada4efa2aeac'),
        'alice@example.com',
      );
      expect(cloudflareEmailFromUrl('/cdn-cgi/l/email-protection'), isNull, reason: 'no hash');
      expect(cloudflareEmailFromUrl('https://www.tsdm39.com/forum.php#c1a0ada8a2a481a4b9a0acb1ada4efa2aeac'), isNull);
      expect(isCloudflareEmailUrl('/cdn-cgi/l/email-protection'), isTrue);
      expect(isCloudflareEmailUrl('forum.php?mod=viewthread&tid=1'), isFalse);
    });
  });

  group('rewriteCloudflareEmails', () {
    test('turns the three shapes in a post back into mailto links and readable addresses', () {
      final body = parseHtmlDocument(_data('email_protection_post_x5.html')).body!;
      expect(rewriteCloudflareEmails(body), 3);
      final links = body.querySelectorAll('a');
      expect(links.map((e) => e.attributes['href']), [
        'mailto:alice@example.com',
        'mailto:bob@example.com',
        'mailto:carol@example.com',
      ]);
      expect(links.map((e) => e.innerText.trim()), ['寫信給我', 'bob@example.com', 'carol@example.com']);
      expect(body.querySelectorAll('.__cf_email__'), isEmpty);
      expect(body.querySelectorAll('[data-cfemail]'), isEmpty);
      expect(rewriteCloudflareEmails(body), 0, reason: 'idempotent');
    });

    test('leaves a link alone when the hash is not an address', () {
      final body = parseHtmlDocument(
        '<div><a href="/cdn-cgi/l/email-protection#${_encode(0x33, 'https://evil.example/x')}">x</a> '
        '<span class="__cf_email__" data-cfemail="zz">[email&#160;protected]</span></div>',
      ).body!;
      expect(rewriteCloudflareEmails(body), 0);
      expect(body.querySelector('a')!.attributes['href'], startsWith('/cdn-cgi/l/email-protection#'));
      expect(body.querySelector('span')!.innerText, contains('protected'));
    });
  });

  testWidgets('the muncher renders the decoded addresses instead of the placeholders', (tester) async {
    final body = parseHtmlDocument(_data('email_protection_post_x5.html')).body!;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: Scaffold(body: Builder(builder: (context) => munchElement(context, body)))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('bob@example.com', findRichText: true), findsOneWidget);
    expect(find.textContaining('carol@example.com', findRichText: true), findsOneWidget);
    expect(find.textContaining('寫信給我', findRichText: true), findsOneWidget);
    expect(find.textContaining('protected', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

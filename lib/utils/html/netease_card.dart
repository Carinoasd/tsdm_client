import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' as fp;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Card to show a parsed netease iframe player.
class NeteaseCard extends StatefulWidget {
  /// Constructor.
  const NeteaseCard(this.id, {super.key});

  /// Song id.
  final String id;

  @override
  State<NeteaseCard> createState() => _NeteaseCardState();
}

class _NeteaseCardState extends State<NeteaseCard> with LoggerMixin {
  static const urlPrefix = 'https://music.163.com/song?id=';

  late String fallbackInfo;

  String _parseMusicInfo(String rawDocument) {
    final doc = parseHtmlDocument(rawDocument);
    final title = doc.querySelector('em.f-ff2')?.innerText;
    final artist = doc.querySelector('p.des.s-fc4 > span')?.title;

    if (title == null || artist == null) {
      error(
        'failed to parse netease music info (id ${widget.id}), '
        'title=$title, artist=$artist',
      );
      return fallbackInfo;
    }

    return '$artist - $title';
  }

  /// Song infos told, by id: a card built again (a floor scrolled back to) asks no more.
  static final _infoById = <String, String>{};

  /// The song info, asked once per card.
  late final Future<String> _info;

  Future<String> _loadInfo() async {
    if (_infoById[widget.id] case final info?) {
      return info;
    }
    final result = await getIt
        .get<NetClientProvider>(instanceName: ServiceKeys.noCookie)
        .get('$urlPrefix${widget.id}')
        .run();
    switch (result) {
      case fp.Left():
        return fallbackInfo;
      case fp.Right(:final value):
        final info = _parseMusicInfo(value.data as String);
        if (info != fallbackInfo) {
          _infoById.remove(widget.id);
          _infoById[widget.id] = info;
          while (_infoById.length > 64) {
            _infoById.remove(_infoById.keys.first);
          }
        }
        return info;
    }
  }

  @override
  void initState() {
    super.initState();
    fallbackInfo = 'id: ${widget.id}';
    _info = _loadInfo();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.musicCard;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final primaryStyle = Theme.of(context).textTheme.titleMedium?.copyWith(color: primaryColor);
    final infoStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.secondary);

    return Card(
      child: Padding(
        padding: edgeInsetsL16T16R16B16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.music_note_outlined, color: primaryColor),
                sizedBoxW8H8,
                // Wraps on a narrow screen with large text instead of overflowing.
                Flexible(child: Text(tr.title, style: primaryStyle)),
              ],
            ),
            sizedBoxW12H12,
            FutureBuilder(
              future: _info,
              initialData: _infoById[widget.id],
              builder: (context, snapshot) {
                if (snapshot.data case final info?) {
                  return Text(info, style: infoStyle);
                }
                return sizedCircularProgressIndicator;
              },
            ),
            sizedBoxW12H12,
            OutlinedButton.icon(
              icon: const Icon(Icons.launch_outlined),
              label: Text(tr.openLink),
              onPressed: () async => launchUrlString('$urlPrefix${widget.id}'),
            ),
          ],
        ),
      ),
    );
  }
}

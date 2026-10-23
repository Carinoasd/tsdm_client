import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post/repository/sec_check_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Ask the user to answer the captcha and the security question of [check] before the post goes (again); null when the
/// user cancels.
///
/// The image and the question are asked from the forum when the dialog opens (and again when the user asks for another
/// one); an answer is checked with the forum before the dialog closes, a wrong one gets a new image or a new question.
/// [wrongAnswer] says the previous answer was not taken. A check the app cannot show offers [browserUrl], the page to
/// continue on.
Future<SecCheckAnswer?> showSecCheckDialog(
  BuildContext context,
  SecCheck check, {
  bool wrongAnswer = false,
  String? browserUrl,
  SecCheckRepository repository = const SecCheckRepository(),
}) => showDialog<SecCheckAnswer>(
  context: context,
  barrierDismissible: false,
  builder: (context) => RootPage(
    DialogPaths.secCheck,
    SecCheckDialog(check: check, wrongAnswer: wrongAnswer, browserUrl: browserUrl, repository: repository),
  ),
);

/// The dialog of [showSecCheckDialog].
class SecCheckDialog extends StatefulWidget {
  /// Constructor.
  const SecCheckDialog({
    required this.check,
    required this.repository,
    this.wrongAnswer = false,
    this.browserUrl,
    super.key,
  });

  /// What to answer.
  final SecCheck check;

  /// Asks the forum.
  final SecCheckRepository repository;

  /// The previous answer was not taken.
  final bool wrongAnswer;

  /// The page to continue on when the check cannot be shown.
  final String? browserUrl;

  @override
  State<SecCheckDialog> createState() => _SecCheckDialogState();
}

class _SecCheckDialogState extends State<SecCheckDialog> with LoggerMixin {
  final _code = TextEditingController();
  final _answer = TextEditingController();

  Future<Uint8List?>? _image;
  Future<String?>? _question;

  /// The forum asks for something the app cannot show.
  bool _unsupported = false;

  String? _codeError;
  String? _answerError;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (widget.check.seccode) {
      _loadImage();
    }
    if (widget.check.secqaa) {
      _loadQuestion();
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _answer.dispose();
    super.dispose();
  }

  void _loadImage() {
    _image = widget.repository.fetchCaptcha(widget.check).run().then((result) {
      switch (result) {
        case Left(:final value):
          if (value is SecCheckUnsupportedException && mounted) {
            setState(() => _unsupported = true);
          }
          handle(value);
          return null;
        case Right(:final value):
          return value;
      }
    });
  }

  void _loadQuestion() {
    _question = widget.repository.fetchQuestion(widget.check).run().then((result) {
      switch (result) {
        case Left(:final value):
          if (value is SecCheckUnsupportedException && mounted) {
            setState(() => _unsupported = true);
          }
          handle(value);
          return null;
        case Right(:final value):
          return value;
      }
    });
  }

  Future<void> _confirm() async {
    final tr = context.t.secCheck;
    final check = widget.check;
    final code = _code.text.trim();
    final answer = _answer.text.trim();
    setState(() {
      _codeError = check.seccode && code.isEmpty ? tr.empty : null;
      _answerError = check.secqaa && answer.isEmpty ? tr.empty : null;
    });
    if (_codeError != null || _answerError != null) {
      return;
    }
    setState(() => _checking = true);
    // The forum only looks at the answers here; they count when the form is posted.
    final codeOk = check.seccode ? await widget.repository.verify(check, captcha: true, value: code) : true;
    final answerOk = check.secqaa ? await widget.repository.verify(check, captcha: false, value: answer) : true;
    if (!mounted) {
      return;
    }
    if (codeOk == false || answerOk == false) {
      setState(() {
        _checking = false;
        if (codeOk == false) {
          _codeError = tr.invalidCaptcha;
          _code.clear();
          _loadImage();
        }
        if (answerOk == false) {
          _answerError = tr.invalidAnswer;
          _answer.clear();
          // Another question: the forum lets an answer be checked a few times only.
          _loadQuestion();
        }
      });
      return;
    }
    Navigator.of(context).pop(SecCheckAnswer(check: check, seccode: code, secanswer: answer));
  }

  Widget _buildCaptcha(BuildContext context) {
    final tr = context.t.secCheck;
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: tr.refresh,
                child: InkWell(
                  key: const ValueKey('sec-check-captcha-image'),
                  borderRadius: BorderRadius.circular(appInnerRadius),
                  onTap: _checking ? null : () => setState(_loadImage),
                  child: Container(
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(appInnerRadius),
                    ),
                    child: FutureBuilder<Uint8List?>(
                      future: _image,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                        }
                        final bytes = snapshot.data;
                        if (bytes == null) {
                          return Text(
                            tr.loadFailed,
                            style: TextStyle(color: colorScheme.error),
                            textAlign: TextAlign.center,
                          );
                        }
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(appInnerRadius),
                          child: Image.memory(bytes, height: 56, fit: BoxFit.contain, gaplessPlayback: true),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: tr.refresh,
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _checking ? null : () => setState(_loadImage),
            ),
          ],
        ),
        sizedBoxW8H8,
        TextField(
          key: const ValueKey('sec-check-code-field'),
          controller: _code,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: widget.check.secqaa ? TextInputAction.next : TextInputAction.done,
          onSubmitted: widget.check.secqaa ? null : (_) => _confirm(),
          decoration: InputDecoration(labelText: tr.captcha, hintText: tr.captchaHint, errorText: _codeError),
        ),
      ],
    );
  }

  Widget _buildQuestion(BuildContext context) {
    final tr = context.t.secCheck;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: FutureBuilder<String?>(
                future: _question,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  }
                  final question = snapshot.data;
                  return Text(
                    question == null ? tr.loadFailed : '${tr.question}：$question',
                    key: const ValueKey('sec-check-question'),
                    style: textTheme.bodyLarge,
                  );
                },
              ),
            ),
            IconButton(
              tooltip: tr.refresh,
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _checking ? null : () => setState(_loadQuestion),
            ),
          ],
        ),
        sizedBoxW8H8,
        TextField(
          key: const ValueKey('sec-check-answer-field'),
          controller: _answer,
          autofocus: !widget.check.seccode,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _confirm(),
          decoration: InputDecoration(labelText: tr.answer, errorText: _answerError),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.secCheck;
    final browserUrl = widget.browserUrl;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.verified_user_outlined, title: tr.title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.wrongAnswer) ...[
              AppNoticeBanner(tone: AppNoticeTone.error, message: tr.wrongAnswer),
              sizedBoxW12H12,
            ],
            if (_unsupported)
              AppNoticeBanner(tone: AppNoticeTone.warning, message: tr.unsupported)
            else ...[
              Text(tr.message),
              sizedBoxW12H12,
              if (widget.check.seccode) _buildCaptcha(context),
              if (widget.check.seccode && widget.check.secqaa) sizedBoxW16H16,
              if (widget.check.secqaa) _buildQuestion(context),
            ],
          ],
        ),
      ),
      actions: [
        if (_unsupported && browserUrl != null)
          TextButton(
            onPressed: () async {
              try {
                await openInExternalBrowser(Uri.parse(browserUrl));
              } on Object catch (e) {
                error('failed to open the page in the browser: $e');
              }
            },
            child: Text(tr.openBrowser),
          ),
        TextButton(
          key: const ValueKey('sec-check-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t.general.cancel),
        ),
        if (!_unsupported)
          FilledButton(
            key: const ValueKey('sec-check-confirm'),
            onPressed: _checking ? null : _confirm,
            child: _checking
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(tr.confirm),
          ),
      ],
    );
  }
}

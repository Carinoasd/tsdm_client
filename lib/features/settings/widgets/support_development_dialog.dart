import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

final _featureRequestUri = Uri.https('github.com', '/Carinoasd/tsdm_client/issues/new', {
  'template': '02_feedback.yml',
});

/// Voluntary donations and feature requests, opened explicitly by the user.
class SupportDevelopmentDialog extends StatefulWidget {
  /// Constructor.
  const SupportDevelopmentDialog({super.key});

  /// Original donation image, bundled so it can also be viewed offline.
  static const imagePath = 'assets/images/alipay-donation.jpg';

  /// The forum announcement 「支援天使，重建经费征集」: donations to this app get its rewards too, on the same terms.
  static const forumRewardUrl = '$baseUrl/forum.php?mod=viewthread&tid=1266879';

  /// The maintainer's forum account the sponsor messages after paying (the rewards are handed out by hand).
  static const maintainerUid = '2042122';

  /// The maintainer's forum username, shown as the chat's title.
  static const maintainerUsername = '大和啦';

  @override
  State<SupportDevelopmentDialog> createState() => _SupportDevelopmentDialogState();
}

class _SupportDevelopmentDialogState extends State<SupportDevelopmentDialog> with LoggerMixin {
  bool _saving = false;
  bool _openingRequest = false;
  bool _requestOpenFailed = false;

  Future<void> _openFeatureRequest() async {
    if (_openingRequest) {
      return;
    }
    setState(() {
      _openingRequest = true;
      _requestOpenFailed = false;
    });
    var opened = false;
    try {
      opened = await openInExternalBrowser(_featureRequestUri);
    } on Object catch (e, st) {
      handleRaw(e, st);
    } finally {
      if (mounted) {
        setState(() {
          _openingRequest = false;
          _requestOpenFailed = !opened;
        });
      }
    }
  }

  Future<void> _saveImage() async {
    if (_saving) {
      return;
    }
    final tr = context.t.aboutPage;
    setState(() => _saving = true);
    try {
      final asset = await rootBundle.load(SupportDevelopmentDialog.imagePath);
      final bytes = asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: tr.saveDonationCode,
        fileName: 'tsdm-client-alipay.jpg',
        type: FileType.custom,
        allowedExtensions: ['jpg'],
        bytes: isDesktop ? null : bytes,
      );
      if (path == null) {
        return;
      }
      if (isDesktop) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (mounted) {
        showSnackBar(context: context, message: tr.donationCodeSaved);
      }
    } on Object catch (e, st) {
      handleRaw(e, st);
      if (mounted) {
        showSnackBar(context: context, message: tr.donationCodeSaveFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// Open the reward announcement in the app's thread page, in place of this dialog: a dialog left under the thread
  /// would keep its modal barrier (holding back notification taps) while the thread is read.
  Future<void> _openForumRewardAnnouncement() async {
    final route = SupportDevelopmentDialog.forumRewardUrl.parseUrlToRoute();
    final router = GoRouter.maybeOf(context);
    if (route == null || router == null) {
      error('can not open the forum reward announcement: no route');
      return;
    }
    Navigator.of(context).pop();
    await router.pushNamed(
      route.screenPath,
      pathParameters: route.pathParameters,
      queryParameters: route.queryParameters,
    );
  }

  /// Open a private message to the maintainer in place of this dialog (same reason as the announcement).
  Future<void> _messageMaintainer() async {
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      error('can not open the chat with the maintainer: no router');
      return;
    }
    Navigator.of(context).pop();
    await router.pushNamed(
      ScreenPaths.chat,
      pathParameters: {'uid': SupportDevelopmentDialog.maintainerUid},
      extra: <String, dynamic>{'username': SupportDevelopmentDialog.maintainerUsername},
    );
  }

  Future<void> _copyUsername(String username) async {
    await Clipboard.setData(ClipboardData(text: username));
    if (mounted) {
      showSnackBar(context: context, message: context.t.aboutPage.forumReward.usernameCopied);
    }
  }

  /// The rewards of the forum announcement, how to claim them and the account in use to write in the payment note.
  ///
  /// The account is the one the app acts as ([AuthenticationRepository.effectiveCurrentUser]), nothing is fetched.
  Widget _buildForumReward(BuildContext context) {
    final tr = context.t.aboutPage.forumReward;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bodyStyle = textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant);
    final strong = TextStyle(fontWeight: FontWeight.bold, color: colorScheme.onSurface);
    final tiers = [
      (tr.tier50.amount, tr.tier50.reward),
      (tr.tier100.amount, tr.tier100.reward),
      (tr.tier200.amount, tr.tier200.reward),
      (tr.tierEvery100.amount, tr.tierEvery100.reward),
      (tr.tier500.amount, tr.tier500.reward),
    ];
    final account = context.readOrNull<AuthenticationRepository>()?.effectiveCurrentUser;
    final username = account?.username;
    final uid = account?.uid;

    final Widget accountRow;
    if (username != null && username.isNotEmpty) {
      accountRow = AppInsetBlock(
        key: const ValueKey('forum-reward-account'),
        color: colorScheme.surface,
        padding: edgeInsetsL12T4R4B4,
        child: Row(
          children: [
            Icon(Icons.person_outline, size: 20, color: colorScheme.primary),
            sizedBoxW8H8,
            Expanded(
              child: Text(
                uid == null ? tr.accountNoUid(username: username) : tr.account(username: username, uid: uid),
                style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: tr.copyUsername,
              onPressed: () async => _copyUsername(username),
            ),
          ],
        ),
      );
    } else {
      accountRow = AppNoticeBanner(key: const ValueKey('forum-reward-guest'), message: tr.notLoggedIn);
    }

    return AppInsetBlock(
      outlined: true,
      color: colorScheme.primaryContainer.withValues(alpha: 0.3),
      padding: edgeInsetsL12T4R12B12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppSectionHeader(tr.title, icon: Icons.redeem_outlined),
          Text(tr.description, style: bodyStyle),
          const SizedBox(height: 4),
          for (final (amount, reward) in tiers)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Icon(Icons.circle, size: 6, color: colorScheme.primary),
                  ),
                  sizedBoxW8H8,
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: amount, style: strong),
                          TextSpan(text: tr.separator),
                          TextSpan(text: reward),
                        ],
                      ),
                      style: bodyStyle,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: tr.claimTitle, style: strong),
                TextSpan(text: tr.separator),
                TextSpan(text: tr.claim),
              ],
            ),
            style: bodyStyle,
          ),
          sizedBoxW8H8,
          accountRow,
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _messageMaintainer,
            icon: const Icon(Icons.email_outlined),
            label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr.messageMe, maxLines: 1)),
          ),
          sizedBoxW8H8,
          OutlinedButton.icon(
            onPressed: _openForumRewardAnnouncement,
            icon: const Icon(Icons.campaign_outlined),
            label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr.viewAnnouncement, maxLines: 1)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.aboutPage;
    final colorScheme = Theme.of(context).colorScheme;
    final mutedStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant);
    // The voluntary nature first, then the feature request block, then the forum rewards with how to claim them in
    // the payment note, right before the donation code on a white ground so it stays scannable in the dark theme.
    return AlertDialog(
      // One line: the longer name wrapped to two lines on a narrow phone (feedback on 1.29.1).
      title: AppDialogTitle(icon: Icons.volunteer_activism_outlined, title: tr.supportDevelopment, singleLine: true),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr.donationDescription, style: mutedStyle),
            const SizedBox(height: 16),
            AppInsetBlock(
              outlined: true,
              padding: edgeInsetsL12T4R12B12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppSectionHeader(tr.featureRequestTitle, icon: Icons.lightbulb_outline),
                  Text(tr.featureRequestDescription, style: mutedStyle),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _openingRequest ? null : _openFeatureRequest,
                    // No spinner while the browser opens: the disabled button is the pending state.
                    icon: const Icon(Icons.open_in_new),
                    label: FittedBox(fit: BoxFit.scaleDown, child: Text(tr.featureRequestAction, maxLines: 1)),
                  ),
                  if (_requestOpenFailed) ...[
                    const SizedBox(height: 8),
                    AppNoticeBanner(message: tr.featureRequestOpenFailed, tone: AppNoticeTone.error),
                    const SizedBox(height: 4),
                    SelectableText(
                      _featureRequestUri.toString(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.primary),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildForumReward(context),
            const SizedBox(height: 16),
            AppSectionHeader(tr.donationTitle, icon: Icons.qr_code_2_outlined),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(appInnerRadius),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(SupportDevelopmentDialog.imagePath, semanticLabel: tr.donationCodeLabel),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(tr.donationInstructions, style: mutedStyle),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _saving ? null : _saveImage,
          icon: const Icon(Icons.save_alt),
          label: Text(tr.saveDonationCode),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.close)),
      ],
    );
  }
}

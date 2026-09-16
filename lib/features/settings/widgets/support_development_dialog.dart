import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Voluntary maintainer donations, opened explicitly from the About page.
class SupportDevelopmentDialog extends StatefulWidget {
  /// Constructor.
  const SupportDevelopmentDialog({super.key});

  /// Original donation image, bundled so it can also be viewed offline.
  static const imagePath = 'assets/images/alipay-donation.jpg';

  @override
  State<SupportDevelopmentDialog> createState() => _SupportDevelopmentDialogState();
}

class _SupportDevelopmentDialogState extends State<SupportDevelopmentDialog> with LoggerMixin {
  bool _saving = false;

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

  @override
  Widget build(BuildContext context) {
    final tr = context.t.aboutPage;
    return AlertDialog(
      title: Text(tr.supportDevelopment),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr.donationDescription),
            const SizedBox(height: 16),
            Image.asset(SupportDevelopmentDialog.imagePath, semanticLabel: tr.donationCodeLabel),
            const SizedBox(height: 16),
            Text(tr.donationInstructions),
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

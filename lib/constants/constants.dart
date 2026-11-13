import 'dart:ui';

import 'package:tsdm_client/features/editor/widgets/toolbar.dart';
import 'package:tsdm_client/utils/git_info.dart';

/// App full version generated from the compile environment.
const appFullVersion =
    '$appVersion.$gitCommitRevisionShort '
    '($gitCommitCountCurrentBranch) '
    '($gitCommitTimeYear-$gitCommitTimeMonth-$gitCommitTimeDay)';

/// App logo asset path. Logo format: *.svg.
const assetsLogoSvgPath = './assets/images/tsdm_client.svg';

/// App logo asset path. Logo format: *.png.
const assetsLogoPngPath = './assets/images/tsdm_client.png';

/// App license content asset path. Used in license page.
const assetsLicensePath = './assets/text/LICENSE';

/// Dart logo
const assetDartLogoPath = './assets/images/dart.svg';

/// Path of all emoji related asset.
const assetEmojiDir = './assets/images/emoji/';

/// Bundled emoji.
const assetEmojiInfoPath = './assets/images/emoji/emoji.json';

/// Tiny placeholder image.
///
/// As part of workaround for the image data.
const assetPlaceholderImagePath = './assets/images/placeholder.png';

/// All features disabled by default.
///
/// Used in normal usages, disable these features to make concise toolbar
/// layout.
const Set<EditorFeatures> defaultEditorDisabledFeatures = {
  EditorFeatures.fontFamily,
  EditorFeatures.fontSize,
  EditorFeatures.bold,
  EditorFeatures.italic,
  EditorFeatures.underline,
  EditorFeatures.superscript,
  EditorFeatures.backgroundColor,
  EditorFeatures.clearFormat,
  EditorFeatures.alignLeft,
  EditorFeatures.alignCenter,
  EditorFeatures.alignRight,
  EditorFeatures.orderedList,
  EditorFeatures.bulletList,
  EditorFeatures.cut,
  EditorFeatures.copy,
  EditorFeatures.paste,
  EditorFeatures.codeBlock,
  EditorFeatures.quoteBlock,
  EditorFeatures.free,
};

/// All features disabled by default.
///
/// Used in normal usages, disable these features to remove noisy styles.
const Set<EditorFeatures> defaultFullScreenDisabledEditorFeatures = {
  EditorFeatures.fontFamily,
  EditorFeatures.cut,
  EditorFeatures.copy,
  EditorFeatures.paste,
  EditorFeatures.free,
};

/// Medal image size fixed to 34 x 55
const medalImageSize = Size(34, 55);

/// Badge image size fixed to 184 x 100
const badgeImageSize = Size(184, 100);

/// Primary pokemon image size, height is less 100 and not fixed.
const pokemonPrimaryImageSize = Size(90, 90);

/// Not primary size fixed to 32 x 32.
const pokemonNotPrimaryImageSize = Size(32, 32);

/// Feeling image size fixed to 60 x 60.
const feelingImageSize = Size(60, 60);

/// The maximum width of html content.
///
/// Server side render it with this boundary in browser.
const htmlContentMaxWidth = 712.0;

/// Prefix of all cookie.
///
/// Updated for the Discuz! X5 migration: the forum regenerated its cookie
/// prefix (seen in Set-Cookie as `Ystv_2132_*`). The old value `s_gkr8_682f`
/// no longer matches the `<prefix>_auth` cookie, so logins could not be saved.
const cookiePrefix = 'Ystv_2132';

/// The maximum count of recent used custom colors in editor.
const editorRecentUsedCustomColorsMaxCount = 8;

import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/features/image/utils/batch_image_save.dart';
import 'package:tsdm_client/features/image/widgets/post_image.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

/// The pictures of the floor content [html] in its order: those a floor opens its gallery with (not a smiley, an icon
/// of the forum or of a small size), without the repeated ones.
///
/// Read from the html, so floors that are not built (scrolled far away) have theirs too.
List<GalleryImage> galleryImagesOfHtml(String html) {
  final body = parseHtmlDocument(html).body;
  if (body == null) {
    return const [];
  }
  final images = <GalleryImage>[];
  for (final element in body.querySelectorAll('img')) {
    final dataSrc = element.attributes['data-src'];
    final url = (dataSrc != null && dataSrc.isNotEmpty) ? dataSrc.prependHost() : element.imageUrl();
    if (url == null || tmpImpellerWorkaroundUrls.contains(url)) {
      continue;
    }
    final width = element.attributes['width']?.parseToInt()?.toDouble();
    final height = element.attributes['height']?.parseToInt()?.toDouble();
    if (element.attributes.containsKey('smilieid') ||
        isForumStaticImage(url) ||
        isSmallImage(width: width, height: height)) {
      continue;
    }
    images.add(GalleryImage(url));
  }
  return distinctGalleryImages(images);
}

/// The pictures of the floor [post], none when its content is not shown.
List<GalleryImage> galleryImagesOfPost(Post post) => post.isSpoofed ? const [] : galleryImagesOfHtml(post.data);

/// The pictures of the floors [posts] in their order, without the repeated ones.
List<GalleryImage> galleryImagesOfPosts(Iterable<Post> posts) =>
    distinctGalleryImages([for (final post in posts) ...galleryImagesOfPost(post)]);

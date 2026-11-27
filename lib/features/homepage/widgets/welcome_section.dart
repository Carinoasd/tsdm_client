part of 'widgets.dart';

const double _kahrpbaPicWidth = 300;

/// Corner radius of a picture of the swiper: a little tighter than the cards around it, so the corners of a banner
/// (often text right to its edges) are not cut away.
const double _kahrpbaPicRadius = 16;

/// Width over height of the swiper before a picture told its own.
const double homeBannerDefaultRatio = 16 / 9;

/// The ratios (width over height) a picture may give the swiper: from 4:3 to 4:1. A picture outside of them (a tall
/// poster, a thin strip) does not shape the swiper, it is cropped to [homeBannerDefaultRatio].
const double homeBannerMinRatio = 4 / 3;

/// See [homeBannerMinRatio].
const double homeBannerMaxRatio = 4;

/// Least and most height of the swiper.
const double homeBannerMinHeight = 96;

/// See [homeBannerMinHeight].
const double homeBannerMaxHeight = 220;

/// Whether a picture of [size] may shape the swiper ([homeBannerMinRatio] to [homeBannerMaxRatio]).
bool homeBannerRatioAccepted(Size size) {
  if (size.width <= 0 || size.height <= 0) {
    return false;
  }
  final ratio = size.width / size.height;
  return ratio >= homeBannerMinRatio && ratio <= homeBannerMaxRatio;
}

/// Height of the swiper whose pictures are [width] wide and [ratio] (width over height; null before a picture told
/// it, or one out of range) in shape, kept between [homeBannerMinHeight] and [homeBannerMaxHeight].
double homeBannerHeight({double? ratio, double width = _kahrpbaPicWidth}) {
  final used = ratio != null && ratio >= homeBannerMinRatio && ratio <= homeBannerMaxRatio
      ? ratio
      : homeBannerDefaultRatio;
  return (width / used).clamp(homeBannerMinHeight, homeBannerMaxHeight);
}

/// A section of homepage, contains swiper and user info.
class WelcomeSection extends StatefulWidget {
  /// Constructor.
  const WelcomeSection({
    required this.forumStatus,
    required this.loggedUserInfo,
    required this.swiperUrlList,
    super.key,
  });

  /// Forum status.
  final ForumStatus forumStatus;

  /// Current logged user info.
  ///
  /// Null if no one logged.
  final LoggedUserInfo? loggedUserInfo;

  /// All urls used in swiper.
  final List<SwiperUrl> swiperUrlList;

  @override
  State<WelcomeSection> createState() => _WelcomeSectionState();
}

class _WelcomeSectionState extends State<WelcomeSection> with LoggerMixin {
  late final CarouselController _swiperController;
  Timer? _swiperTimer;
  bool _reverseSwiper = false;

  /// The shape of the first picture that loaded with one the swiper takes ([homeBannerRatioAccepted]); null before.
  final _bannerRatio = ValueNotifier<double?>(null);

  /// A picture was decoded: the first one of a usable shape gives the swiper its height. Told while the image
  /// builds, so the height changes after the frame.
  void _onBannerSize(Size size) {
    if (_bannerRatio.value != null || !homeBannerRatioAccepted(size)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _bannerRatio.value == null) {
        _bannerRatio.value = size.width / size.height;
      }
    });
  }

  /// The pictures in a row, each as wide as before and as high as their shape asks ([homeBannerHeight]), filled to
  /// their edges: no card behind them, no band above or under a banner that is flatter than the box.
  Widget _buildKahrpbaSwiper(BuildContext context, List<SwiperUrl> swiperUrlList) {
    return ValueListenableBuilder(
      valueListenable: _bannerRatio,
      builder: (context, ratio, _) => SizedBox(
        key: const ValueKey('home-banner'),
        height: homeBannerHeight(ratio: ratio),
        child: CarouselView(
          reverse: _reverseSwiper,
          controller: _swiperController,
          itemSnapping: true,
          itemExtent: _kahrpbaPicWidth,
          shrinkExtent: _kahrpbaPicWidth,
          // Only between the pictures: none above and under them.
          padding: const EdgeInsets.symmetric(horizontal: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_kahrpbaPicRadius)),
          onTap: (index) async {
            final parseResult = swiperUrlList[index].linkUrl.parseUrlToRoute();
            if (parseResult == null) {
              return;
            }
            await context.pushNamed(
              parseResult.screenPath,
              pathParameters: parseResult.pathParameters,
              queryParameters: parseResult.queryParameters,
            );
          },
          children: [
            for (final e in swiperUrlList)
              CachedImage(
                e.coverUrl,
                fit: BoxFit.cover,
                onImageSize: (size, {required downscaled}) => _onBannerSize(size),
              ),
          ],
        ),
      ),
    );
  }

  /// Forum status row, shown when the swiper is not available.
  Widget _buildForumStatusRow(BuildContext context, ForumStatus forumStatus) {
    final tr = context.t.homepage.forumStatus;
    final style = TextStyle(color: Theme.of(context).colorScheme.secondary);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: edgeInsetsL12T12R12B12,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Text('${tr.today}: ${forumStatus.todayCount}', style: style),
            Text('${tr.yesterday}: ${forumStatus.yesterdayCount}', style: style),
            Text('${tr.threads}: ${forumStatus.threadCount}', style: style),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context) {
    if (!context.mounted) {
      return sizedBoxEmpty;
    }

    // The swiper contents come from a customized block in forum homepage which no longer exists after the server
    // upgraded to Discuz! X5. Keep the swiper in case it comes back one day, show forum status instead when empty.
    if (widget.swiperUrlList.isEmpty) {
      return _buildForumStatusRow(context, widget.forumStatus);
    }

    return _buildKahrpbaSwiper(context, widget.swiperUrlList);
  }

  void setupSwiperTimer(int itemCount) {
    if (itemCount == 0) {
      return;
    }
    _swiperTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      double? target;
      if (_reverseSwiper) {
        if (_swiperController.offset <= 100) {
          setState(() {
            _reverseSwiper = false;
          });
        } else {
          target = _swiperController.offset - _kahrpbaPicWidth;
        }
      } else {
        if (_swiperController.offset >= (itemCount - 3) * _kahrpbaPicWidth) {
          setState(() {
            _reverseSwiper = true;
          });
        } else {
          target = _swiperController.offset + _kahrpbaPicWidth;
        }
      }
      if (target != null) {
        unawaited(_swiperController.animateTo(target, duration: duration200, curve: Curves.ease));
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _swiperController = CarouselController();
    setupSwiperTimer(widget.swiperUrlList.length);
  }

  @override
  void dispose() {
    _swiperTimer?.cancel();
    _bannerRatio.dispose();
    _swiperController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<HomepageBloc, HomepageState>(
      listenWhen: (prev, curr) => prev.scrollSwiper != curr.scrollSwiper,
      listener: (context, state) {
        // Resume or pause the scroll of welcome swiper according to whether we
        // are in the home tab.
        //
        // The info about in home tab or not is passed from shell route builder.
        if (state.scrollSwiper) {
          setupSwiperTimer(widget.swiperUrlList.length);
        } else {
          _swiperTimer?.cancel();
        }
      },
      child: _buildSection(context),
    );
  }
}

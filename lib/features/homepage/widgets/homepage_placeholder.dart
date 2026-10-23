part of 'widgets.dart';

/// Placeholder widget for the page.
///
/// The skeleton of the homepage while its first load runs, laid out as the phone homepage: the greeting card with
/// the actions of the day, the support entry, a card with tabs (the pinned threads, the guide) and its rows.
class HomepagePlaceholder extends StatelessWidget {
  /// Constructor.
  const HomepagePlaceholder({super.key});

  Widget _tabsCard() => AppSurface(
    child: LoadingShimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SkeletonBlock(width: 64, height: 18),
              sizedBoxW16H16,
              SkeletonBlock(width: 64, height: 18),
              sizedBoxW16H16,
              SkeletonBlock(width: 64, height: 18),
            ],
          ),
          for (var i = 0; i < 5; i++) ...[
            sizedBoxW16H16,
            SkeletonBlock(widthFactor: i.isEven ? 0.92 : 0.78),
            sizedBoxW4H4,
            const SkeletonBlock(widthFactor: 0.4, height: 12),
          ],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SkeletonSemantics(
      child: AppCenteredList(
        builder: (context, side, _) => ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: side.copyWith(top: 12, bottom: 12),
          children: <Widget>[
            const AppSurface(
              child: LoadingShimmer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBlock(width: 140, height: 22),
                              sizedBoxW8H8,
                              SkeletonBlock(width: 180),
                            ],
                          ),
                        ),
                        sizedBoxW12H12,
                        SkeletonBlock(width: 96, height: 52, radius: 8),
                      ],
                    ),
                    sizedBoxW16H16,
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        SkeletonBlock(width: 96, height: 36, radius: 18),
                        SkeletonBlock(width: 96, height: 36, radius: 18),
                        SkeletonBlock(width: 96, height: 36, radius: 18),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const AppSurface(
              child: LoadingShimmer(
                child: Row(
                  children: [
                    SkeletonBlock(width: 32, height: 32, radius: appInnerRadius),
                    sizedBoxW12H12,
                    Expanded(child: SkeletonBlock(widthFactor: 0.7)),
                  ],
                ),
              ),
            ),
            _tabsCard(),
            _tabsCard(),
          ].insertBetween(sizedBoxW12H12),
        ),
      ),
    );
  }
}

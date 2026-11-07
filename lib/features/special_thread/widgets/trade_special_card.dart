part of 'special_thread_card.dart';

/// The goods of a trade thread in the page's order: picture, name, recommended and quality, price in money and in
/// the site's trade credit with the original price struck through, the time left or the end of the trade, a deleted
/// goods as the page says it. A goods opens its page in the app ([openTradeGoodsPage]: the details the thread page
/// does not carry, buying a goods sold for credit, only with [onReload]: not in an offline copy nor a notice's post);
/// sorting and adding goods open the web page.
class _TradeCard extends StatelessWidget {
  const _TradeCard(this.trade, {this.onReload});

  final TradeSpecial trade;

  /// Reload the thread page after a purchase; null: no buying here.
  final VoidCallback? onReload;

  Future<void> _open(BuildContext context, TradeGoods goods) async {
    final target = tradeGoodsOfUrl(goods.url);
    if (target == null) {
      return _openInBrowser(context, goods.url!);
    }
    return openTradeGoodsPage(
      context,
      tid: target.tid,
      pid: target.pid,
      goods: goods,
      creditUnit: trade.creditUnit,
      canBuy: onReload != null,
      onBought: onReload,
    );
  }

  String _price(BuildContext context, num money, int credit) {
    final tr = context.t.specialThread.trade;
    final unit = trade.creditUnit;
    return [
      if (money > 0) tr.price(price: _number(money)),
      if (credit > 0 && unit != null) tr.credit(credit: credit, unit: '${unit.title}${unit.unit}'),
    ].join(' + ');
  }

  Widget _goods(BuildContext context, TradeGoods goods) {
    final tr = context.t.specialThread.trade;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    if (goods.removed) {
      return AppInsetBlock(
        color: colorScheme.surfaceContainerHigh,
        child: Row(
          children: [
            Icon(Icons.remove_shopping_cart_outlined, size: 18, color: colorScheme.outline),
            sizedBoxW8H8,
            Expanded(
              child: Text(tr.removed, style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline)),
            ),
          ],
        ),
      );
    }
    final picture = goods.thumb ?? goods.image;
    final price = _price(context, goods.price, goods.credit);
    final original = _price(context, goods.costPrice, goods.costCredit);
    final meta = [
      if (goods.sticky) tr.recommended,
      if (goods.quality == 1) tr.qualityNew else if (goods.quality == 2) tr.qualityUsed,
      if (goods.timeout)
        tr.ended
      else if (goods.remain case final remain?)
        tr.remain(days: remain.days, hours: remain.hours),
    ].join(' · ');
    final body = AppInsetBlock(
      color: colorScheme.surfaceContainerHigh,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(appInnerRadius),
            child: SizedBox(
              width: 64,
              height: 64,
              child: picture == null
                  ? ColoredBox(
                      color: colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.shopping_bag_outlined, color: colorScheme.outline),
                    )
                  : CachedImage(picture, width: 64, height: 64, fit: BoxFit.cover),
            ),
          ),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(goods.subject, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    style: textTheme.labelSmall?.copyWith(
                      color: goods.timeout ? colorScheme.error : colorScheme.outline,
                    ),
                  ),
                if (price.isNotEmpty) ...[
                  sizedBoxW4H4,
                  Text(price, style: textTheme.bodyLarge?.copyWith(color: colorScheme.primary)),
                ],
                if (original.isNotEmpty)
                  Text(
                    original,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.outline,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
              ],
            ),
          ),
          if (goods.url != null) Icon(Icons.chevron_right, size: 20, color: colorScheme.outline),
        ],
      ),
    );
    if (goods.url == null) {
      return body;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(appInnerRadius),
      onTap: () async => _open(context, goods),
      child: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.trade;
    return AppEmbedCard(
      icon: Icons.storefront_outlined,
      title: tr.title,
      subtitle: trade.count == null ? null : tr.count(count: trade.count!),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (trade.goods.isEmpty) ...[
            Text(tr.noGoods, style: Theme.of(context).textTheme.bodyMedium),
            sizedBoxW8H8,
          ],
          for (final goods in trade.goods) ...[_goods(context, goods), sizedBoxW8H8],
          if ((trade.canManage && trade.manageUrl != null) || (trade.canAdd && trade.addUrl != null))
            Wrap(
              spacing: 8,
              children: [
                if (trade.canManage && trade.manageUrl != null)
                  TextButton.icon(
                    onPressed: () async => _openInBrowser(context, trade.manageUrl!),
                    icon: const Icon(Icons.sort),
                    label: Text(tr.manage),
                  ),
                if (trade.canAdd && trade.addUrl != null)
                  TextButton.icon(
                    onPressed: () async => _openInBrowser(context, trade.addUrl!),
                    icon: const Icon(Icons.add_shopping_cart_outlined),
                    label: Text(tr.add),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

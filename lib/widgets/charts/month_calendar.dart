import 'package:flutter/material.dart';

/// A month as a grid of days, the [marked] days filled and [today] outlined, with arrows to the months around.
///
/// The weeks start on Sunday. The title and the weekday letters come from the localizations of the app.
class MonthCalendar extends StatelessWidget {
  /// Constructor.
  const MonthCalendar({
    required this.month,
    required this.marked,
    required this.today,
    required this.onPrevious,
    required this.onNext,
    super.key,
  });

  /// Any day of the month shown.
  final DateTime month;

  /// The days of [month] to fill, as day numbers (1-31).
  final Set<int> marked;

  /// Today, outlined when it is in [month].
  final DateTime today;

  /// Show the month before; null disables the arrow.
  final VoidCallback? onPrevious;

  /// Show the month after; null disables the arrow.
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final first = DateTime(month.year, month.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Sunday first: DateTime.sunday is 7.
    final offset = first.weekday % 7;
    final rows = ((offset + daysInMonth) / 7).ceil();
    final isThisMonth = today.year == month.year && today.month == month.month;
    final letters = localizations.narrowWeekdays;

    Widget cell(int index) {
      final day = index - offset + 1;
      if (day < 1 || day > daysInMonth) {
        return const SizedBox.shrink();
      }
      final isMarked = marked.contains(day);
      final isToday = isThisMonth && today.day == day;
      return Center(
        child: Semantics(
          label: isToday ? '$day, ${localizations.currentDateLabel}' : '$day',
          selected: isMarked,
          container: true,
          excludeSemantics: true,
          child: Container(
            key: ValueKey('calendar-day-$day'),
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isMarked ? colorScheme.primary : null,
              border: isToday ? Border.all(color: colorScheme.primary, width: 2) : null,
            ),
            child: Text(
              '$day',
              style: textTheme.bodyMedium?.copyWith(
                color: isMarked ? colorScheme.onPrimary : colorScheme.onSurface,
                fontWeight: isMarked || isToday ? FontWeight.bold : null,
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('calendar-previous'),
              tooltip: localizations.previousMonthTooltip,
              icon: const Icon(Icons.chevron_left),
              onPressed: onPrevious,
            ),
            Expanded(
              child: Text(
                localizations.formatMonthYear(first),
                textAlign: TextAlign.center,
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              key: const ValueKey('calendar-next'),
              tooltip: localizations.nextMonthTooltip,
              icon: const Icon(Icons.chevron_right),
              onPressed: onNext,
            ),
          ],
        ),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(
                    letters[i],
                    style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
          ],
        ),
        for (var row = 0; row < rows; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                for (var column = 0; column < 7; column++) Expanded(child: cell(row * 7 + column)),
              ],
            ),
          ),
      ],
    );
  }
}

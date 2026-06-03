import 'package:flutter/material.dart';

/// 仿苹果日历的年月快速选择器
///
/// 显示年份（上下箭头快速切换）和 12 个月份网格，
/// 点击月份后返回选中的年月。
class YearMonthPicker extends StatelessWidget {
  final int initialYear;
  final int initialMonth;

  const YearMonthPicker({
    super.key,
    required this.initialYear,
    required this.initialMonth,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: _YearMonthPickerStateful(
        initialYear: initialYear,
        initialMonth: initialMonth,
      ),
    );
  }

  /// 弹出选择器并返回 `DateTime(year, month, 1)`，取消返回 null
  static Future<DateTime?> show(
    BuildContext context, {
    required int year,
    required int month,
  }) {
    return showDialog<DateTime>(
      context: context,
      builder: (_) => YearMonthPicker(initialYear: year, initialMonth: month),
    );
  }
}

class _YearMonthPickerStateful extends StatefulWidget {
  final int initialYear;
  final int initialMonth;

  const _YearMonthPickerStateful({
    required this.initialYear,
    required this.initialMonth,
  });

  @override
  State<_YearMonthPickerStateful> createState() =>
      _YearMonthPickerStatefulState();
}

class _YearMonthPickerStatefulState extends State<_YearMonthPickerStateful> {
  late int _year;
  static const _months = [
    '1月', '2月', '3月', '4月', '5月', '6月',
    '7月', '8月', '9月', '10月', '11月', '12月',
  ];

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 年份 + 箭头
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _year--),
              ),
              Text(
                '$_year年',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _year++),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 12 个月网格 (3×4)
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 8,
            crossAxisSpacing: 12,
            childAspectRatio: 2.2,
            children: List.generate(12, (i) {
              final month = i + 1;
              final isCurrent =
                  month == widget.initialMonth && _year == widget.initialYear;
              return Material(
                color: isCurrent
                    ? cs.primary
                    : cs.surfaceContainerHighest.withAlpha(80),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => Navigator.pop(
                    context,
                    DateTime(_year, month, 1),
                  ),
                  child: Center(
                    child: Text(
                      _months[i],
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? cs.onPrimary : cs.onSurface,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

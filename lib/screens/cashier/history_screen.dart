import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../data/app_data.dart';
import '../../data/mock_data.dart';
import '../../models/invoice.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_header_band.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/invoice_card.dart';
import '../../widgets/live_data.dart';

/// Tab Lịch sử: hóa đơn đã thanh toán, gom theo ngày kèm tổng tiền từng ngày.
///
/// Mặc định chỉ hiện hóa đơn do chính thu ngân này thu ("Của tôi"); chuyển "Cả quán" để xem
/// của mọi thu ngân. Trước đây trộn mọi thu ngân, mọi ngày vào một danh sách.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool _mineOnly = true;

  @override
  Widget build(BuildContext context) =>
      LiveData(sources: const {LiveSource.invoices}, builder: _buildContent);

  bool _isMine(Invoice i) {
    final me = MockData.currentCashier;
    return i.cashierId != null ? i.cashierId == me.id : i.cashierName == me.name;
  }

  Widget _buildContent(BuildContext context, Future<void> Function() refresh) {
    // Server đã sắp mới nhất trước; hóa đơn mẫu thì thêm vào sau nên đảo lại cho giống.
    final all = MockData.invoices.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final invoices = _mineOnly ? all.where(_isMine).toList() : all;

    // Gom theo ngày (giữ thứ tự mới nhất trước).
    final days = <DateTime, List<Invoice>>{};
    for (final i in invoices) {
      days.putIfAbsent(DateUtils.dateOnly(i.createdAt), () => []).add(i);
    }

    final children = <Widget>[];
    var index = 0;
    for (final entry in days.entries) {
      final total = entry.value.fold<double>(0, (sum, i) => sum + i.total);
      final isToday = DateUtils.isSameDay(entry.key, DateTime.now());
      children.add(Padding(
        padding: EdgeInsets.fromLTRB(4, children.isEmpty ? 0 : 14, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                isToday ? 'Hôm nay · ${AppFormatters.weekdayDate(entry.key)}' : AppFormatters.weekdayDate(entry.key),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.textPrimary),
              ),
            ),
            Text('${entry.value.length} hóa đơn · ${AppFormatters.currency(total)}',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          ],
        ),
      ));
      for (final invoice in entry.value) {
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: FadeSlideIn.staggered(
            index: index++,
            child: InvoiceCard(
              invoice: invoice,
              onTap: () => Navigator.of(context).pushNamed(AppRoutes.cashierInvoice, arguments: invoice),
            ),
          ),
        ));
      }
    }

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      body: Column(
        children: [
          AppHeaderBand(caption: '${invoices.length} hóa đơn đã thanh toán', title: 'Lịch sử thanh toán'),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              children: [
                _chip('Của tôi', true),
                const SizedBox(width: 8),
                _chip('Cả quán', false),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: refresh,
              child: invoices.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 60),
                        EmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: 'Chưa có hóa đơn nào',
                          message: _mineOnly
                              ? 'Hóa đơn bạn thu sẽ hiển thị tại đây. Chọn "Cả quán" để xem của mọi thu ngân.'
                              : 'Các hóa đơn đã thanh toán sẽ hiển thị tại đây',
                        ),
                      ],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      children: children,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool mine) {
    final selected = _mineOnly == mine;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 13,
        color: selected ? AppColors.textOnDark : AppColors.textPrimary,
      ),
      selectedColor: AppColors.ink,
      backgroundColor: AppColors.surface,
      side: BorderSide(color: selected ? AppColors.ink : AppColors.border),
      onSelected: (_) => setState(() => _mineOnly = mine),
    );
  }
}

import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../data/app_data.dart';
import '../../data/mock_data.dart';
import '../../data/shift_repository.dart';
import '../../models/shift.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_header_band.dart';
import '../../widgets/live_data.dart';
import 'cashier_shell.dart';
import 'shift_screen.dart';

/// Tab Tổng quan của Thu ngân.
///
/// - Thẻ ca nghe [ShiftRepository.current] nên mở / đóng ca ở đâu cũng cập nhật ngay (trước đây
///   mở ca xong Tổng quan vẫn ghi "Chưa mở"), và tự tải lại khi có hóa đơn mới.
/// - Chưa mở ca thì có nút "Mở ca" ngay trên thẻ: chưa mở ca thì không thu tiền được.
/// - Ghi rõ số nào của CA (của thu ngân này), số nào của CẢ QUÁN hôm nay.
/// - Bỏ hàng "Truy cập nhanh" trùng với thanh điều hướng dưới; giữ lối vào Lịch đặt bàn.
class CashierDashboardScreen extends StatelessWidget {
  const CashierDashboardScreen({super.key});

  /// Mở một tab khác trong khung Thu ngân; nếu màn này đang được mở riêng lẻ
  /// (không nằm trong khung) thì mở màn tương ứng như trước.
  static void _open(BuildContext context, CashierTab tab, String fallbackRoute) {
    if (CashierShell.goTo(context, tab)) return;
    Navigator.of(context).pushNamed(fallbackRoute);
  }

  /// Số liệu lấy từ đơn + hóa đơn thật, tự tải mới khi mở màn và khi dữ liệu đổi.
  @override
  Widget build(BuildContext context) => LiveData(
        sources: const {LiveSource.orders, LiveSource.invoices},
        builder: (context, refresh) => _buildContent(context, refresh),
      );

  Widget _buildContent(BuildContext context, Future<void> Function() refresh) {
    final user = MockData.currentCashier;
    final pendingCount = MockData.pendingPaymentOrders.length;
    final pendingTotal = MockData.pendingPaymentOrders.fold<double>(0, (sum, o) => sum + o.subtotal);
    final paidCount = MockData.todayInvoices.length;

    var order = 0;
    Widget step(Widget child) => FadeSlideIn.staggered(index: order++, child: child);

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      body: Column(
        children: [
          AppHeaderBand(
            caption: '${user.name} · Thu ngân',
            title: 'Tổng quan',
            showBack: false,
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await Future.wait([refresh(), ShiftRepository.instance.fetchCurrent().then((_) {})]);
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  step(_ShiftCard(onDetail: () => _open(context, CashierTab.shift, AppRoutes.cashierShift))),
                  const SizedBox(height: 12),
                  step(Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _CountTile(
                          value: '$pendingCount',
                          label: 'Đơn chờ thanh toán',
                          caption: pendingCount == 0 ? null : AppFormatters.currency(pendingTotal),
                          onTap: () => _open(context, CashierTab.pending, AppRoutes.cashierPendingPayment),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _CountTile(
                          value: '$paidCount',
                          label: 'Hóa đơn hôm nay (cả quán)',
                          onTap: () => _open(context, CashierTab.history, AppRoutes.cashierHistory),
                        ),
                      ),
                    ],
                  )),
                  const SizedBox(height: 12),
                  step(Container(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Doanh thu cả quán hôm nay',
                            style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary)),
                        const SizedBox(height: 4),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: CountUpText(
                            value: MockData.computedTodayRevenue,
                            formatter: (v) => AppFormatters.currency(v.round()),
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        // Đếm cùng nguồn với số tiền phía trên (hóa đơn đã thu hôm nay), không
                        // đếm đơn mới tạo — đơn chưa trả chưa có tiền, đơn hôm qua trả hôm nay vẫn có tiền.
                        Text('Từ ${MockData.todayInvoices.length} hóa đơn đã thanh toán · gồm mọi thu ngân',
                            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                      ],
                    ),
                  )),
                  const SizedBox(height: 12),
                  step(_LinkCard(
                    icon: Icons.event_note_rounded,
                    title: 'Lịch đặt bàn',
                    subtitle: 'Khách đặt trước, tiền cọc · nhận bàn khi khách tới',
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.reservationList),
                  )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thẻ ca hiện tại, nghe [ShiftRepository.current].
///
/// - Chưa mở ca → nói rõ chưa thu tiền được + nút "Mở ca" (mở hộp ngay tại đây).
/// - Đang mở ca → giờ bắt đầu, số hóa đơn và tổng thu của ca, nút "Chi tiết" sang tab Ca làm.
class _ShiftCard extends StatefulWidget {
  final VoidCallback onDetail;

  const _ShiftCard({required this.onDetail});

  @override
  State<_ShiftCard> createState() => _ShiftCardState();
}

class _ShiftCardState extends State<_ShiftCard> {
  final _repo = ShiftRepository.instance;

  @override
  void initState() {
    super.initState();
    MockData.invoicesVersion.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    MockData.invoicesVersion.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      await _repo.fetchCurrent();
    } catch (_) {
      // Lỗi tải ca: giữ trạng thái đang có; thu ngân có thể kéo xuống để thử lại.
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Shift?>(
      valueListenable: _repo.current,
      builder: (context, shift, _) {
        final loading = !_repo.loaded;
        final open = shift != null && shift.isOpen;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: open || loading ? AppColors.surface : AppColors.warningBg,
            borderRadius: BorderRadius.circular(20),
            border: open || loading ? null : Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(open ? Icons.storefront_outlined : Icons.lock_clock_outlined,
                    color: AppColors.textPrimary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: loading
                    ? const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Placeholder(width: 100, height: 13),
                          SizedBox(height: 6),
                          _Placeholder(width: 160, height: 15),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            open ? 'Ca của bạn · mở từ ${AppFormatters.time(shift.openedAt)}' : 'Bạn chưa mở ca',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            open
                                ? '${shift.invoiceCount} hóa đơn · ${AppFormatters.currency(shift.revenueByMethod.total)}'
                                : 'Chưa thu tiền được cho tới khi mở ca',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              PressScale(
                onTap: loading ? null : (open ? widget.onDetail : () => showOpenShiftDialog(context)),
                scale: 0.92,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: open ? null : AppColors.ink,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: AppColors.ink, width: 1.3),
                  ),
                  child: Text(open ? 'Chi tiết' : 'Mở ca',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: open ? AppColors.textPrimary : AppColors.textOnDark)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Khung xám mờ dùng làm placeholder khi đang load ca.
class _Placeholder extends StatelessWidget {
  final double width;
  final double height;

  const _Placeholder({required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// Ô đếm: số lớn + nhãn hai dòng (+ dòng phụ), chạm để mở tab tương ứng.
class _CountTile extends StatelessWidget {
  final String value;
  final String label;
  final String? caption;
  final VoidCallback onTap;

  const _CountTile({required this.value, required this.label, required this.onTap, this.caption});

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        constraints: const BoxConstraints(minHeight: 96),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(value,
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textSecondary),
              ],
            ),
            const SizedBox(height: 2),
            Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.3)),
            if (caption != null)
              Text(caption!,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }
}

/// Thẻ một dòng dẫn tới màn khác (Lịch đặt bàn).
class _LinkCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _LinkCard({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: AppColors.textPrimary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  Text(subtitle, style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

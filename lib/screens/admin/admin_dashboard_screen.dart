import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../core/api/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/app_data.dart';
import '../../data/mock_data.dart';
import '../../data/reservation_repository.dart';
import '../../models/reservation.dart';
import '../../models/revenue.dart';
import '../../models/table_model.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/live_data.dart';
import '../../widgets/mock_bar_chart.dart';
import '../../widgets/section_header.dart';
import '../../widgets/stat_card.dart';
import 'admin_more_screen.dart';

/// Số cột của lưới thống kê theo bề ngang màn hình: điện thoại 2 cột,
/// tablet/nửa cửa sổ desktop 3 cột, cửa sổ đủ rộng hiển thị cả 4 thẻ trên
/// một hàng.
int _statGridColumns(double width) {
  if (width >= 900) return 4;
  if (width >= 600) return 3;
  return 2;
}

/// Dashboard tổng quan của Admin.
///
/// Phần trên là tình hình **đang diễn ra** (bàn, đơn chờ thu, lượt đặt, đơn hủy hôm nay) —
/// thứ quản lý cần nhìn trong giờ phục vụ. Phần dưới là doanh thu; chi tiết (món bán chạy,
/// chọn khoảng ngày, xuất Excel) nằm ở tab Báo cáo nên không lặp lại ở đây.
class AdminDashboardScreen extends StatefulWidget {
  /// Chuyển sang tab Bàn / Báo cáo của khung Admin (null khi màn được mở riêng).
  final VoidCallback? onOpenTables;
  final VoidCallback? onOpenReports;

  const AdminDashboardScreen({super.key, this.onOpenTables, this.onOpenReports});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  /// Lượt đặt và đơn hủy trong hôm nay: không nằm trong kho dữ liệu chung nên tải riêng.
  List<Reservation>? _reservations;
  int? _cancelledCount;

  @override
  void initState() {
    super.initState();
    _loadToday();
  }

  Future<void> _loadToday() async {
    final today = DateUtils.dateOnly(DateTime.now());
    // Mỗi phần lỗi thì chỉ phần đó hiện "—", không chặn cả Dashboard.
    await Future.wait([
      () async {
        try {
          final list = await ReservationRepository.instance.fetchForDate(today);
          if (mounted) setState(() => _reservations = list);
        } on ApiException {
          // giữ số cũ
        }
      }(),
      () async {
        try {
          final result = await AdminRepository.instance.fetchCancelledOrders(today);
          if (mounted) setState(() => _cancelledCount = result.orders.length);
        } on ApiException {
          // giữ số cũ
        }
      }(),
    ]);
  }

  /// Số liệu lấy từ báo cáo của server, tự tải mới khi mở màn và khi kéo để làm mới.
  @override
  Widget build(BuildContext context) => LiveData(
        sources: const {LiveSource.report, LiveSource.tables, LiveSource.orders},
        builder: _buildContent,
      );

  Widget _buildContent(BuildContext context, Future<void> Function() refresh) {
    final report = MockData.report;
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(
        // Ngày nằm ngay dưới tiêu đề thay cho một dòng riêng trong danh sách.
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Tổng quan'),
            Text('Hôm nay · ${AppFormatters.weekdayDate(now)}',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.logout_rounded, color: AppColors.error),
            tooltip: 'Đăng xuất',
            onPressed: () => confirmAdminSignOut(context),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () => Future.wait([refresh(), _loadToday()]),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              // Doanh thu là số quản lý xem đầu tiên → một khối nổi bật thay cho 4 ô cùng cỡ.
              FadeSlideIn(child: _RevenueHero(report: report, onOpenReports: widget.onOpenReports)),
              const SizedBox(height: 20),
              const FadeSlideIn(child: SectionHeader(title: 'Đang diễn ra')),
              const SizedBox(height: 10),
              FadeSlideIn(child: _statGrid(_operationCards(context))),
              const SizedBox(height: 20),
              FadeSlideIn(
                delay: const Duration(milliseconds: 80),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('Doanh thu 7 ngày',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary)),
                          ),
                          if (widget.onOpenReports != null)
                            TextButton(
                              onPressed: widget.onOpenReports,
                              child: const Text('Xem báo cáo'),
                            ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: MockBarChart(data: report.revenueByDay, height: 140),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Lưới ô "Đang diễn ra": 2 cột trên điện thoại, nhiều cột hơn trên màn rộng; ô thấp gọn
  /// (biểu tượng nằm cùng hàng với con số) thay cho ô cao 150.
  Widget _statGrid(List<Widget> children) => LayoutBuilder(
        builder: (context, constraints) => GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _statGridColumns(constraints.maxWidth),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 98,
          ),
          children: children,
        ),
      );

  List<Widget> _operationCards(BuildContext context) {
    final tables = MockData.tables;
    final serving = tables.where((t) => t.status == TableStatus.serving).length;
    final reserved = tables.where((t) => t.status == TableStatus.reserved).length;
    final empty = tables.where((t) => t.status == TableStatus.empty).length;

    final pending = MockData.pendingPaymentOrders;
    final pendingTotal = pending.fold<double>(0, (sum, o) => sum + o.subtotal);

    final now = DateTime.now();
    final upcoming = (_reservations ?? const <Reservation>[])
        .where((r) => r.status == ReservationStatus.upcoming)
        .toList()
      ..sort((a, b) => a.dateTime.compareTo(b.dateTime));
    final next = upcoming.where((r) => r.dateTime.isAfter(now.subtract(const Duration(minutes: 15)))).firstOrNull;

    return [
      StatCard(
        compact: true,
        label: 'Bàn có khách',
        value: '$serving/${tables.length}',
        icon: Icons.table_bar_outlined,
        color: AppColors.tableServing,
        caption: '$reserved đặt trước · $empty trống',
        onTap: widget.onOpenTables,
      ),
      StatCard(
        compact: true,
        label: 'Đơn chờ thanh toán',
        value: '${pending.length}',
        icon: Icons.point_of_sale_outlined,
        color: AppColors.warning,
        caption: pending.isEmpty ? 'Không có đơn nào' : 'Tạm tính ${AppFormatters.currency(pendingTotal)}',
      ),
      StatCard(
        compact: true,
        label: 'Lượt đặt sắp tới',
        value: _reservations == null ? '—' : '${upcoming.length}',
        icon: Icons.event_note_outlined,
        color: AppColors.info,
        caption: next == null ? 'Chưa có lượt nào' : 'Gần nhất ${AppFormatters.time(next.dateTime)} · ${next.tableNumber}',
        // Quay lại từ lịch đặt (có thể vừa hủy lượt) thì đếm lại.
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.reservationList).then((_) => _loadToday()),
      ),
      StatCard(
        compact: true,
        label: 'Đơn hủy hôm nay',
        value: _cancelledCount == null ? '—' : '$_cancelledCount',
        icon: Icons.cancel_outlined,
        color: AppColors.error,
        caption: 'Lý do và người hủy',
        onTap: () => Navigator.of(context).pushNamed(AppRoutes.adminCancelledOrders).then((_) => _loadToday()),
      ),
    ];
  }
}


/// Khối doanh thu nổi bật: hôm nay (so với hôm qua), tuần này (so với tuần trước), số đơn và
/// khách thành viên hôm nay. Nền nâu đậm như thẻ ca của Thu ngân để nổi lên đầu trang.
class _RevenueHero extends StatelessWidget {
  final ReportOverview report;
  final VoidCallback? onOpenReports;

  const _RevenueHero({required this.report, this.onOpenReports});

  @override
  Widget build(BuildContext context) {
    final muted = AppColors.textOnDark.withValues(alpha: 0.72);
    Widget mini(String label, String value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, color: muted)),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textOnDark)),
              ),
            ],
          ),
        );

    final card = Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(22)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Doanh thu hôm nay', style: TextStyle(fontSize: 13, color: muted))),
              if (onOpenReports != null) Icon(Icons.chevron_right_rounded, color: muted),
            ],
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: CountUpText(
              value: report.todayRevenue,
              formatter: (v) => AppFormatters.currency(v.round()),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: AppColors.primary,
                letterSpacing: -0.6,
              ),
            ),
          ),
          // Không ghi "-55%": so một phần ngày hôm nay với CẢ ngày hôm qua thì sáng nào cũng báo
          // giảm. Hiện số của kỳ trước để quản lý tự so.
          Text('Hôm qua: ${AppFormatters.currency(report.yesterdayRevenue)}',
              style: TextStyle(fontSize: 12.5, color: muted)),
          const SizedBox(height: 14),
          Divider(height: 1, color: AppColors.textOnDark.withValues(alpha: 0.15)),
          const SizedBox(height: 12),
          Row(
            children: [
              mini('Tuần này', AppFormatters.currency(report.weekRevenue)),
              mini('Tuần trước', AppFormatters.currency(report.lastWeekRevenue)),
              mini('Đơn · Thành viên', '${report.todayOrders} · ${report.todayMembers}'),
            ],
          ),
        ],
      ),
    );
    if (onOpenReports == null) return card;
    return PressScale(onTap: onOpenReports!, scale: 0.98, child: card);
  }
}

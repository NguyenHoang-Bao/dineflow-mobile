import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../data/app_data.dart';
import '../../data/mock_data.dart';
import '../../data/order_staff_repository.dart';
import '../../data/reservation_repository.dart';
import '../../models/reservation.dart';
import '../../models/table_model.dart';
import '../../theme/app_colors.dart';
import '../../theme/status_visuals.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header_band.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/live_data.dart';
import '../../widgets/staff_table_tile.dart';

/// UI chuyển bàn: xem bàn hiện tại → chọn bàn trống muốn chuyển đến → xác nhận.
///
/// Gọi API thật `POST /tables/{id}/transfer` khi xác nhận.
///
/// Bàn đích chỉ cần trống lúc này (server chặn bàn có khách đặt trong 90 phút tới), nên bàn có
/// khách đặt muộn hơn vẫn chọn được. Màn này tải lịch đặt hôm nay để ghi "Đặt 21:00" lên ô bàn
/// và hỏi lại trước khi chuyển vào bàn đó.
class TransferTableScreen extends StatefulWidget {
  final String currentTableId;
  const TransferTableScreen({super.key, required this.currentTableId});

  @override
  State<TransferTableScreen> createState() => _TransferTableScreenState();
}

class _TransferTableScreenState extends State<TransferTableScreen> {
  String? _targetTableId;
  bool _loading = false;

  /// Lượt đặt sắp tới hôm nay theo bàn (rỗng nếu chưa tải xong hoặc lỗi).
  Map<String, Reservation> _bookings = const {};

  @override
  void initState() {
    super.initState();
    ReservationRepository.instance.fetchUpcomingTodayByTable().then((map) {
      if (mounted) setState(() => _bookings = map);
    });
  }

  Future<void> _confirm(TableModel currentTable, TableModel target) async {
    if (_loading) return;

    final booking = _bookings[target.id];
    if (booking != null) {
      final ok = await showConfirmDialog(
        context,
        title: 'Chuyển sang ${target.number}?',
        message: '${target.number} có khách đặt lúc ${AppFormatters.time(booking.dateTime)}. '
            'Khách đang ngồi cần thanh toán hoặc đổi bàn trước giờ đó, nếu không sẽ không nhận bàn '
            'cho khách đặt được.',
        confirmLabel: 'Vẫn chuyển',
        cancelLabel: 'Không',
      );
      if (!ok || !mounted) return;
    }

    setState(() => _loading = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      await OrderStaffRepository.instance.transferTable(
        widget.currentTableId,
        targetTableId: target.id,
      );
      // Làm mới dữ liệu bàn và đơn sau khi chuyển thành công.
      await AppData.refresh(
        {LiveSource.tables, LiveSource.orders},
        force: true,
      );
      // Đóng màn hình và báo thành công cho màn hình trước (TableDetailScreen).
      navigator.pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Đã chuyển từ ${currentTable.number} sang ${target.number}'),
        ),
      );
    } on ApiException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
      // Bàn đích có thể vừa có khách / khách đặt → tải lại để danh sách đúng.
      await AppData.refresh({LiveSource.tables}, force: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => LiveData(
        sources: const {LiveSource.tables, LiveSource.orders},
        builder: (context, _) => _buildContent(context),
      );

  Widget _buildContent(BuildContext context) {
    // MockData.tables được AppData nạp từ API thật qua LiveData bên trên.
    final allTables = MockData.tables;
    final currentTable = allTables.where((t) => t.id == widget.currentTableId).firstOrNull;
    if (currentTable == null) {
      return const Scaffold(
        body: SafeArea(
          child: EmptyState(
            icon: Icons.table_restaurant_outlined,
            title: 'Không tìm thấy bàn',
            message: 'Bàn này có thể đã bị xóa hoặc thay đổi trạng thái',
          ),
        ),
      );
    }

    // Chỉ bàn mở được cho khách lúc này: trống, đang hoạt động, không khóa, không đang giữ cho khách đặt.
    final availableTables =
        allTables.where((t) => t.id != currentTable.id && t.canOpenForWalkIn).toList();
    final areas = availableTables.map((t) => t.area).toSet().toList();

    final target = _targetTableId == null
        ? null
        : availableTables.where((t) => t.id == _targetTableId).firstOrNull;

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      body: Column(
        children: [
          const AppHeaderBand(title: 'Chuyển bàn', subtitle: 'Chuyển khách và đơn sang bàn khác'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              children: [
                Text('Bàn hiện tại', style: _sectionStyle),
                const SizedBox(height: 10),
                FadeSlideIn(offsetY: 10, child: _CurrentTableCard(table: currentTable)),
                const SizedBox(height: 22),
                Text('Chọn bàn muốn chuyển đến', style: _sectionStyle),
                const SizedBox(height: 2),
                Text(
                  'Chỉ hiện bàn đang trống và mở được. Bàn ghi "Đặt hh:mm" là bàn có khách đặt muộn hơn hôm nay.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 12),
                if (availableTables.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: EmptyState(
                      icon: Icons.event_busy_outlined,
                      title: 'Không còn bàn trống',
                      message: 'Tất cả bàn đang được phục vụ, đang khóa hoặc đã có khách đặt trước',
                    ),
                  )
                else
                  // Theo khu vực để dễ chọn bàn gần chỗ khách đang ngồi.
                  for (final area in areas) ...[
                    StaffAreaTitle(area),
                    StaffTableGrid(
                      tables: availableTables.where((t) => t.area == area).toList(),
                      isSelected: (table) => table.id == _targetTableId,
                      alertOf: (table) {
                        final b = _bookings[table.id];
                        return b == null ? null : 'Đặt ${AppFormatters.time(b.dateTime)}';
                      },
                      onTap: (table) => setState(() => _targetTableId = table.id),
                    ),
                    const SizedBox(height: 16),
                  ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: AppButton(
                label: target == null ? 'Chọn bàn muốn chuyển đến' : 'Chuyển sang ${target.number}',
                isLoading: _loading,
                onPressed: target == null ? null : () => _confirm(currentTable, target),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static TextStyle get _sectionStyle =>
      TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary);
}

/// Thẻ "Bàn hiện tại": ô số bàn theo màu trạng thái, tên bàn - khu vực, số khách - mã đơn.
class _CurrentTableCard extends StatelessWidget {
  final TableModel table;

  const _CurrentTableCard({required this.table});

  @override
  Widget build(BuildContext context) {
    final visual = tableTileVisual(table.status);
    final orderId = table.currentOrderId;
    // Mã đơn như các màn khác (OD261126-1000), không phải id nội bộ của database.
    final code = orderId == null ? null : (MockData.findOrder(orderId)?.displayCode ?? orderId);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: visual.background,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: visual.border),
            ),
            child: Text(
              AppFormatters.tableCode(table.number),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: visual.foreground),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${table.number} · ${table.area}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  code == null ? '${table.capacity} khách' : '${table.capacity} khách · đơn #$code',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TableStatusPill(status: table.status),
        ],
      ),
    );
  }
}

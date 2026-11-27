import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../data/app_data.dart';
import '../../data/mock_data.dart';
import '../../data/order_staff_repository.dart';
import '../../models/order.dart';
import '../../models/order_item.dart';
import '../../models/table_model.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header_band.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/live_data.dart';
import '../../widgets/staff_table_tile.dart';

/// UI gộp bàn: chọn thêm bàn, gộp đơn của các bàn nguồn vào bàn hiện tại.
///
/// Bàn hiện tại ([initialTableId]) là bàn ĐÍCH — các bàn còn lại được chọn
/// là bàn NGUỒN. Server sẽ chuyển toàn bộ món của bàn nguồn vào đơn của
/// bàn đích, hủy đơn nguồn rồi giải phóng bàn nguồn. Không hoàn tác được nên luôn hỏi lại.
///
/// Gọi API thật `POST /tables/{sourceId}/merge` lần lượt cho từng bàn nguồn.
///
/// Các chặn ở app (server hiện CHƯA chặn, đã kiểm chứng bằng test trên database tạm 26/11):
/// - đơn đã thanh toán (làm nguồn → khách trả hai lần; làm đích → món gộp vào không thu được);
/// - cùng một món nhưng khác size/topping: server ghép món theo food_id + giá GỐC + ghi chú nên
///   gộp "Trà sữa M" vào "Trà sữa L" thành một dòng size L → hóa đơn sai.
class MergeTableScreen extends StatefulWidget {
  final String initialTableId;
  const MergeTableScreen({super.key, required this.initialTableId});

  @override
  State<MergeTableScreen> createState() => _MergeTableScreenState();
}

class _MergeTableScreenState extends State<MergeTableScreen> {
  /// Các bàn NGUỒN đã chọn (không gồm bàn đích).
  final List<String> _sourceIds = [];
  bool _loading = false;

  Order? _orderOf(TableModel table) =>
      table.currentOrderId == null ? null : MockData.findOrder(table.currentOrderId!);

  /// Bàn làm nguồn được: có khách, có đơn còn mở và chưa thanh toán.
  bool _canBeSource(TableModel t) =>
      t.id != widget.initialTableId &&
      t.isActive &&
      !t.isLocked &&
      t.status == TableStatus.serving &&
      (_orderOf(t)?.acceptsMoreItems ?? false);

  void _toggle(TableModel table) {
    setState(() {
      if (_sourceIds.contains(table.id)) {
        _sourceIds.remove(table.id);
      } else {
        _sourceIds.add(table.id);
      }
    });
  }

  /// Món sẽ bị server gộp sai: cùng món + cùng ghi chú nhưng khác size/topping, trong đó có ít
  /// nhất một dòng đến từ bàn nguồn. Trả về tên các món đó (rỗng = gộp an toàn).
  static List<String> _sizeConflicts(Order? target, List<Order> sources) {
    String optionKey(OrderItem i) => (i.selectedOptions.map((o) => o.id).toList()..sort()).join(',');
    final groups = <String, ({String name, Set<String> keys, bool fromSource})>{};
    void add(OrderItem i, bool fromSource) {
      final k = '${i.foodId}|${i.note.trim()}';
      final g = groups[k];
      groups[k] = (
        name: i.foodName,
        keys: {...?g?.keys, optionKey(i)},
        fromSource: (g?.fromSource ?? false) || fromSource,
      );
    }

    for (final i in target?.items ?? const <OrderItem>[]) {
      add(i, false);
    }
    for (final o in sources) {
      for (final i in o.items) {
        add(i, true);
      }
    }
    return [
      for (final g in groups.values)
        if (g.fromSource && g.keys.length > 1) g.name,
    ];
  }

  Future<void> _confirm(TableModel targetTable, List<TableModel> sources, Order? targetOrder) async {
    if (_loading || sources.isEmpty) return;

    final conflicts = _sizeConflicts(targetOrder, sources.map(_orderOf).whereType<Order>().toList());
    if (conflicts.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Chưa gộp được'),
          content: Text(
            '${conflicts.toSet().join(', ')} có ở các bàn này nhưng khác size/topping. Server hiện gộp '
            'nhầm các món này thành một dòng nên hóa đơn sẽ sai tiền.\n\n'
            'Tạm thời hãy chuyển khách sang bàn trống thay vì gộp, hoặc để mỗi bàn thanh toán riêng.',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đã hiểu'))],
        ),
      );
      return;
    }

    final names = sources.map((t) => t.number).join(', ');
    final ok = await showConfirmDialog(
      context,
      title: 'Gộp $names vào ${targetTable.number}?',
      message: 'Toàn bộ món của $names sẽ chuyển sang '
          '${targetOrder == null ? targetTable.number : 'đơn #${targetOrder.displayCode} của ${targetTable.number}'}, '
          'các bàn này trở về trống. Gộp rồi thì không tách lại được.',
      confirmLabel: 'Gộp bàn',
    );
    if (!ok || !mounted) return;

    setState(() => _loading = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // Gọi lần lượt từng bàn: lỗi giữa chừng thì các bàn trước đã gộp xong (server không hoàn tác),
    // nên phải báo rõ bàn nào đã gộp, bàn nào chưa, và tải lại dữ liệu.
    final merged = <String>[];
    String? failure;
    for (final source in sources) {
      try {
        await OrderStaffRepository.instance.mergeOne(source.id, targetTableId: targetTable.id);
        merged.add(source.number);
      } on ApiException catch (e) {
        failure = '${source.number}: ${e.message}';
        break;
      }
    }
    await AppData.refresh({LiveSource.tables, LiveSource.orders}, force: true);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _sourceIds.clear();
    });

    if (failure == null) {
      navigator.pop(true);
      messenger.showSnackBar(SnackBar(content: Text('Đã gộp $names vào ${targetTable.number}')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(merged.isEmpty ? 'Không gộp được' : 'Mới gộp được một phần'),
        content: Text([
          if (merged.isNotEmpty) 'Đã gộp: ${merged.join(', ')} vào ${targetTable.number}.',
          'Lỗi ở $failure',
        ].join('\n\n')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LiveData(
        sources: const {LiveSource.tables, LiveSource.orders},
        builder: (context, _) => _buildContent(context),
      );

  Widget _buildContent(BuildContext context) {
    final targetTable = MockData.tables.where((t) => t.id == widget.initialTableId).firstOrNull;
    if (targetTable == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final targetOrder = _orderOf(targetTable);
    final targetPaid = targetOrder != null && !targetOrder.acceptsMoreItems;

    final candidates = MockData.activeTables.where(_canBeSource).toList();
    // Bàn đã chọn mà vừa đổi trạng thái (vd vừa thanh toán) thì bỏ khỏi danh sách chọn.
    _sourceIds.removeWhere((id) => !candidates.any((t) => t.id == id));
    final sources = [for (final id in _sourceIds) candidates.firstWhere((t) => t.id == id)];
    final areas = candidates.map((t) => t.area).toSet().toList();

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      body: Column(
        children: [
          AppHeaderBand(
            title: 'Gộp bàn',
            subtitle: 'Gộp đơn của các bàn khác vào ${targetTable.number}',
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              children: [
                // ── Bàn đích ─────────────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.primary),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.call_merge_rounded, color: AppColors.textPrimary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Bàn đích: ${targetTable.number}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary)),
                            Text(
                              targetOrder == null
                                  ? 'Chưa có đơn — đơn của bàn nguồn sẽ chuyển sang đây'
                                  : 'Đơn #${targetOrder.displayCode} · ${targetOrder.totalQuantity} món',
                              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                if (targetPaid)
                  const EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'Không gộp vào đơn đã thanh toán',
                    message: 'Món gộp vào đơn đã trả sẽ không được thu tiền. Hãy gộp vào bàn khác.',
                  )
                else ...[
                  Text(
                    sources.isEmpty ? 'Chọn bàn cần gộp vào' : 'Đã chọn ${sources.length} bàn nguồn',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Chỉ hiện bàn đang có khách và chưa thanh toán. Chạm để chọn / bỏ chọn.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  if (candidates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: EmptyState(
                        icon: Icons.table_bar_outlined,
                        title: 'Không có bàn nào để gộp',
                        message: 'Chưa có bàn nào khác đang có khách.',
                      ),
                    )
                  else
                    for (final area in areas) ...[
                      StaffAreaTitle(area),
                      FadeSlideIn(
                        offsetY: 8,
                        child: StaffTableGrid(
                          tables: candidates.where((t) => t.area == area).toList(),
                          isSelected: (table) => _sourceIds.contains(table.id),
                          onTap: _toggle,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: AppButton(
                label: sources.isNotEmpty
                    ? 'Gộp ${sources.length} bàn vào ${targetTable.number}'
                    : 'Chọn ít nhất 1 bàn nguồn',
                isLoading: _loading,
                onPressed: sources.isNotEmpty && !targetPaid ? () => _confirm(targetTable, sources, targetOrder) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

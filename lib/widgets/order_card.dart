import 'package:flutter/material.dart';

import '../models/order.dart';
import '../theme/app_colors.dart';
import '../utils/formatters.dart';
import 'app_animations.dart';
import 'status_badge.dart';

class OrderStatusVisual {
  final Color color;
  final Color background;
  const OrderStatusVisual(this.color, this.background);
}

OrderStatusVisual orderStatusVisual(OrderStatus status) {
  switch (status) {
    case OrderStatus.placed:
      return OrderStatusVisual(AppColors.info, AppColors.infoBg);
    // Theo mockup "Đơn đang phục vụ": đang chuẩn bị = viên vàng, đã ra món = viên nâu đen.
    // Dùng chung cho mọi màn hiện trạng thái đơn (kể cả Chi tiết bàn) để cùng một màu.
    case OrderStatus.preparing:
      return OrderStatusVisual(AppColors.textOnPrimary, AppColors.primary);
    case OrderStatus.serving:
      return OrderStatusVisual(AppColors.textOnDark, AppColors.ink);
    case OrderStatus.completed:
      return OrderStatusVisual(AppColors.success, AppColors.successBg);
    case OrderStatus.cancelled:
      return OrderStatusVisual(AppColors.error, AppColors.errorBg);
  }
}

/// Card tóm tắt một đơn hàng, dùng trong nhiều màn hình (lịch sử, order đang phục vụ, chờ thanh toán...).
class OrderCard extends StatelessWidget {
  final Order order;
  final VoidCallback? onTap;
  final Widget? trailingAction;

  /// Thay dòng ngày giờ mặc định (vd "Gọi lúc 12:44 · 25 phút trước" ở tab Đang phục vụ).
  final String? timeLabel;

  /// Thay nhãn trạng thái (NV Order dùng "Chờ bếp / Đang làm / Đã ra món").
  final String? statusLabel;

  const OrderCard({
    super.key,
    required this.order,
    this.onTap,
    this.trailingAction,
    this.timeLabel,
    this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    final visual = orderStatusVisual(order.status);
    return PressScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
          boxShadow: AppColors.softShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Đơn #${order.displayCode}${order.tableNumber != null ? ' · ${order.tableNumber}' : ''}',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                StatusBadge(
                  label: statusLabel ?? order.status.label,
                  color: visual.color,
                  background: visual.background,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              order.items.map((i) => '${i.quantity}× ${i.foodName}').join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.35),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(timeLabel ?? AppFormatters.timeDate(order.createdAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(AppFormatters.currency(order.subtotal),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: AppColors.textPrimary)),
                ),
              ],
            ),
            if (trailingAction != null) ...[const SizedBox(height: 10), trailingAction!],
          ],
        ),
      ),
    );
  }
}

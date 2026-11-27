import 'package:flutter/material.dart';

import '../models/order.dart';
import '../models/table_model.dart';
import 'app_colors.dart';

/// Cặp màu (chữ/viền + nền) cho một trạng thái.
typedef StatusVisual = ({Color color, Color background});

/// Màu hiển thị cho trạng thái bàn.
///
/// Gom về một chỗ duy nhất: trước đây `TableCard`, màn Chi tiết bàn và màn
/// Quản lý bàn & khu vực mỗi nơi tự ánh xạ màu, dẫn tới có màn quên đổi màu
/// theo trạng thái và nhìn bàn nào cũng như nhau.
StatusVisual tableStatusVisual(TableStatus status) {
  switch (status) {
    case TableStatus.empty:
      return (color: AppColors.tableEmpty, background: AppColors.tableEmptyBg);
    case TableStatus.serving:
      return (color: AppColors.tableServing, background: AppColors.tableServingBg);
    case TableStatus.reserved:
      return (color: AppColors.tableReserved, background: AppColors.tableReservedBg);
    case TableStatus.locked:
      return (color: AppColors.textSecondary, background: AppColors.surfaceAlt);
  }
}

/// Bộ màu cho ô bàn kiểu mockup Nhân viên Order: nền, chữ chính, chữ phụ, viền.
typedef TableTileVisual = ({Color background, Color foreground, Color muted, Color border});

/// Màu ô bàn theo trạng thái, đúng bộ mockup Nhân viên Order:
/// trống = trắng viền mảnh, đang phục vụ = nâu đen chữ trắng, đặt trước = vàng.
/// Dùng cho ô bàn, nhãn trạng thái bàn và chú thích màu của nhóm màn này.
TableTileVisual tableTileVisual(TableStatus status) {
  switch (status) {
    case TableStatus.empty:
      return (
        background: AppColors.surface,
        foreground: AppColors.textPrimary,
        muted: AppColors.textSecondary,
        border: AppColors.border,
      );
    case TableStatus.serving:
      return (
        background: AppColors.ink,
        foreground: AppColors.textOnDark,
        muted: AppColors.textOnDark.withValues(alpha: 0.8),
        border: AppColors.ink,
      );
    case TableStatus.reserved:
      return (
        background: AppColors.primary,
        foreground: AppColors.textOnPrimary,
        muted: AppColors.textOnPrimary.withValues(alpha: 0.75),
        border: AppColors.primary,
      );
    // Bàn Admin khóa tạm: nền xám, viền đậm hơn để không lẫn với nền trang (ô chú thích
    // "Khóa" trước đây trùng màu nền nên nhìn như không có).
    case TableStatus.locked:
      return (
        background: AppColors.border,
        foreground: AppColors.textSecondary,
        muted: AppColors.textSecondary.withValues(alpha: 0.75),
        border: AppColors.textSecondary.withValues(alpha: 0.45),
      );
  }
}

/// Nhãn trạng thái bàn dạng ngắn dùng trên ô bàn và chú thích (mockup ghi
/// "Đặt trước" thay cho "Đã đặt trước" để vừa ô nhỏ).
String tableStatusShortLabel(TableStatus status) {
  switch (status) {
    case TableStatus.empty:
      return 'Trống';
    case TableStatus.serving:
      return 'Đang phục vụ';
    case TableStatus.reserved:
      return 'Đặt trước';
    case TableStatus.locked:
      return 'Đang khóa';
  }
}

/// Bước của đơn theo cách NV Order nói, ngắn để vừa ô bàn: đơn vừa gửi = "Chờ bếp",
/// bếp đang làm = "Đang làm", đã mang ra = "Đã ra món".
String orderStepShortLabel(OrderStatus status) {
  switch (status) {
    case OrderStatus.placed:
      return 'Chờ bếp';
    case OrderStatus.preparing:
      return 'Đang làm';
    case OrderStatus.serving:
      return 'Đã ra món';
    case OrderStatus.completed:
      return 'Chờ thanh toán';
    case OrderStatus.cancelled:
      return 'Đã hủy';
  }
}

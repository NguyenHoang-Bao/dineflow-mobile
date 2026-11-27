import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Hộp thoại xác nhận dùng chung: hai nút nằm cùng một hàng, chia đều bề ngang.
///
/// Không đặt OutlinedButton/FilledButton trần vào `AlertDialog.actions`: theme của app cho
/// OutlinedButton `minimumSize: Size.fromHeight(52)` (rộng tối đa) nên nút "Hủy" chiếm hết
/// một hàng và đẩy nút chính xuống dòng dưới. Ở đây mỗi nút được bọc trong [Expanded]
/// và đặt lại `minimumSize` nên luôn đứng cạnh nhau.
///
/// Trả về `true` khi người dùng bấm nút xác nhận.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Hủy',
  bool destructive = false,

  /// Màu nút xác nhận khi không phải thao tác nguy hiểm (vd xanh cho "Kích hoạt").
  Color? confirmColor,
}) async {
  final Color background = destructive ? AppColors.error : (confirmColor ?? AppColors.primary);
  final Color foreground =
      destructive || confirmColor != null ? Colors.white : AppColors.textOnPrimary;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(
        message,
        style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary, height: 1.5),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  side: BorderSide(color: AppColors.border),
                  foregroundColor: AppColors.textPrimary,
                  shape: shape,
                ),
                child: Text(cancelLabel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  backgroundColor: background,
                  foregroundColor: foreground,
                  shape: shape,
                ),
                child: Text(confirmLabel, textAlign: TextAlign.center),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return result == true;
}

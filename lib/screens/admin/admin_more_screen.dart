import 'package:flutter/material.dart';

import '../../app/app_navigator.dart';
import '../../app/routes.dart';
import '../../core/session/session_store.dart';
import '../../theme/app_colors.dart';
import '../../widgets/confirm_dialog.dart';

/// Hỏi lại trước khi đăng xuất (nút đăng xuất nằm sát các nút khác, dễ bấm nhầm).
Future<void> confirmAdminSignOut(BuildContext context) async {
  final ok = await showConfirmDialog(
    context,
    title: 'Đăng xuất?',
    message: 'Bạn sẽ cần đăng nhập lại để quản lý nhà hàng.',
    confirmLabel: 'Đăng xuất',
    destructive: true,
  );
  if (ok) await signOut();
}

/// Tab "Quản lý" của Admin: gom các chức năng ít dùng hằng ngày hơn để thanh điều hướng
/// dưới gọn (Tổng quan, Thực đơn, Bàn, Khuyến mãi, Báo cáo, Quản lý).
///
/// Trước đây Báo cáo ca, Lịch đặt bàn và Đơn đã hủy chỉ mở được từ ô "Quản lý nhanh"
/// ở cuối Dashboard nên rất khó tìm; giờ chúng nằm cùng chỗ với Tài khoản và Khuyến mãi.
class AdminMoreScreen extends StatelessWidget {
  const AdminMoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = SessionStore.instance.user;
    void open(String route) => Navigator.of(context).pushNamed(route);

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      appBar: AppBar(title: const Text('Quản lý')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (user != null)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: AppColors.primaryLight,
                    child: Text(
                      user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                      style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name,
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary)),
                        Text(
                          [if (user.phone.isNotEmpty) user.phone, 'Quản trị viên'].join(' · '),
                          style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const _GroupLabel('Con người'),
          _Group(children: [
            _MenuTile(
              icon: Icons.people_alt_outlined,
              title: 'Tài khoản',
              subtitle: 'Nhân viên, khách hàng · khóa / mở',
              onTap: () => open(AppRoutes.adminAccounts),
            ),
          ]),
          const _GroupLabel('Bán hàng'),
          _Group(children: [
            _MenuTile(
              icon: Icons.event_note_outlined,
              title: 'Lịch đặt bàn',
              subtitle: 'Khách đặt trước theo ngày, tiền cọc',
              onTap: () => open(AppRoutes.reservationList),
            ),
            _MenuTile(
              icon: Icons.cancel_outlined,
              title: 'Đơn đã hủy',
              subtitle: 'Lý do và người hủy theo ngày',
              onTap: () => open(AppRoutes.adminCancelledOrders),
            ),
          ]),
          const _GroupLabel('Thu ngân'),
          _Group(children: [
            _MenuTile(
              icon: Icons.badge_outlined,
              title: 'Báo cáo ca',
              subtitle: 'Tiền đầu ca, doanh thu, chênh lệch',
              onTap: () => open(AppRoutes.adminShifts),
            ),
          ]),
          const SizedBox(height: 20),
          _Group(children: [
            _MenuTile(
              icon: Icons.logout_rounded,
              title: 'Đăng xuất',
              danger: true,
              onTap: () => confirmAdminSignOut(context),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Một nhóm mục trong cùng một khung trắng, ngăn nhau bằng đường kẻ mảnh (kiểu trang cài đặt)
/// thay cho mỗi mục một thẻ riêng — gọn hơn và nhìn ra nhóm ngay.
class _Group extends StatelessWidget {
  final List<Widget> children;
  const _Group({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, indent: 62, color: AppColors.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String text;
  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 18, 6, 6),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: AppColors.textSecondary,
          ),
        ),
      );
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;

  const _MenuTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.textPrimary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: danger ? AppColors.errorBg : AppColors.primaryLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: color)),
                  if (subtitle != null)
                    Text(subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                ],
              ),
            ),
            if (!danger) Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

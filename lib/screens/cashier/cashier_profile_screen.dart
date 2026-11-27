import 'package:flutter/material.dart';

import '../../app/app_navigator.dart';
import '../../app/routes.dart';
import '../../data/mock_data.dart';
import '../../theme/app_colors.dart';
import '../../widgets/account_identity_card.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_header_band.dart';
import '../../widgets/app_setting_tile.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/theme_mode_tile.dart';

/// Tab Cá nhân của Thu ngân.
///
/// Bỏ hai mục "Ca làm việc" và "Lịch sử thanh toán" (trùng thanh điều hướng dưới), thêm
/// "Lịch đặt bàn" (trước đây chỉ vào được từ ô Truy cập nhanh). Đăng xuất có hỏi lại.
class CashierProfileScreen extends StatelessWidget {
  const CashierProfileScreen({super.key});

  Future<void> _signOut(BuildContext context) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Đăng xuất?',
      message: 'Nhớ đóng ca trước khi nghỉ nếu đã hết ca. Bạn sẽ cần đăng nhập lại để thu tiền.',
      confirmLabel: 'Đăng xuất',
      destructive: true,
    );
    if (ok) await signOut();
  }

  @override
  Widget build(BuildContext context) {
    var order = 0;
    Widget step(Widget child) => FadeSlideIn.staggered(index: order++, child: child);

    AppSettingTile tile(IconData icon, String label, VoidCallback onTap) => AppSettingTile(
          icon: icon,
          label: label,
          iconBackground: AppColors.primaryLight,
          iconShape: BoxShape.rectangle,
          onTap: onTap,
        );

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      body: Column(
        children: [
          const AppHeaderBand(caption: 'Tài khoản thu ngân', title: 'Cá nhân'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                step(AccountIdentityCard(user: MockData.currentCashier)),
                const SizedBox(height: 14),
                step(AppSettingGroup(
                  background: AppColors.surface,
                  divided: true,
                  children: [
                    tile(Icons.event_note_outlined, 'Lịch đặt bàn',
                        () => Navigator.of(context).pushNamed(AppRoutes.reservationList)),
                    ThemeModeTile(iconBackground: AppColors.primaryLight, iconShape: BoxShape.rectangle),
                    tile(Icons.lock_outline_rounded, 'Đổi mật khẩu',
                        () => Navigator.of(context).pushNamed(AppRoutes.cashierSettings)),
                  ],
                )),
                const SizedBox(height: 14),
                step(AppSettingGroup(
                  background: AppColors.surface,
                  children: [
                    AppSettingTile(
                      icon: Icons.logout_rounded,
                      label: 'Đăng xuất',
                      color: AppColors.error,
                      iconBackground: AppColors.surfaceAlt,
                      iconShape: BoxShape.rectangle,
                      onTap: () => _signOut(context),
                    ),
                  ],
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

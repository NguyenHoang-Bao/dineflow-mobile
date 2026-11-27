import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_bottom_nav.dart';
import 'admin_dashboard_screen.dart';
import 'admin_more_screen.dart';
import 'menu_management_screen.dart';
import 'promotion_management_screen.dart';
import 'revenue_report_screen.dart';
import 'table_area_management_screen.dart';

/// Khung điều hướng cho Admin (6 mục): Tổng quan, Thực đơn, Bàn, Khuyến mãi, Báo cáo, Quản lý.
/// Tab "Quản lý" gom Tài khoản, Lịch đặt bàn, Đơn đã hủy, Báo cáo ca.
///
/// Khuyến mãi lên thanh dưới cho Admin dễ tìm (nhóm chốt 27/11, chấp nhận 6 mục).
/// Dùng thanh điều hướng dưới cùng cho màn hình hẹp (điện thoại) và NavigationRail
/// cho màn hình rộng (tablet/desktop).
class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> with SingleTickerProviderStateMixin {
  int _index = 0;

  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
    value: 1,
  );
  late final Animation<double> _fade = CurvedAnimation(parent: _fadeController, curve: Curves.easeOutCubic);

  static const _destinations = [
    (icon: Icons.dashboard_outlined, activeIcon: Icons.dashboard, label: 'Tổng quan'),
    (icon: Icons.menu_book_outlined, activeIcon: Icons.menu_book, label: 'Thực đơn'),
    (icon: Icons.table_bar_outlined, activeIcon: Icons.table_bar, label: 'Bàn'),
    (icon: Icons.local_offer_outlined, activeIcon: Icons.local_offer, label: 'Khuyến mãi'),
    (icon: Icons.bar_chart_outlined, activeIcon: Icons.bar_chart, label: 'Báo cáo'),
    (icon: Icons.grid_view_outlined, activeIcon: Icons.grid_view_rounded, label: 'Quản lý'),
  ];

  /// Vị trí tab trong [_destinations], để Dashboard mở thẳng tab Bàn / Báo cáo.
  static const _tablesTab = 2;
  static const _reportsTab = 4;

  late final List<Widget> _tabs = [
    AdminDashboardScreen(
      onOpenTables: () => _selectTab(_tablesTab),
      onOpenReports: () => _selectTab(_reportsTab),
    ),
    const MenuManagementScreen(),
    const TableAreaManagementScreen(),
    const PromotionManagementScreen(),
    const RevenueReportScreen(),
    const AdminMoreScreen(),
  ];

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _selectTab(int index) {
    if (_index == index) return;
    setState(() => _index = index);
    _fadeController.forward(from: 0);
  }

  void _logout() => confirmAdminSignOut(context);

  Widget get _body => FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(_fade),
          child: IndexedStack(index: _index, children: _tabs),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 640;

        if (isWide) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _selectTab,
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: AppColors.goldGradient,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: AppColors.goldShadow,
                          ),
                          child: Icon(Icons.restaurant_menu_rounded, color: AppColors.textOnPrimary),
                        ),
                        const SizedBox(height: 8),
                        IconButton(
                          icon: Icon(Icons.logout, color: AppColors.error, size: 20),
                          onPressed: _logout,
                          tooltip: 'Đăng xuất',
                        ),
                      ],
                    ),
                  ),
                  destinations: [
                    for (final d in _destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.activeIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
                VerticalDivider(width: 1, color: AppColors.border),
                Expanded(child: _body),
              ],
            ),
          );
        }

        return Scaffold(
          body: _body,
          bottomNavigationBar: AppBottomNav(
            currentIndex: _index,
            onTap: _selectTab,
            items: [
              for (final d in _destinations)
                AppNavItem(icon: d.icon, activeIcon: d.activeIcon, label: d.label),
            ],
          ),
        );
      },
    );
  }
}

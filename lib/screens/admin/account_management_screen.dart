import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/session/session_store.dart';
import '../../data/admin_repository.dart';
import '../../models/user.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/status_badge.dart';

/// Quản lý tài khoản (Admin): nhân viên (NV Order, Thu ngân, Quản trị) và khách hàng.
/// Tạo / sửa / khóa / mở khóa / xóa (= khóa vĩnh viễn) tài khoản nhân viên.
///
/// Server trả toàn bộ danh sách (không phân trang) nên lọc vai trò và tìm kiếm làm ngay
/// trong app: tìm được cả theo **số điện thoại** (thứ nhân viên dùng để đăng nhập) mà
/// API `search` chưa hỗ trợ, và không gọi API mỗi lần gõ phím.
class AccountManagementScreen extends StatefulWidget {
  const AccountManagementScreen({super.key});
  @override
  State<AccountManagementScreen> createState() => _AccountManagementScreenState();
}

/// Bộ lọc vai trò: (khóa, nhãn, vai trò khớp; null = tất cả).
const _roleFilters = <(String, String, UserRole?)>[
  ('all', 'Tất cả', null),
  ('admin', 'Quản trị', UserRole.admin),
  ('order_staff', 'NV Order', UserRole.orderStaff),
  ('cashier', 'Thu ngân', UserRole.cashier),
  ('customer', 'Khách hàng', UserRole.customer),
];

class _AccountManagementScreenState extends State<AccountManagementScreen> {
  final _repo = AdminRepository.instance;

  List<User> _users = [];
  bool _loading = true;
  String? _error;

  String _roleFilter = 'all';
  String _search = '';

  String? get _myId => SessionStore.instance.user?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final users = await _repo.fetchUsers();
      if (!mounted) return;
      setState(() { _users = users; _loading = false; });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _loading = false; });
    }
  }

  /// Danh sách sau khi lọc vai trò + tìm theo tên / SĐT / email.
  List<User> get _visible {
    final role = _roleFilters.firstWhere((f) => f.$1 == _roleFilter).$3;
    final q = _search.trim().toLowerCase();
    final qDigits = q.replaceAll(RegExp(r'\D'), '');
    return _users.where((u) {
      if (role != null && u.role != role) return false;
      if (q.isEmpty) return true;
      return u.name.toLowerCase().contains(q) ||
          u.email.toLowerCase().contains(q) ||
          (qDigits.isNotEmpty && u.phone.replaceAll(RegExp(r'\D'), '').contains(qDigits));
    }).toList();
  }

  int _countFor(UserRole? role) => role == null ? _users.length : _users.where((u) => u.role == role).length;

  // ── Tạo / Sửa tài khoản ─────────────────────────────────────────────────

  void _showUserForm([User? existing]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _UserFormSheet(
        existing: existing,
        onSaved: (name, email, phone, role) async {
          Navigator.of(ctx).pop();
          setState(() => _loading = true);
          try {
            if (existing == null) {
              await _repo.createUser(name: name, email: email, phone: phone, role: role);
              _showSnack('Tạo tài khoản thành công. Mật khẩu mặc định: 123456');
            } else {
              await _repo.updateUser(existing.id, name: name, email: email, phone: phone, role: role);
              _showSnack('Cập nhật thành công');
            }
            _load();
          } on ApiException catch (e) {
            _showSnack(e.message, isError: true);
            setState(() => _loading = false);
          }
        },
      ),
    );
  }

  // ── Khóa / Mở khóa ──────────────────────────────────────────────────────

  Future<void> _toggleStatus(User user) async {
    final locking = user.status == AccountStatus.active;
    // Khóa làm người đó bị đăng xuất ngay → hỏi lại. Mở khóa thì không cần.
    if (locking) {
      final ok = await showConfirmDialog(
        context,
        title: 'Khóa tài khoản?',
        message: '"${user.name}" sẽ bị đăng xuất và không đăng nhập được cho tới khi được mở khóa.',
        confirmLabel: 'Khóa',
        destructive: true,
      );
      if (!ok) return;
    }
    try {
      final updated = await _repo.toggleUserStatus(user.id);
      setState(() {
        final i = _users.indexWhere((u) => u.id == user.id);
        if (i >= 0) _users[i] = updated;
      });
      _showSnack(updated.status == AccountStatus.locked
          ? 'Đã khóa tài khoản ${user.name}'
          : 'Đã mở khóa tài khoản ${user.name}');
    } on ApiException catch (e) {
      _showSnack(e.message, isError: true);
    }
  }

  // ── Đặt lại mật khẩu (chỉ NV Order / Thu ngân) ──────────────────────────

  Future<void> _confirmResetPassword(User user) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Đặt lại mật khẩu',
      message: 'Đặt lại mật khẩu của "${user.name}" về 123456?\n'
          'Nhân viên sẽ bị đăng xuất khỏi mọi thiết bị và tự đổi mật khẩu sau khi đăng nhập.\n'
          'Mật khẩu cũ không xem được vì được lưu dạng mã hóa.',
      confirmLabel: 'Đặt lại',
    );
    if (!ok) return;
    try {
      _showSnack(await _repo.resetUserPassword(user.id));
    } on ApiException catch (e) {
      _showSnack(e.message, isError: true);
    }
  }

  // ── "Xóa" = Khóa vĩnh viễn ──────────────────────────────────────────────

  Future<void> _confirmDelete(User user) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Xóa tài khoản',
      message: 'Xóa "${user.name}"?\nTài khoản sẽ bị khóa và ẩn khỏi danh sách.\nLịch sử đơn hàng vẫn được giữ lại.',
      confirmLabel: 'Xóa',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.deleteUser(user.id);
      setState(() => _users.removeWhere((u) => u.id == user.id));
      _showSnack('Đã xóa tài khoản ${user.name}');
    } on ApiException catch (e) {
      _showSnack(e.message, isError: true);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppColors.error : null,
      ));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      appBar: AppBar(
        title: const Text('Tài khoản', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            onPressed: () => _showUserForm(),
            icon: const Icon(Icons.person_add_rounded),
            tooltip: 'Thêm nhân viên',
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Bộ lọc ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              children: [
                _SearchField(
                  hint: 'Tìm tên, số điện thoại, email…',
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final f in _roleFilters)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(_loading ? f.$2 : '${f.$2} (${_countFor(f.$3)})'),
                            selected: _roleFilter == f.$1,
                            onSelected: (_) => setState(() => _roleFilter = f.$1),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ── Danh sách ──
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _tile(User u) => _UserTile(
        user: u,
        isMe: u.id == _myId,
        onEdit: () => _showUserForm(u),
        onToggle: () => _toggleStatus(u),
        onDelete: () => _confirmDelete(u),
        // Chỉ nhân viên mới đặt lại mật khẩu ở đây; khách dùng "Quên mật khẩu" (OTP email)
        onResetPassword: u.role == UserRole.orderStaff || u.role == UserRole.cashier
            ? () => _confirmResetPassword(u)
            : null,
      );

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: EmptyState(icon: Icons.error_outline_rounded, title: 'Lỗi tải dữ liệu', message: _error!));
    }
    final users = _visible;
    if (users.isEmpty) {
      return Center(
        child: EmptyState(
          icon: Icons.person_off_outlined,
          title: 'Không có tài khoản',
          message: _search.trim().isNotEmpty ? 'Không có ai khớp "${_search.trim()}"' : 'Bấm + để thêm nhân viên mới',
        ),
      );
    }

    // "Tất cả": tách Nhân viên và Khách hàng — hai nhóm quản lý khác nhau
    // (nhân viên do admin tạo, khách tự đăng ký; với khách admin chủ yếu chỉ khóa/mở).
    final List<Widget> children;
    if (_roleFilter == 'all') {
      final staff = users.where((u) => u.role != UserRole.customer).toList();
      final customers = users.where((u) => u.role == UserRole.customer).toList();
      children = [
        if (staff.isNotEmpty) ...[_GroupHeader('Nhân viên', staff.length), for (final u in staff) _tile(u)],
        if (customers.isNotEmpty) ...[_GroupHeader('Khách hàng', customers.length), for (final u in customers) _tile(u)],
      ];
    } else {
      children = [for (final u in users) _tile(u)];
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        children: children,
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String title;
  final int count;
  const _GroupHeader(this.title, this.count);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text('$title ($count)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textSecondary)),
      );
}

// ── Tile ────────────────────────────────────────────────────────────────────

class _UserTile extends StatelessWidget {
  final User user;
  final bool isMe;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback? onResetPassword;

  const _UserTile({
    required this.user,
    required this.isMe,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
    this.onResetPassword,
  });

  @override
  Widget build(BuildContext context) {
    final isLocked = user.status == AccountStatus.locked;
    final contact = [if (user.phone.isNotEmpty) user.phone, if (user.email.isNotEmpty) user.email].join(' · ');

    return FadeSlideIn(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 9, 0, 9),
        decoration: BoxDecoration(
          color: isLocked ? AppColors.surfaceAlt : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isLocked ? AppColors.error.withValues(alpha: 0.3) : AppColors.border),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 19,
              backgroundColor: AppColors.primaryLight,
              child: Text(user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                  style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(user.name,
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.textPrimary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (isMe)
                        Text('  (bạn)', style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                      // Chỉ báo khi bị khóa; "Hoạt động" là mặc định nên không cần nhãn riêng.
                      if (isLocked) ...[
                        const SizedBox(width: 6),
                        StatusBadge(label: 'Đã khóa', color: AppColors.error, background: AppColors.errorBg),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  // Vai trò gộp vào dòng phụ thay cho một nhãn riêng.
                  Text('${_roleLabel(user.role)} · $contact',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Thao tác',
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'toggle') onToggle();
                if (v == 'delete') onDelete();
                if (v == 'reset') onResetPassword?.call();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Sửa thông tin')),
                if (onResetPassword != null) const PopupMenuItem(value: 'reset', child: Text('Đặt lại mật khẩu')),
                // Server không cho tự khóa / tự xóa mình → không hiện nút để khỏi bấm rồi mới báo lỗi.
                if (!isMe) ...[
                  PopupMenuItem(value: 'toggle', child: Text(isLocked ? 'Mở khóa' : 'Khóa tài khoản')),
                  PopupMenuItem(value: 'delete', child: Text('Xóa', style: TextStyle(color: AppColors.error))),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _roleLabel(UserRole role) => switch (role) {
    UserRole.admin => 'Quản trị viên',
    UserRole.orderStaff => 'NV Order',
    UserRole.cashier => 'Thu ngân',
    UserRole.customer => 'Khách hàng',
  };
}

// ── Form Sheet ───────────────────────────────────────────────────────────────

class _UserFormSheet extends StatefulWidget {
  final User? existing;
  final void Function(String name, String email, String phone, UserRole role) onSaved;

  const _UserFormSheet({this.existing, required this.onSaved});

  @override
  State<_UserFormSheet> createState() => _UserFormSheetState();
}

class _UserFormSheetState extends State<_UserFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _nameCtrl = TextEditingController(text: widget.existing?.name);
  late final _emailCtrl = TextEditingController(text: widget.existing?.email);
  late final _phoneCtrl = TextEditingController(text: widget.existing?.phone);
  late UserRole _role = widget.existing?.role ?? UserRole.orderStaff;

  /// Chỉ đổi qua lại NV Order ↔ Thu ngân; tài khoản khách / quản trị giữ nguyên vai trò.
  bool get _canChangeRole => _role == UserRole.orderStaff || _role == UserRole.cashier;

  @override
  void dispose() {
    _nameCtrl.dispose(); _emailCtrl.dispose(); _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (ctx, scroll) => Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
        padding: EdgeInsets.only(left: 20, right: 20, top: 8, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Form(
          key: _formKey,
          child: ListView(
            controller: scroll,
            children: [
              Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Text(isNew ? 'Thêm nhân viên' : 'Sửa tài khoản',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 18),
              AppTextField(controller: _nameCtrl, label: 'Họ và tên', hint: 'Nguyễn Văn A', validator: (v) => (v == null || v.trim().isEmpty) ? 'Vui lòng nhập tên' : null),
              const SizedBox(height: 12),
              AppTextField(controller: _phoneCtrl, label: 'Số điện thoại (dùng để đăng nhập)', hint: '0901234567', keyboardType: TextInputType.phone),
              const SizedBox(height: 12),
              AppTextField(controller: _emailCtrl, label: 'Email', hint: 'nhanvien@dineflow.vn', keyboardType: TextInputType.emailAddress, validator: (v) => (v == null || !v.contains('@')) ? 'Email không hợp lệ' : null),
              if (_canChangeRole) ...[
                const SizedBox(height: 14),
                Text('Vai trò', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final r in [UserRole.orderStaff, UserRole.cashier])
                      ChoiceChip(
                        label: Text(r == UserRole.orderStaff ? 'NV Order' : 'Thu ngân'),
                        selected: _role == r,
                        onSelected: (_) => setState(() => _role = r),
                      ),
                  ],
                ),
              ],
              if (isNew) ...[
                const SizedBox(height: 12),
                Text('Mật khẩu mặc định: 123456 (nhân viên tự đổi sau khi đăng nhập)', style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
              ],
              const SizedBox(height: 24),
              AppButton(
                label: isNew ? 'Tạo tài khoản' : 'Lưu thay đổi',
                onPressed: () {
                  if (_formKey.currentState!.validate()) {
                    widget.onSaved(_nameCtrl.text.trim(), _emailCtrl.text.trim(), _phoneCtrl.text.trim(), _role);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Ô tìm kiếm ───────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search_rounded),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 14),
      ),
    );
  }
}

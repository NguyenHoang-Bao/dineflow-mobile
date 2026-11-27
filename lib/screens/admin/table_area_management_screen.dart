import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/reservation_repository.dart';
import '../../models/reservation.dart';
import '../../models/table_model.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/confirm_dialog.dart';

/// Quản lý bàn & khu vực.
/// Kết nối thật với AdminRepository.
/// - `is_locked` (PATCH /admin/tables/{id}/toggle-locked): khóa / mở khóa tạm thời.
/// - `is_active` (PATCH /admin/tables/{id}/toggle-active): vô hiệu hóa hẳn bàn.
///
/// Kèm lịch đặt bàn hôm nay (GET /reservations?date=) để thấy bàn nào sắp có khách đặt —
/// nhất là bàn đang phục vụ mà sắp tới giờ khách đặt.
class TableAreaManagementScreen extends StatefulWidget {
  const TableAreaManagementScreen({super.key});

  @override
  State<TableAreaManagementScreen> createState() => _TableAreaManagementScreenState();
}

/// Lượt đặt trong khoảng này mà bàn còn đang phục vụ thì cảnh báo đỏ.
const _conflictWindow = Duration(minutes: 60);

/// Khớp GRACE_MINUTES ở backend: quá giờ hẹn chừng này mà khách chưa tới thì lượt đặt tự hủy.
const _grace = Duration(minutes: 15);

class _TableAreaManagementScreenState extends State<TableAreaManagementScreen> {
  final _repo = AdminRepository.instance;

  List<TableModel> _tables = [];
  bool _loading = true;
  String? _error;

  /// Lượt đặt sắp tới trong hôm nay, theo id bàn (lượt gần nhất). Lỗi tải thì để trống.
  Map<String, Reservation> _nextReservation = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _repo.fetchTables(),
        _fetchTodayReservations(),
      ]);
      if (!mounted) return;
      setState(() {
        _tables = results[0] as List<TableModel>;
        _nextReservation = results[1] as Map<String, Reservation>;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _loading = false; });
    }
  }

  /// Lỗi ở lịch đặt không được làm hỏng cả màn quản lý bàn → nuốt lỗi, trả map rỗng.
  Future<Map<String, Reservation>> _fetchTodayReservations() async {
    try {
      final list = await ReservationRepository.instance.fetchForDate(DateUtils.dateOnly(DateTime.now()));
      final cutoff = DateTime.now().subtract(_grace);
      final upcoming = list
          .where((r) => r.status == ReservationStatus.upcoming && r.dateTime.isAfter(cutoff))
          .toList()
        ..sort((a, b) => a.dateTime.compareTo(b.dateTime));
      final map = <String, Reservation>{};
      for (final r in upcoming) {
        for (final id in r.tableIds) {
          map.putIfAbsent(id, () => r);
        }
      }
      return map;
    } on ApiException {
      return {};
    }
  }

  // ── Khóa / Mở khóa tạm thời (is_locked) ─────────────────────────────────

  Future<void> _toggleLock(TableModel table) async {
    if (!table.isLocked && table.status == TableStatus.serving) {
      _snack('Không thể khóa ${table.number} khi đang có khách', isWarn: true);
      return;
    }
    try {
      final updated = await _repo.toggleTableLocked(table.id);
      _replace(updated);
      _snack(updated.isLocked ? 'Đã khóa ${table.number}' : 'Đã mở khóa ${table.number}');
    } on ApiException catch (e) {
      _snack(e.message, isError: true);
    }
  }

  // ── Vô hiệu hóa hẳn (is_active) ─────────────────────────────────────────

  Future<void> _toggleActive(TableModel table) async {
    // Server cũng chặn, nhưng chặn ngay ở đây thì không phải xác nhận xong mới thấy báo lỗi.
    if (table.isActive && table.status == TableStatus.serving) {
      _snack('Không thể vô hiệu hóa ${table.number} khi đang có khách. Hãy thanh toán hoặc chuyển bàn trước.',
          isWarn: true);
      return;
    }
    final reservation = _nextReservation[table.id];
    final ok = await showConfirmDialog(
      context,
      title: table.isActive ? 'Vô hiệu hóa ${table.number}?' : 'Kích hoạt lại ${table.number}?',
      message: table.isActive
          ? 'Bàn sẽ bị ẩn khỏi sơ đồ của NV Order và khách không đặt được. '
              'Chỉ dùng khi bàn bị tháo hoặc khu vực đóng dài ngày.'
              '${reservation == null ? '' : '\n\nLưu ý: hôm nay có khách đặt bàn này lúc ${AppFormatters.time(reservation.dateTime)} (${reservation.code}).'}'
          : 'Bàn sẽ xuất hiện lại trong sơ đồ bàn.',
      confirmLabel: table.isActive ? 'Vô hiệu hóa' : 'Kích hoạt',
      destructive: table.isActive,
      confirmColor: table.isActive ? null : AppColors.success,
    );
    if (!ok) return;
    try {
      final updated = await _repo.toggleTableActive(table.id);
      _replace(updated);
      _snack(updated.isActive ? 'Đã kích hoạt ${table.number}' : 'Đã vô hiệu hóa ${table.number}');
    } on ApiException catch (e) {
      _snack(e.message, isError: true);
    }
  }

  void _replace(TableModel updated) {
    setState(() {
      final i = _tables.indexWhere((t) => t.id == updated.id);
      if (i >= 0) _tables[i] = updated;
    });
  }

  // ── Form thêm / sửa bàn ──────────────────────────────────────────────────

  void _showTableForm([TableModel? table]) {
    final areas = _orderedAreas();
    final numberCtrl = TextEditingController(text: table?.number ?? '');
    final capacityCtrl = TextEditingController(text: table != null ? '${table.capacity}' : '');
    final depositCtrl = TextEditingController(
      text: (table != null && table.depositAmount > 0) ? table.depositAmount.toInt().toString() : '',
    );
    // Một ô chọn khu vực: các khu vực đã có + mục "Khu vực mới…". Chỉ khi chọn mục mới
    // (hoặc chưa có khu vực nào) mới hiện ô nhập tên khu vực.
    const newAreaValue = '__new_area__';
    String areaChoice = table?.area ?? (areas.isNotEmpty ? areas.first : newAreaValue);
    // Tạo controller MỘT lần (không tạo trong builder) để chữ đang gõ không bị mất khi sheet vẽ lại.
    final newAreaCtrl = TextEditingController();
    String resolvedArea() => areaChoice == newAreaValue ? newAreaCtrl.text.trim() : areaChoice;
    final formKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (bCtx, setSheet) {
          final bottomInset = MediaQuery.of(bCtx).viewInsets.bottom;
          return Container(
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
            padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)))),
                  Text(table == null ? 'Thêm bàn mới' : 'Sửa bàn', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 20),
                  AppTextField(
                    controller: numberCtrl, label: 'Tên bàn', hint: 'VD: Bàn 5, Bàn VIP 1',
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Vui lòng nhập tên bàn' : null,
                  ),
                  const SizedBox(height: 14),
                  AppTextField(
                    controller: capacityCtrl, label: 'Sức chứa (người)', hint: 'VD: 4',
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Vui lòng nhập sức chứa';
                      if (int.tryParse(v.trim()) == null || int.parse(v.trim()) < 1) return 'Sức chứa phải là số nguyên dương';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  AppTextField(
                    controller: depositCtrl,
                    label: 'Tiền cọc bàn (VNĐ)',
                    hint: 'VD: 100000 (để trống nếu không cọc)',
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      if (v != null && v.trim().isNotEmpty) {
                        final val = double.tryParse(v.trim());
                        if (val == null || val < 0) return 'Tiền cọc phải là số không âm';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  Text('Khu vực', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  const SizedBox(height: 8),
                  if (areas.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: areaChoice,
                      decoration: InputDecoration(contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border))),
                      items: [
                        for (final a in areas) DropdownMenuItem(value: a, child: Text(a)),
                        const DropdownMenuItem(value: newAreaValue, child: Text('+ Khu vực mới…')),
                      ],
                      onChanged: (v) => setSheet(() => areaChoice = v ?? areaChoice),
                    ),
                  // Ô nhập tên khu vực mới: chỉ hiện khi chọn "Khu vực mới…" hoặc chưa có khu vực nào
                  if (areaChoice == newAreaValue) ...[
                    if (areas.isNotEmpty) const SizedBox(height: 10),
                    AppTextField(
                      controller: newAreaCtrl,
                      label: 'Tên khu vực mới',
                      hint: 'VD: Tầng 3, Sân vườn',
                      validator: (v) {
                        final name = (v ?? '').trim();
                        if (name.isEmpty) return 'Vui lòng nhập tên khu vực';
                        // Gõ trùng khu vực đã có (khác hoa/thường) thì nhắc chọn trong danh sách
                        final existing = areas.where((a) => a.toLowerCase() == name.toLowerCase());
                        if (existing.isNotEmpty) return 'Khu vực "${existing.first}" đã có, hãy chọn trong danh sách';
                        return null;
                      },
                    ),
                  ],
                  const SizedBox(height: 20),
                  AppButton(
                    label: table == null ? 'Thêm bàn' : 'Lưu thay đổi',
                    onPressed: () async {
                      if (!formKey.currentState!.validate()) return;
                      final deposit = double.tryParse(depositCtrl.text.trim()) ?? 0.0;
                      Navigator.of(bCtx).pop();
                      setState(() => _loading = true);
                      try {
                        if (table == null) {
                          await _repo.createTable(
                            number: numberCtrl.text.trim(),
                            area: resolvedArea(),
                            capacity: int.parse(capacityCtrl.text.trim()),
                            depositAmount: deposit,
                          );
                          _snack('Đã thêm bàn "${numberCtrl.text.trim()}"');
                        } else {
                          await _repo.updateTable(
                            table.id,
                            number: numberCtrl.text.trim(),
                            area: resolvedArea(),
                            capacity: int.parse(capacityCtrl.text.trim()),
                            depositAmount: deposit,
                          );
                          _snack('Đã cập nhật "${table.number}"');
                        }
                        _load();
                      } on ApiException catch (e) {
                        _snack(e.message, isError: true);
                        setState(() => _loading = false);
                      }
                    },
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  void _snack(String msg, {bool isError = false, bool isWarn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppColors.error : isWarn ? AppColors.warning : null,
      ));
  }

  /// Số đầu tiên trong tên bàn ("Bàn 12" → 12); không có số thì xếp cuối.
  static int _tableNo(TableModel t) =>
      int.tryParse(RegExp(r'\d+').firstMatch(t.number)?.group(0) ?? '') ?? 1 << 30;

  /// Khu vực xếp theo số bàn nhỏ nhất trong khu (Tầng 1: Bàn 1–6, Tầng 2: Bàn 7–10,
  /// Ngoài trời: Bàn 11–12), không theo ABC — ABC đẩy "Ngoài trời" lên trước "Tầng 1".
  List<String> _orderedAreas() {
    final first = <String, int>{};
    for (final t in _tables) {
      final n = _tableNo(t);
      first[t.area] = first.containsKey(t.area) && first[t.area]! <= n ? first[t.area]! : n;
    }
    return first.keys.toList()
      ..sort((a, b) {
        final c = first[a]!.compareTo(first[b]!);
        return c != 0 ? c : a.compareTo(b);
      });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bàn & khu vực', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(icon: const Icon(Icons.add), tooltip: 'Thêm bàn', onPressed: () => _showTableForm()),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.error_outline_rounded, color: AppColors.error, size: 48),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 16),
                    TextButton(onPressed: _load, child: const Text('Thử lại')),
                  ]))
                : _tables.isEmpty
                    ? Center(child: Text('Chưa có bàn nào', style: TextStyle(color: AppColors.textSecondary)))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // Điện thoại 3 cột (ô gọn), máy rất hẹp 2 cột, màn rộng 4–5 cột.
                            final w = constraints.maxWidth;
                            final columns = w >= 900 ? 5 : w >= 600 ? 4 : w >= 340 ? 3 : 2;
                            return ListView(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                              children: [
                                _StatusSummary(tables: _tables),
                                const SizedBox(height: 14),
                                for (final area in _orderedAreas()) ..._areaSection(area, columns),
                              ],
                            );
                          },
                        ),
                      ),
      ),
    );
  }

  List<Widget> _areaSection(String area, int columns) {
    final tables = _tables.where((t) => t.area == area).toList()
      ..sort((a, b) {
        final c = _tableNo(a).compareTo(_tableNo(b));
        return c != 0 ? c : a.number.compareTo(b.number);
      });
    final serving = tables.where((t) => t.isActive && t.status == TableStatus.serving).length;
    final reserved = tables.where((t) => _nextReservation.containsKey(t.id)).length;

    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        // Tên khu và dòng tóm tắt cùng một hàng; tóm tắt co lại (…) nếu máy quá hẹp.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(area, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  '${tables.length} bàn',
                  if (serving > 0) '$serving có khách',
                  if (reserved > 0) '$reserved khách đặt',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
      GridView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          mainAxisExtent: 100,
        ),
        children: [
          for (final t in tables)
            _TableTile(
              table: t,
              reservation: _nextReservation[t.id],
              onEdit: () => _showTableForm(t),
              onToggleLock: () => _toggleLock(t),
              onToggleActive: () => _toggleActive(t),
            ),
        ],
      ),
      const SizedBox(height: 16),
    ];
  }
}

/// Dòng tóm tắt toàn quán ở đầu trang: số bàn theo từng trạng thái, mỗi trạng thái một chấm màu
/// (cũng là chú thích màu cho các ô bên dưới).
class _StatusSummary extends StatelessWidget {
  final List<TableModel> tables;

  const _StatusSummary({required this.tables});

  @override
  Widget build(BuildContext context) {
    final active = tables.where((t) => t.isActive).toList();
    int count(_TileState s) => tables.where((t) => _TileState.of(t) == s).length;
    final items = [
      for (final s in _TileState.values)
        if (count(s) > 0 || s == _TileState.empty || s == _TileState.serving) (s, count(s)),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Text('${active.length} bàn',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final (state, n) in items)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Dot(color: state.color),
                      const SizedBox(width: 5),
                      Text('$n ${state.label.toLowerCase()}',
                          style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Trạng thái hiển thị của một ô bàn ở màn Admin (gộp trạng thái bàn với khóa / vô hiệu hóa).
enum _TileState {
  empty,
  serving,
  reserved,
  locked,
  inactive;

  static _TileState of(TableModel t) {
    if (!t.isActive) return inactive;
    if (t.isLocked) return locked;
    return switch (t.status) {
      TableStatus.serving => serving,
      TableStatus.reserved => reserved,
      TableStatus.locked => locked,
      TableStatus.empty => empty,
    };
  }

  String get label => switch (this) {
        empty => 'Trống',
        serving => 'Có khách',
        reserved => 'Đặt trước',
        locked => 'Đang khóa',
        inactive => 'Vô hiệu',
      };

  Color get color => switch (this) {
        empty => AppColors.success,
        serving => AppColors.error,
        reserved => AppColors.warning,
        locked => AppColors.textSecondary,
        inactive => AppColors.border,
      };
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) =>
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

// ── Ô bàn ───────────────────────────────────────────────────────────────────

class _TableTile extends StatelessWidget {
  final TableModel table;
  final Reservation? reservation;
  final VoidCallback onEdit;
  final VoidCallback onToggleLock;
  final VoidCallback onToggleActive;

  const _TableTile({
    required this.table,
    required this.reservation,
    required this.onEdit,
    required this.onToggleLock,
    required this.onToggleActive,
  });

  @override
  Widget build(BuildContext context) {
    final state = _TileState.of(table);
    final isInactive = state == _TileState.inactive;
    final r = reservation;
    // Bàn đang có khách mà sắp tới giờ khách khác đặt → cần xử lý (mời khách / đổi bàn cho lượt đặt).
    final conflict = r != null &&
        table.status == TableStatus.serving &&
        r.dateTime.isBefore(DateTime.now().add(_conflictWindow));

    return FadeSlideIn(
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 8, 0, 9),
        decoration: BoxDecoration(
          color: isInactive || state == _TileState.locked ? AppColors.surfaceAlt : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: conflict ? AppColors.error : (isInactive ? AppColors.border.withValues(alpha: 0.5) : AppColors.border),
            width: conflict ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    table.number,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15.5,
                      color: isInactive ? AppColors.textSecondary : AppColors.textPrimary,
                    ),
                  ),
                ),
                SizedBox(
                  width: 30,
                  height: 26,
                  child: PopupMenuButton<String>(
                    tooltip: 'Thao tác với ${table.number}',
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.more_vert_rounded, size: 18, color: AppColors.textSecondary),
                    onSelected: (v) {
                      if (v == 'edit') onEdit();
                      if (v == 'lock') onToggleLock();
                      if (v == 'active') onToggleActive();
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: _MenuText('Sửa bàn', 'Tên, sức chứa, khu vực')),
                      if (!isInactive)
                        PopupMenuItem(
                          value: 'lock',
                          child: table.isLocked
                              ? const _MenuText('Mở khóa', 'NV Order mở bàn lại được')
                              : const _MenuText('Khóa tạm', 'Tạm không nhận khách (vd đang sửa, dọn)'),
                        ),
                      PopupMenuItem(
                        value: 'active',
                        child: isInactive
                            ? const _MenuText('Kích hoạt lại', 'Hiện lại trong sơ đồ bàn')
                            : _MenuText('Vô hiệu hóa', 'Ẩn hẳn khỏi sơ đồ (bàn đã tháo)', color: AppColors.error),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text('${table.capacity} khách', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                if (table.depositAmount > 0) ...[
                  Text(' · ', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  Expanded(
                    child: Text(
                      'Cọc ${AppFormatters.currency(table.depositAmount)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primaryDark),
                    ),
                  ),
                ],
              ],
            ),
            const Spacer(),
            Row(
              children: [
                if (state == _TileState.locked)
                  Icon(Icons.lock_outline_rounded, size: 12, color: state.color)
                else
                  _Dot(color: state.color),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(state.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ),
              ],
            ),
            if (r != null && !isInactive)
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 8),
                child: Text(
                  conflict ? 'Đặt ${AppFormatters.time(r.dateTime)} · còn khách' : 'Đặt ${AppFormatters.time(r.dateTime)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: conflict ? AppColors.error : AppColors.info,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Dòng trong menu ⋮: tên thao tác + giải thích ngắn (khóa tạm và vô hiệu hóa dễ nhầm nhau).
class _MenuText extends StatelessWidget {
  final String title;
  final String hint;
  final Color? color;
  const _MenuText(this.title, this.hint, {this.color});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: color ?? AppColors.textPrimary)),
          Text(hint, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      );
}

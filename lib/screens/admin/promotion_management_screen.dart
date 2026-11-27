import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../models/promotion.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/status_badge.dart';

/// Quản lý khuyến mãi / voucher.
/// Kết nối thật với AdminRepository.
class PromotionManagementScreen extends StatefulWidget {
  const PromotionManagementScreen({super.key});

  @override
  State<PromotionManagementScreen> createState() => _PromotionManagementScreenState();
}

class _PromotionManagementScreenState extends State<PromotionManagementScreen> {
  final _repo = AdminRepository.instance;

  List<Promotion> _promos = [];
  bool _loading = true;
  String? _error;

  /// Lọc theo nhóm trạng thái; null = tất cả.
  _PromoGroup? _filter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      _promos = await _repo.fetchPromotions();
      setState(() => _loading = false);
    } on ApiException catch (e) {
      setState(() { _error = e.message; _loading = false; });
    }
  }

  // ── Bật / Tắt khuyến mãi ────────────────────────────────────────────────

  Future<void> _toggleActive(Promotion promo) async {
    final isActive = promo.isActive;
    final ok = await showConfirmDialog(
      context,
      title: '${isActive ? "Tắt" : "Bật"} khuyến mãi',
      message: 'Bạn muốn ${isActive ? 'tắt' : 'bật'} "${promo.name}"?\n'
          '${isActive ? "Khách không dùng được mã ${promo.code} nữa, kể cả khi còn hạn." : "Mã ${promo.code} dùng lại được trong thời gian áp dụng."}',
      confirmLabel: isActive ? 'Tắt' : 'Bật',
      destructive: isActive,
      confirmColor: isActive ? null : AppColors.success,
    );
    if (!ok) return;
    try {
      final updated = await _repo.togglePromotionActive(promo.id);
      setState(() {
        final i = _promos.indexWhere((p) => p.id == promo.id);
        if (i >= 0) _promos[i] = updated;
      });
      _snack(updated.isActive
          ? '${promo.name}: đã bật'
          : '${promo.name}: đã tắt');
    } on ApiException catch (e) {
      if (_handleDeleted(e)) return;
      _snack(e.message, isError: true);
    }
  }

  /// Khuyến mãi đã bị xóa ở nơi khác (vd trên web /admin) → server trả 404.
  /// Báo rõ cho người dùng và tải lại danh sách để bỏ mục đã mất.
  bool _handleDeleted(ApiException e) {
    if (e.statusCode != 404) return false;
    _snack('Khuyến mãi này không còn trên hệ thống (có thể đã bị xóa trên web). Đã tải lại danh sách.', isError: true);
    _load();
    return true;
  }

  // ── Form thêm / sửa ──────────────────────────────────────────────────────

  void _showForm([Promotion? promo]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PromotionFormSheet(
        existing: promo,
        onSaved: (name, code, percent, maxDiscount, minOrder, from, to) async {
          Navigator.of(ctx).pop();
          setState(() => _loading = true);
          try {
            if (promo == null) {
              await _repo.createPromotion(
                title: name, code: code, discountPercent: percent,
                maxDiscount: maxDiscount, minOrderAmount: minOrder,
                validFrom: from, validTo: to,
              );
              _snack('Đã thêm khuyến mãi "$name"');
            } else {
              await _repo.updatePromotion(
                promo.id,
                title: name, discountPercent: percent,
                maxDiscount: maxDiscount, minOrderAmount: minOrder,
                validFrom: from, validTo: to,
              );
              _snack('Đã cập nhật "$name"');
            }
            _load();
          } on ApiException catch (e) {
            if (_handleDeleted(e)) return;
            _snack(e.message, isError: true);
            setState(() => _loading = false);
          }
        },
      ),
    );
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: isError ? AppColors.error : null));
  }

  /// Nhóm hiển thị của khuyến mãi: "Đã tắt" (admin tắt) tách khỏi "Đã hết hạn" (quá ngày).
  static _PromoGroup _groupOf(Promotion p) {
    if (p.endDate.isBefore(DateTime.now())) return _PromoGroup.expired;
    if (!p.isActive) return _PromoGroup.off;
    return p.status == PromotionStatus.upcoming ? _PromoGroup.upcoming : _PromoGroup.active;
  }

  /// Đang áp dụng → Sắp diễn ra → Đã tắt → Hết hạn; trong nhóm: sắp hết hạn trước.
  List<Promotion> get _visible {
    final list = _promos.where((p) => _filter == null || _groupOf(p) == _filter).toList()
      ..sort((a, b) {
        final g = _groupOf(a).index.compareTo(_groupOf(b).index);
        if (g != 0) return g;
        return _groupOf(a) == _PromoGroup.expired
            ? b.endDate.compareTo(a.endDate) // hết hạn: mới hết trước
            : a.endDate.compareTo(b.endDate);
      });
    return list;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Khuyến mãi', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(icon: const Icon(Icons.add), tooltip: 'Thêm khuyến mãi', onPressed: () => _showForm()),
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
                : _promos.isEmpty
                    ? Center(child: Text('Chưa có khuyến mãi nào', style: TextStyle(color: AppColors.textSecondary)))
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(children: [
                                for (final g in <_PromoGroup?>[null, ..._PromoGroup.values])
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: FilterChip(
                                      label: Text('${g?.label ?? 'Tất cả'} '
                                          '(${g == null ? _promos.length : _promos.where((p) => _groupOf(p) == g).length})'),
                                      selected: _filter == g,
                                      onSelected: (_) => setState(() => _filter = g),
                                    ),
                                  ),
                              ]),
                            ),
                          ),
                          Expanded(
                            child: Builder(builder: (context) {
                              final promos = _visible;
                              if (promos.isEmpty) {
                                return Center(
                                  child: Text('Không có khuyến mãi nào ở mục này',
                                      style: TextStyle(color: AppColors.textSecondary)),
                                );
                              }
                              return RefreshIndicator(
                                onRefresh: _load,
                                child: ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                                  itemCount: promos.length,
                                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                                  itemBuilder: (ctx, i) => _PromoTile(
                                    promo: promos[i],
                                    onEdit: () => _showForm(promos[i]),
                                    onToggle: () => _toggleActive(promos[i]),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ],
                      ),
      ),
    );
  }
}

enum _PromoGroup {
  active('Đang áp dụng'),
  upcoming('Sắp diễn ra'),
  off('Đã tắt'),
  expired('Hết hạn');

  final String label;
  const _PromoGroup(this.label);
}

// ── Tile khuyến mãi ─────────────────────────────────────────────────────────

class _PromoTile extends StatelessWidget {
  final Promotion promo;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  const _PromoTile({required this.promo, required this.onEdit, required this.onToggle});

  Color get _statusColor => !promo.isActive
      ? AppColors.warning
      : switch (promo.status) {
          PromotionStatus.active => AppColors.success,
          PromotionStatus.upcoming => AppColors.info,
          PromotionStatus.expired => AppColors.textSecondary,
        };

  /// "Đã tắt" (admin tắt) tách riêng khỏi "Đã hết hạn" (quá ngày kết thúc).
  String get _statusLabel => promo.isActive ? promo.status.label : 'Đã tắt';

  @override
  Widget build(BuildContext context) {
    // Bật/Tắt theo cờ is_active; chỉ ẩn nút khi đã quá ngày kết thúc (muốn dùng lại thì Sửa ngày).
    final canToggle = promo.endDate.isAfter(DateTime.now());
    final isActive = promo.isActive;

    // Gọn: bỏ hàng nút riêng ở dưới. Chạm thẻ = Sửa / Gia hạn; công tắc ở góc = Bật / Tắt.
    return FadeSlideIn(
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onEdit,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              // Ô % giảm nổi bật bên trái
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isActive && canToggle ? AppColors.primaryLight : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('-${promo.percent}%',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(promo.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: AppColors.textPrimary)),
                    ),
                    const SizedBox(width: 6),
                    StatusBadge(label: _statusLabel, color: _statusColor, background: _statusColor.withValues(alpha: 0.12)),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    [
                      promo.code,
                      if (promo.maxDiscount != null) 'tối đa ${AppFormatters.currency(promo.maxDiscount!)}',
                      if (promo.minOrderAmount > 0) 'đơn từ ${AppFormatters.currency(promo.minOrderAmount)}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                  ),
                  Text(
                    '${AppFormatters.date(promo.startDate)} – ${AppFormatters.date(promo.endDate)}'
                    // Hết hạn thì việc hay làm nhất là đổi ngày để chạy lại → nói rõ chạm để gia hạn.
                    '${canToggle ? '' : ' · chạm để gia hạn'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ]),
              ),
              if (canToggle)
                Tooltip(
                  message: isActive ? 'Tắt khuyến mãi' : 'Bật khuyến mãi',
                  child: Transform.scale(
                    scale: 0.85,
                    child: Switch.adaptive(value: isActive, onChanged: (_) => onToggle()),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.update_rounded, color: AppColors.textSecondary),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ── Form Sheet ───────────────────────────────────────────────────────────────

class _PromotionFormSheet extends StatefulWidget {
  final Promotion? existing;
  final void Function(
    String name, String code, int percent,
    double? maxDiscount, double minOrder,
    DateTime from, DateTime to,
  ) onSaved;

  const _PromotionFormSheet({this.existing, required this.onSaved});

  @override
  State<_PromotionFormSheet> createState() => _PromotionFormSheetState();
}

class _PromotionFormSheetState extends State<_PromotionFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _nameCtrl = TextEditingController(text: widget.existing?.name);
  late final _codeCtrl = TextEditingController(text: widget.existing?.code);
  late final _percentCtrl = TextEditingController(text: widget.existing != null ? '${widget.existing!.percent}' : '');
  late final _maxCtrl = TextEditingController(text: widget.existing?.maxDiscount?.toStringAsFixed(0) ?? '');
  late final _minCtrl = TextEditingController(text: widget.existing != null && widget.existing!.minOrderAmount > 0 ? widget.existing!.minOrderAmount.toStringAsFixed(0) : '');

  late DateTime _from = widget.existing?.startDate ?? DateTime.now();
  late DateTime _to = widget.existing?.endDate ?? DateTime.now().add(const Duration(days: 30));

  Future<void> _pickDate(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _codeCtrl.dispose(); _percentCtrl.dispose();
    _maxCtrl.dispose(); _minCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.6,
      expand: false,
      builder: (ctx, scroll) => Container(
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
        padding: EdgeInsets.only(left: 20, right: 20, top: 8, bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Form(
          key: _formKey,
          child: ListView(controller: scroll, children: [
            Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Text(isNew ? 'Thêm khuyến mãi' : 'Sửa khuyến mãi', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 18),
            AppTextField(controller: _nameCtrl, label: 'Tên chương trình', hint: 'VD: Khuyến mãi hè 2026',
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Vui lòng nhập tên' : null),
            const SizedBox(height: 12),
            AppTextField(controller: _codeCtrl, label: 'Mã voucher', hint: 'VD: SUMMER20',
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Vui lòng nhập mã' : null),
            const SizedBox(height: 12),
            AppTextField(controller: _percentCtrl, label: 'Phần trăm giảm (%)', hint: 'VD: 20',
              keyboardType: TextInputType.number,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Vui lòng nhập %';
                final n = int.tryParse(v.trim());
                if (n == null || n < 1 || n > 100) return '% phải từ 1–100';
                return null;
              }),
            const SizedBox(height: 12),
            AppTextField(controller: _maxCtrl, label: 'Giảm tối đa (đồng, để trống = không giới hạn)', hint: 'VD: 100000',
              keyboardType: TextInputType.number),
            const SizedBox(height: 12),
            AppTextField(controller: _minCtrl, label: 'Đơn tối thiểu (đồng, để trống = không yêu cầu)', hint: 'VD: 200000',
              keyboardType: TextInputType.number),
            const SizedBox(height: 14),
            // Date pickers
            Row(children: [
              Expanded(child: _DateTile(label: 'Từ ngày', date: _from, onTap: () => _pickDate(true))),
              const SizedBox(width: 10),
              Expanded(child: _DateTile(label: 'Đến ngày', date: _to, onTap: () => _pickDate(false))),
            ]),
            const SizedBox(height: 24),
            AppButton(
              label: isNew ? 'Tạo khuyến mãi' : 'Lưu thay đổi',
              onPressed: () {
                if (!_formKey.currentState!.validate()) return;
                if (_to.isBefore(_from)) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ngày kết thúc phải sau ngày bắt đầu')));
                  return;
                }
                widget.onSaved(
                  _nameCtrl.text.trim(),
                  _codeCtrl.text.trim().toUpperCase(),
                  int.parse(_percentCtrl.text.trim()),
                  _maxCtrl.text.trim().isEmpty ? null : double.parse(_maxCtrl.text.trim()),
                  _minCtrl.text.trim().isEmpty ? 0 : double.parse(_minCtrl.text.trim()),
                  _from, _to,
                );
              },
            ),
          ]),
        ),
      ),
    );
  }
}

class _DateTile extends StatelessWidget {
  final String label;
  final DateTime date;
  final VoidCallback onTap;
  const _DateTile({required this.label, required this.date, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(AppFormatters.date(date), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

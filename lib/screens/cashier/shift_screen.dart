import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../data/mock_data.dart';
import '../../models/invoice.dart';
import '../../models/shift.dart';
import '../../data/shift_repository.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header_band.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/money_input.dart';
import '../../widgets/status_badge.dart';

/// Icon tương ứng với từng phương thức thanh toán.
IconData paymentMethodIcon(PaymentMethod method) => switch (method) {
  PaymentMethod.cash => Icons.payments_rounded,
  PaymentMethod.qr   => Icons.qr_code_rounded,
  PaymentMethod.card => Icons.credit_card_rounded,
};

void _snack(ScaffoldMessengerState messenger, String text, {bool error = false}) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text), backgroundColor: error ? AppColors.error : null));

/// Hộp mở ca dùng chung cho tab Ca làm, Tổng quan và màn Thanh toán (thu ngân bấm thanh toán
/// mà chưa mở ca thì mở luôn tại chỗ, khỏi phải quay ra rồi chọn lại voucher / thành viên).
/// Trả về ca vừa mở, hoặc null nếu thu ngân hủy / lỗi (lỗi đã được báo bằng snackbar).
Future<Shift?> showOpenShiftDialog(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final cash = await showDialog<double>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _OpenShiftDialog(),
  );
  if (cash == null) return null;
  try {
    final shift = await ShiftRepository.instance.openShift(openingCash: cash);
    _snack(messenger, 'Đã mở ca lúc ${AppFormatters.time(shift.openedAt)}');
    return shift;
  } on ApiException catch (e) {
    _snack(messenger, e.message, error: true);
    return null;
  }
}

/// Tab Ca làm: thông tin ca hiện tại, doanh thu theo phương thức, mở/đóng ca.
///
/// Lấy dữ liệu thật từ `ShiftRepository` và tự tải lại mỗi khi có hóa đơn mới (trước đây chỉ
/// tải một lần khi mở app nên thu tiền xong tab vẫn ghi 0đ, và hộp đóng ca tính chênh lệch
/// từ số liệu cũ). Kéo xuống để làm mới. Đóng ca xong hiện bảng kết quả của ca vừa đóng.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key});

  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  final _repo = ShiftRepository.instance;
  bool _loading = true;
  String? _error;

  /// Ca vừa đóng trong phiên này: hiện kết quả (chênh lệch do server tính) thay vì về trống ngay.
  Shift? _justClosed;

  @override
  void initState() {
    super.initState();
    _repo.current.addListener(_onShiftChanged);
    // Thu tiền xong AppData tải lại hóa đơn → tải lại ca để số liệu ca khớp.
    MockData.invoicesVersion.addListener(_reloadQuietly);
    _loadShift();
  }

  @override
  void dispose() {
    _repo.current.removeListener(_onShiftChanged);
    MockData.invoicesVersion.removeListener(_reloadQuietly);
    super.dispose();
  }

  void _onShiftChanged() {
    if (!mounted) return;
    setState(() {
      if (_repo.current.value != null) _justClosed = null;
    });
  }

  Future<void> _loadShift() async {
    setState(() {
      _loading = !_repo.loaded;
      _error = null;
    });
    try {
      await _repo.fetchCurrent();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Không tải được thông tin ca làm. Thử lại sau.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reloadQuietly() async {
    try {
      await _repo.fetchCurrent();
    } catch (_) {
      // Lỗi mạng tạm thời: giữ số liệu đang có, thu ngân có thể kéo để thử lại.
    }
  }

  // ── Đóng ca ──────────────────────────────────────────────────────────────

  Future<void> _closeShift() async {
    final messenger = ScaffoldMessenger.of(context);
    // Luôn lấy số liệu MỚI NHẤT ngay trước khi đếm két, không dùng số đang hiện trên màn.
    final Shift? fresh;
    try {
      fresh = await _repo.fetchCurrent();
    } on ApiException catch (e) {
      _snack(messenger, e.message, error: true);
      return;
    }
    if (!mounted) return;
    if (fresh == null) {
      _snack(messenger, 'Ca này đã được đóng trước đó.');
      return;
    }

    final counted = await showDialog<double>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CloseShiftDialog(shift: fresh!),
    );
    if (counted == null || !mounted) return;

    // Đóng rồi không sửa lại được (server từ chối đóng lần hai) → lệch tiền thì hỏi lại một lần nữa.
    final diff = counted - fresh.expectedCash;
    if (diff.abs() >= 1) {
      final ok = await showConfirmDialog(
        context,
        title: diff < 0 ? 'Két đang thiếu ${AppFormatters.currency(diff.abs())}' : 'Két đang dư ${AppFormatters.currency(diff)}',
        message: 'Bạn nhập ${AppFormatters.currency(counted)}, hệ thống tính phải có '
            '${AppFormatters.currency(fresh.expectedCash)}. Đóng ca rồi thì không sửa lại số này được. '
            'Đếm lại nếu chưa chắc.',
        confirmLabel: 'Vẫn đóng ca',
        cancelLabel: 'Đếm lại',
        destructive: diff < 0,
      );
      if (!ok || !mounted) return;
    }

    try {
      final closed = await _repo.closeShift(shiftId: fresh.id, closingCashCounted: counted);
      if (!mounted) return;
      setState(() => _justClosed = closed);
      _snack(messenger, 'Đã đóng ca lúc ${AppFormatters.time(closed.closedAt!)}');
    } on ApiException catch (e) {
      _snack(messenger, e.message, error: true);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    final shift = _repo.current.value;
    if (_error != null && shift == null && _justClosed == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_off_rounded, size: 48, color: AppColors.textSecondary),
                  const SizedBox(height: 12),
                  Text(_error!, textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(height: 16),
                  AppButton(label: 'Thử lại', onPressed: _loadShift),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (shift != null && shift.isOpen) return _buildOpenShift(shift);
    return _buildNoShift();
  }

  /// Chưa mở ca → nút Mở ca; nếu vừa đóng ca trong phiên này thì hiện kết quả ca đó ở trên.
  Widget _buildNoShift() {
    var i = 0;
    Widget appear(Widget w) => FadeSlideIn.staggered(index: i++, child: w);
    final closed = _justClosed;

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      body: Column(
        children: [
          const AppHeaderBand(caption: 'Thông tin ca hiện tại', title: 'Ca làm việc'),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadShift,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                children: [
                  if (closed != null) ...[
                    appear(_ClosedShiftSummary(shift: closed)),
                    const SizedBox(height: 12),
                  ],
                  appear(Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(color: AppColors.primaryLight, shape: BoxShape.circle),
                          child: Icon(Icons.lock_clock_outlined, color: AppColors.textPrimary, size: 28),
                        ),
                        const SizedBox(height: 14),
                        Text('Chưa có ca đang mở',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.textPrimary)),
                        const SizedBox(height: 6),
                        Text(
                          'Mở ca để bắt đầu nhận thanh toán.\nMỗi thu ngân chỉ có một ca mở tại một thời điểm.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary, height: 1.4),
                        ),
                      ],
                    ),
                  )),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: AppButton(
                label: closed != null ? 'Mở ca mới' : 'Mở ca',
                icon: Icons.lock_open_rounded,
                onPressed: () => showOpenShiftDialog(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Ca đang mở → hiện thông tin + doanh thu + nút Đóng ca.
  Widget _buildOpenShift(Shift shift) {
    final totalRevenue = shift.revenueByMethod.total;
    final byMethod = {
      PaymentMethod.cash: shift.revenueByMethod.cash,
      PaymentMethod.qr: shift.revenueByMethod.qr,
      PaymentMethod.card: shift.revenueByMethod.card,
    };

    var order = 0;
    Widget step(Widget child) => FadeSlideIn.staggered(index: order++, child: child);

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      body: Column(
        children: [
          const AppHeaderBand(caption: 'Thông tin ca hiện tại', title: 'Ca làm việc'),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadShift,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                children: [
                  // Thẻ thông tin ca
                  step(Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        const _IconTile(icon: Icons.badge_outlined),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(shift.cashierName,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.textPrimary)),
                              const SizedBox(height: 2),
                              Text(
                                'Bắt đầu: ${AppFormatters.time(shift.openedAt)} · '
                                'Tiền đầu ca: ${AppFormatters.currency(shift.openingCash)}',
                                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.3),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        StatusBadge(label: 'Đang mở', color: AppColors.textOnDark, background: AppColors.ink),
                      ],
                    ),
                  )),
                  const SizedBox(height: 12),

                  // Tổng thu ca này
                  step(Container(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Tổng thu ca này',
                                      style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary)),
                                  const SizedBox(height: 4),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: CountUpText(
                                      value: totalRevenue,
                                      formatter: (v) => AppFormatters.currency(v.round()),
                                      style: TextStyle(
                                        fontSize: 30,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.textPrimary,
                                        letterSpacing: -0.6,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: StatusBadge(
                                label: '${shift.invoiceCount} hóa đơn',
                                color: AppColors.textPrimary,
                                background: AppColors.surfaceAlt,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Số tiền mặt phải có trong két lúc này — đối chiếu nhanh khi giao ca.
                        _InfoRow(
                          label: 'Tiền mặt phải có trong két',
                          value: AppFormatters.currency(shift.expectedCash),
                        ),
                      ],
                    ),
                  )),
                  const SizedBox(height: 22),

                  // Doanh thu theo phương thức
                  step(Text('Doanh thu theo phương thức',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary))),
                  const SizedBox(height: 10),
                  step(Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        for (final method in PaymentMethod.values)
                          _MethodRow(
                            method: method,
                            value: byMethod[method]!,
                            share: totalRevenue == 0 ? 0 : byMethod[method]! / totalRevenue,
                          ),
                      ],
                    ),
                  )),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: AppButton(
                label: 'Đóng ca',
                icon: Icons.lock_outline_rounded,
                onPressed: _closeShift,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hộp mở ca: ô tiền đầu ca để trống (không còn số "0" sẵn) và tự thêm dấu chấm.
class _OpenShiftDialog extends StatefulWidget {
  const _OpenShiftDialog();

  @override
  State<_OpenShiftDialog> createState() => _OpenShiftDialogState();
}

class _OpenShiftDialogState extends State<_OpenShiftDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = parseMoney(_ctrl.text);
    return AlertDialog(
      title: const Text('Mở ca làm việc'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tiền mặt có sẵn trong két lúc nhận ca:'),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            inputFormatters: const [MoneyInputFormatter()],
            textInputAction: TextInputAction.done,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'vd 500.000', suffixText: 'đ'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Text('Két trống thì nhập 0.', style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
        TextButton(
          onPressed: amount == null ? null : () => Navigator.pop(context, amount),
          child: const Text('Mở ca'),
        ),
      ],
    );
  }
}

/// Hộp đóng ca: số liệu mới tải từ server, ô tiền đếm được để trống, chênh lệch tính khi gõ.
class _CloseShiftDialog extends StatefulWidget {
  final Shift shift;

  const _CloseShiftDialog({required this.shift});

  @override
  State<_CloseShiftDialog> createState() => _CloseShiftDialogState();
}

class _CloseShiftDialogState extends State<_CloseShiftDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shift = widget.shift;
    final counted = parseMoney(_ctrl.text);
    final diff = counted == null ? null : counted - shift.expectedCash;

    return AlertDialog(
      title: const Text('Đóng ca làm việc'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: 'Tiền mở ca', value: AppFormatters.currency(shift.openingCash)),
            _InfoRow(label: 'Thu tiền mặt trong ca', value: AppFormatters.currency(shift.revenueByMethod.cash)),
            _InfoRow(label: 'Tiền mặt phải có', value: AppFormatters.currency(shift.expectedCash)),
            const SizedBox(height: 14),
            const Text('Số tiền mặt đếm được trong két:'),
            const SizedBox(height: 10),
            TextField(
              controller: _ctrl,
              keyboardType: TextInputType.number,
              inputFormatters: const [MoneyInputFormatter()],
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(hintText: 'Đếm két rồi nhập', suffixText: 'đ'),
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            if (diff != null)
              Row(
                children: [
                  const Text('Chênh lệch: ', style: TextStyle(fontWeight: FontWeight.w600)),
                  Flexible(
                    child: Text(
                      diff.abs() < 1
                          ? 'Khớp'
                          : diff > 0
                              ? '+${AppFormatters.currency(diff)} (dư)'
                              : '-${AppFormatters.currency(diff.abs())} (thiếu)',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: diff.abs() < 1
                            ? AppColors.success
                            : (diff > 0 ? AppColors.textPrimary : AppColors.error),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
        TextButton(
          onPressed: counted == null ? null : () => Navigator.pop(context, counted),
          child: Text('Đóng ca', style: TextStyle(color: counted == null ? null : AppColors.error)),
        ),
      ],
    );
  }
}

/// Kết quả ca vừa đóng (số do server tính): để thu ngân đối chiếu và báo quản lý.
class _ClosedShiftSummary extends StatelessWidget {
  final Shift shift;

  const _ClosedShiftSummary({required this.shift});

  @override
  Widget build(BuildContext context) {
    final diff = shift.cashDifference ?? 0;
    final diffText = diff.abs() < 1
        ? 'Khớp'
        : diff > 0
            ? '+${AppFormatters.currency(diff)} (dư)'
            : '-${AppFormatters.currency(diff.abs())} (thiếu)';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Ca vừa đóng',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary)),
              ),
              StatusBadge(label: 'Đã đóng', color: AppColors.textSecondary, background: AppColors.surfaceAlt),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${AppFormatters.time(shift.openedAt)} – ${shift.closedAt == null ? '' : AppFormatters.time(shift.closedAt!)}'
            ' · ${shift.invoiceCount} hóa đơn · ${AppFormatters.currency(shift.revenueByMethod.total)}',
            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          _InfoRow(label: 'Tiền mặt phải có', value: AppFormatters.currency(shift.expectedCash)),
          _InfoRow(label: 'Đếm được', value: AppFormatters.currency(shift.closingCashCounted ?? 0)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(child: Text('Chênh lệch', style: TextStyle(color: AppColors.textSecondary, fontSize: 13))),
                Text(diffText,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: diff.abs() < 1 ? AppColors.success : (diff > 0 ? AppColors.textPrimary : AppColors.error),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Hàng thông tin nhỏ trong dialog đóng ca.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(color: AppColors.textSecondary, fontSize: 13))),
          Text(value, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  final IconData icon;

  const _IconTile({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 21, color: AppColors.textPrimary),
    );
  }
}

/// Một dòng doanh thu theo phương thức: ô icon, nhãn, số tiền và thanh tỉ lệ.
class _MethodRow extends StatelessWidget {
  final PaymentMethod method;
  final double value;

  /// Tỉ lệ trên tổng thu, từ 0 tới 1.
  final double share;

  const _MethodRow({required this.method, required this.value, required this.share});

  static Color _barColor(PaymentMethod method) => switch (method) {
        PaymentMethod.cash => AppColors.ink,
        PaymentMethod.qr   => AppColors.primary,
        PaymentMethod.card => AppColors.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _IconTile(icon: paymentMethodIcon(method)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(method.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14.5, color: AppColors.textPrimary)),
                    ),
                    const SizedBox(width: 8),
                    AnimatedValueText(
                      AppFormatters.currency(value),
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14.5, color: AppColors.textPrimary),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 7,
                    color: AppColors.border,
                    alignment: Alignment.centerLeft,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: share.clamp(0, 1)),
                      duration: AppMotion.slow,
                      curve: Curves.easeOutCubic,
                      builder: (context, v, _) => FractionallySizedBox(
                        widthFactor: v,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _barColor(method),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

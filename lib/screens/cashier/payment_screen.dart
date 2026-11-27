import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../data/app_data.dart';
import '../../data/invoice_repository.dart';
import '../../data/loyalty_rules.dart';
//import '../../data/member_repository.dart';
import '../../data/mock_data.dart';
import '../../data/order_staff_repository.dart';
import '../../data/settings_repository.dart';
import '../../data/shift_repository.dart';
import '../../models/customer.dart';
import '../../models/invoice.dart';
import '../../models/order.dart';
import '../../models/promotion.dart';
import '../../theme/app_colors.dart';
import '../../theme/status_visuals.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header_band.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/dashed_divider.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/invoice_card.dart';
import '../../widgets/labeled_value_row.dart';
import '../../widgets/live_data.dart';
import '../../widgets/money_input.dart';
import '../../widgets/order_card.dart' show orderStatusVisual;
import '../../widgets/order_items_card.dart';
import '../../widgets/status_badge.dart';
import 'invoice_screen.dart' show InvoiceScreenArgs;
import 'shift_screen.dart' show showOpenShiftDialog;

// Tài khoản nhận chuyển khoản lấy từ server (GET /api/settings → config/restaurant.php),
// không viết cứng trong app. Xem SettingsRepository.

/// Màn hình thanh toán – Quy tắc Kiểu A:
///
/// - Không dùng điểm để trừ tiền.
/// - Giảm = max(giảm theo hạng, giảm theo voucher). Không cộng dồn.
/// - Thu ngân có thể gắn khách thành viên bằng QR hoặc nhập mã để áp giảm hạng.
/// - Server tính lại và cộng điểm khi xác nhận.
/// - Thu ngân có thể Hủy đơn (chỉ đơn chưa thanh toán).
/// - Tiền cọc (đặt bàn kèm món trước) được hiển thị và khấu trừ vào tổng cuối.
/// - Đơn đã gắn khách thành viên (khách đặt bàn được nhận bàn...) thì server TỰ giảm theo hạng
///   của khách đó; màn này tính theo đúng khách đó để số hiển thị khớp hóa đơn (trước đây chỉ tính
///   khi thu ngân quét mã nên màn hình báo 60.000đ mà hóa đơn chỉ 54.500đ).
/// - Chưa mở ca thì báo ngay từ đầu và cho mở ca tại chỗ (server từ chối thanh toán khi chưa mở ca).
/// - Tiền mặt: nhập tiền khách đưa để biết tiền thối (chỉ để thu ngân tính, không gửi lên server).
class PaymentScreen extends StatefulWidget {
  final String orderId;
  const PaymentScreen({super.key, required this.orderId});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  Promotion? _promotion;
  PaymentMethod _method = PaymentMethod.cash;
  bool _paying = false;
  bool _cancelling = false;
  Timer? _sepayPollingTimer;

  @override
  void dispose() {
    _sepayPollingTimer?.cancel();
    _shifts.current.removeListener(_onShiftChanged);
    _tenderedCtrl.dispose();
    super.dispose();
  }

  void _onShiftChanged() {
    if (mounted) setState(() {});
  }

  /// Biết trước thu ngân đã mở ca chưa (lỗi mạng thì không chặn: server vẫn kiểm tra lại).
  Future<void> _loadShift() async {
    try {
      await _shifts.fetchCurrent();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _onMethodChanged(PaymentMethod method, Order order, Promotion? promotion) {
    if (_method == method) return;
    setState(() => _method = method);
    if (method == PaymentMethod.qr) {
      _startSepayPolling(order, promotion);
    } else {
      _sepayPollingTimer?.cancel();
    }
  }

  void _startSepayPolling(Order order, Promotion? promotion) {
    _sepayPollingTimer?.cancel();
    _sepayPollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!mounted || _paying || _method != PaymentMethod.qr) {
        timer.cancel();
        return;
      }
      try {
        if (await _isTransferReceived(order)) {
          timer.cancel();
          if (mounted) _onTransferReceived(order);
        }
      } catch (_) {
        // Bỏ qua lỗi polling tạm thời
      }
    });
  }

  /// Hỏi server (SePay) xem đơn đã nhận được chuyển khoản chưa.
  Future<bool> _isTransferReceived(Order order) async {
    final code = order.code ?? order.displayCode;
    final res = await ApiClient.instance.get('/payment/check-status/$code');
    return (res.data as Map?)?['is_paid'] == true;
  }

  /// SePay báo đã nhận tiền: thông báo xanh như phía khách rồi tự xác nhận.
  void _onTransferReceived(Order order) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Row(children: [
          Icon(Icons.check_circle_rounded, color: Colors.white),
          SizedBox(width: 8),
          Expanded(child: Text('Khách đã chuyển khoản thành công! Đang hoàn tất thanh toán...')),
        ]),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ));
    _pay(order, promotion: _qrPromotion, viaSepay: true);
  }

  /// Nút "Kiểm tra trạng thái ngay" (giống màn thanh toán của khách).
  Future<void> _checkNow(Order order) async {
    if (_checking || _paying) return;
    setState(() => _checking = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (await _isTransferReceived(order)) {
        _sepayPollingTimer?.cancel();
        if (mounted) _onTransferReceived(order);
      } else {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('Chưa nhận được tiền từ ngân hàng. Kiểm tra lại sau giây lát.'),
            duration: Duration(seconds: 2),
          ));
      }
    } catch (_) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Không kiểm tra được lúc này. Vui lòng thử lại.')));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Khách thành viên thu ngân vừa quét / nhập mã (đơn chưa gắn khách nào).
  Customer? _member;

  /// Tiền khách đưa khi trả tiền mặt (chỉ để tính tiền thối; ô trống = không nhập).
  final _tenderedCtrl = TextEditingController();

  final _shifts = ShiftRepository.instance;

  // Số liệu đang hiện trên QR (cập nhật mỗi lần dựng màn), để khi SePay báo đã nhận tiền thì
  // xác nhận / dựng hóa đơn đúng với số khách vừa chuyển.
  double _qrTotal = 0;
  double _qrDiscount = 0;
  Promotion? _qrPromotion;
  bool _checking = false;

  /// Danh sách khuyến mãi đang hoạt động — tải từ API thật khi màn hình mở.
  List<Promotion> _promotions = [];
  bool _loadingPromotions = true;

  static TextStyle get _sectionStyle =>
      TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary);

  @override
  void initState() {
    super.initState();
    _shifts.current.addListener(_onShiftChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPromotions();
      _loadShift();
    });
  }

  /// Tải khuyến mãi đang hoạt động từ API thật.
  Future<void> _loadPromotions() async {
    try {
      final list = await OrderStaffRepository.instance.fetchActivePromotions();
      if (mounted) setState(() => _promotions = list);
    } catch (_) {
      // Lỗi tải khuyến mãi không chặn thanh toán — dùng danh sách rỗng.
    } finally {
      if (mounted) setState(() => _loadingPromotions = false);
    }
  }

  /// Gắn khách thành viên vào phiên thanh toán.
  Future<void> _scanMember(Order order) async {
    // Không gán thẳng vào `Customer?`: Dart sẽ hiểu là pushNamed<Customer?> và đòi route kiểu
    // Route<Customer?>, trong khi routes.dart tạo MaterialPageRoute<dynamic> → lỗi ép kiểu,
    // bấm vào ô không mở được màn quét. Nhận Object? rồi kiểm tra kiểu.
    final result = await Navigator.of(context).pushNamed(AppRoutes.cashierScanMember);
    final customer = result is Customer ? result : null;
    if (customer == null || !mounted) return;
    setState(() => _member = customer);
  }

  Future<void> _pay(Order order, {required Promotion? promotion, bool viaSepay = false}) async {
    if (_paying) return;
    setState(() => _paying = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final Invoice invoice = await InvoiceRepository.instance.pay(
        order.id,
        method: _method,
        promotionCode: promotion?.code,
        memberCode: _member?.memberCode,
      );
      unawaited(AppData.refresh({LiveSource.orders, LiveSource.tables, LiveSource.invoices}, force: true));
      navigator.pushReplacementNamed(AppRoutes.cashierInvoice,
          arguments: InvoiceScreenArgs(
            invoice,
            afterPayment: true,
            memberName: order.customerId != null ? (order.customerName ?? 'khách hàng') : _member?.name,
          ));
    } on ApiException catch (e) {
      // Backend (27/11): webhook SePay đánh dấu đơn đã trả, lệnh xác nhận của app tạo hóa đơn bình thường.
      // Server chỉ từ chối khi đơn ĐÃ CÓ hóa đơn (vd máy khác vừa xuất) → mở đúng hóa đơn đó.
      if (e.message.contains('đã được thanh toán')) {
        await AppData.refresh({LiveSource.orders, LiveSource.tables, LiveSource.invoices}, force: true);
        final existing = MockData.invoices.where((i) => i.orderId == order.id).firstOrNull;
        if (existing != null) {
          navigator.pushReplacementNamed(AppRoutes.cashierInvoice,
              arguments: InvoiceScreenArgs(existing, afterPayment: true,
                  notice: 'Đơn này đã được xuất hóa đơn trước đó (có thể ở máy khác).'));
          return;
        }
      }
      if (viaSepay && e.message.contains('đã được thanh toán')) {
        final now = DateTime.now();
        navigator.pushReplacementNamed(AppRoutes.cashierInvoice,
            arguments: InvoiceScreenArgs(
              Invoice(
                id: order.id,
                orderId: order.id,
                orderCode: order.code,
                tableNumber: order.tableNumber,
                items: order.items,
                subtotal: order.subtotal,
                discount: _qrDiscount,
                depositAmount: order.depositAmount,
                total: _qrTotal,
                paymentMethod: PaymentMethod.qr,
                createdAt: now,
                paidAt: now,
                cashierName: MockData.currentCashier.name,
                promotionCode: _qrPromotion?.code,
              ),
              afterPayment: true,
              memberName: order.customerId != null ? (order.customerName ?? 'khách hàng') : _member?.name,
              notice: 'Đã nhận chuyển khoản qua SePay nhưng không tải được hóa đơn từ hệ thống. '
                  'Kiểm tra lại ở tab Lịch sử, báo quản lý nếu không thấy.',
            ));
        return;
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
      unawaited(AppData.refresh({LiveSource.orders}, force: true));
      unawaited(_loadShift());
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  /// Hủy đơn — chỉ thu ngân, chỉ đơn chưa thanh toán, bắt buộc chọn lý do (nhóm chốt 13/11).
  Future<void> _cancel(Order order) async {
    if (_cancelling) return;

    final choice = await showDialog<({String reason, String note})>(
      context: context,
      builder: (ctx) => _CancelReasonDialog(orderCode: order.displayCode, deposit: order.depositAmount),
    );
    if (choice == null || !mounted) return;

    setState(() => _cancelling = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      await OrderStaffRepository.instance.cancelOrder(order.id, reason: choice.reason, note: choice.note);
      unawaited(AppData.refresh({LiveSource.orders, LiveSource.tables}, force: true));
      navigator.pop();
      // Nhóm chốt 26/11: khách hủy thì quán giữ cọc, không hoàn lại.
      final keptDeposit = order.hasDeposit && choice.reason == _customerCancelReason;
      messenger.showSnackBar(
        SnackBar(
          content: Text(keptDeposit
              ? 'Đã hủy đơn #${order.displayCode}. Quán giữ tiền cọc ${AppFormatters.currency(order.depositAmount)}.'
              : 'Đã hủy đơn #${order.displayCode}'),
        ),
      );
    } on ApiException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  void _lockedHint() => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(
        content: Text('Đang hiện mã QR nên không đổi được voucher. Chọn "Tiền mặt" để đổi rồi chọn lại QR.')));

  /// Bếp chưa mang món ra (chờ bếp / đang làm).
  static bool _unserved(Order order) =>
      order.status == OrderStatus.placed || order.status == OrderStatus.preparing;

  /// Mục 4, phương án A (nhóm chốt 26/11): server đóng đơn và trả bàn ngay khi thanh toán, kể cả
  /// khi bếp chưa làm xong → hỏi lại trước khi thu tiền đơn chưa ra món. Không đổi luồng tự xác
  /// nhận chuyển khoản (SePay) vì nó gọi thẳng [_pay].
  Future<void> _confirmUnservedThenPay(Order order, Promotion? promotion) async {
    if (_unserved(order)) {
      final ok = await showConfirmDialog(
        context,
        title: '${order.tableNumber ?? 'Đơn này'} chưa ra món',
        message: 'Bếp ${order.status == OrderStatus.placed ? 'chưa nhận' : 'đang làm'} đơn #${order.displayCode}. '
            'Thanh toán bây giờ sẽ đóng đơn và trả bàn: NV Order và bếp không còn thấy đơn, '
            'sơ đồ bàn hiện Trống dù khách vẫn đang ngồi chờ món.\n\n'
            'Chỉ thanh toán trước khi khách cần đi ngay.',
        confirmLabel: 'Thu luôn',
        cancelLabel: 'Đợi ra món',
      );
      if (!ok || !mounted) return;
    }
    await _pay(order, promotion: promotion);
  }

  @override
  Widget build(BuildContext context) =>
      LiveData(sources: const {LiveSource.orders}, builder: (context, _) => _buildContent(context));

  Widget _buildContent(BuildContext context) {
    final order = MockData.findOrder(widget.orderId);
    if (order == null) {
      return const Scaffold(
        body: SafeArea(
          child: EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'Không tìm thấy đơn hàng',
            message: 'Đơn này có thể đã được thanh toán hoặc bị hủy',
          ),
        ),
      );
    }

    final subtotal = order.subtotal;

    final applicablePromotions = _promotions.where((p) => p.appliesTo(subtotal)).toList();
    final promotion = applicablePromotions.any((p) => p.id == _promotion?.id) ? _promotion : null;

    final member = _member;
    // Đơn đã gắn khách: server dùng khách này (bỏ qua mã quét thêm), nên tính theo đúng khách đó.
    final linked = order.customerId != null;
    final int? memberPoints = linked ? order.customerPoints : member?.points;
    double tierDiscount = 0;
    int tierPercent = 0;
    if (memberPoints != null) {
      tierPercent = LoyaltyRules.tierFor(memberPoints).discountPercent;
      // Làm tròn như server (round 2 chữ số) để số hiển thị khớp hóa đơn.
      tierDiscount = (subtotal * tierPercent / 100 * 100).roundToDouble() / 100;
    }

    final promoDiscount = promotion?.discountFor(subtotal) ?? 0.0;
    final discount = (tierDiscount > promoDiscount) ? tierDiscount : promoDiscount;
    final usingTierDiscount = tierDiscount > promoDiscount && tierDiscount > 0;

    final depositAmount = order.depositAmount;
    // clamp(0.0, ...) thay vì clamp(0, ...) để Dart suy ra kiểu double thay vì num.
    final total = (subtotal - discount - depositAmount).clamp(0.0, double.infinity);

    final effectivePromotion = usingTierDiscount ? null : promotion;
    _qrTotal = total;
    _qrDiscount = discount;
    _qrPromotion = effectivePromotion;
    // Đang hiện QR: khóa voucher / thành viên để số tiền không đổi sau khi khách đã quét.
    final qrLocked = _method == PaymentMethod.qr;

    // Ca: đã tải xong mà không có ca đang mở → chưa thu tiền được.
    final noShift = _shifts.loaded && !(_shifts.current.value?.isOpen ?? false);
    // SePay đã nhận tiền (đơn đã trả nhưng chưa xuất hóa đơn): chỉ còn việc xuất hóa đơn, ghi nhận là QR.
    final transferReceived = order.isPaid && order.isOpen;
    if (transferReceived && _method != PaymentMethod.qr) _method = PaymentMethod.qr;
    // Tiền mặt: khách đưa thiếu thì chưa cho xác nhận (ô trống = không kiểm tra).
    final tendered = _method == PaymentMethod.cash ? parseMoney(_tenderedCtrl.text) : null;
    final shortCash = tendered != null && tendered < total;

    var step = 0;
    Widget appear(Widget child) => FadeSlideIn.staggered(index: step++, child: child);

    return Scaffold(
      backgroundColor: AppColors.surfaceAlt,
      body: Column(
        children: [
          AppHeaderBand(
            title: order.tableNumber != null ? 'Thanh toán · ${order.tableNumber}' : 'Thanh toán',
            subtitle: 'Đơn #${order.displayCode} · ${order.items.length} món · ${orderStepShortLabel(order.status)}',
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
              children: [
                if (noShift) ...[
                  _NoShiftBanner(onOpen: () => showOpenShiftDialog(context)),
                  const SizedBox(height: 14),
                ],
                if (transferReceived) ...[
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: AppColors.successBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
                    ),
                    child: Row(children: [
                      Icon(Icons.check_circle_rounded, color: AppColors.success),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Đã nhận chuyển khoản qua SePay. Bấm "Xuất hóa đơn" để ghi vào ca và hoàn tất đơn.',
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 14),
                ],
                if (_unserved(order) && !transferReceived) ...[
                  _UnservedNote(status: order.status),
                  const SizedBox(height: 14),
                ],
                appear(OrderItemsCard(items: order.items, quantityColor: AppColors.primaryLight)),
                const SizedBox(height: 18),

                // ── Thành viên ───────────────────────────────────────────
                appear(Text('Thành viên', style: _sectionStyle)),
                const SizedBox(height: 10),
                appear(IgnorePointer(
                  ignoring: qrLocked,
                  child: Opacity(opacity: qrLocked ? 0.6 : 1, child: _buildMemberSection(order, member, linked: linked)),
                )),
                const SizedBox(height: 18),

                // ── Voucher ──────────────────────────────────────────────
                appear(Text('Voucher', style: _sectionStyle)),
                const SizedBox(height: 10),
                if (_loadingPromotions)
                  appear(const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ))
                else
                  appear(Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _ChoicePill(
                        label: 'Không dùng',
                        selected: _promotion == null,
                        onTap: qrLocked ? _lockedHint : () => setState(() => _promotion = null),
                      ),
                      for (final p in applicablePromotions)
                        _ChoicePill(
                          label: '${p.code} · -${p.percent}%',
                          selected: promotion?.id == p.id,
                          onTap: qrLocked ? _lockedHint : () => setState(() => _promotion = p),
                        ),
                      if (applicablePromotions.isEmpty && !_loadingPromotions)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Không có voucher áp dụng được cho đơn này',
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                          ),
                        ),
                    ],
                  )),
                if (promotion != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    [
                      'Giảm ${promotion.percent}%',
                      if (promotion.maxDiscount != null) 'tối đa ${AppFormatters.currency(promotion.maxDiscount!)}',
                      if (promotion.minOrderAmount > 0) 'đơn từ ${AppFormatters.currency(promotion.minOrderAmount)}',
                      'hạn tới ${AppFormatters.date(promotion.endDate)}',
                    ].join(' · '),
                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                  ),
                  if (usingTierDiscount)
                    Text('Giảm theo hạng thành viên cao hơn nên voucher không được dùng (không cộng dồn).',
                        style: TextStyle(fontSize: 12.5, color: AppColors.warning, fontWeight: FontWeight.w600)),
                ],
                const SizedBox(height: 18),

                // ── Tổng tiền ────────────────────────────────────────────
                appear(Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      LabeledValueRow(
                        label: 'Tạm tính',
                        value: AppFormatters.currency(subtotal),
                        animateValue: true,
                      ),
                      if (discount > 0)
                        LabeledValueRow(
                          label: usingTierDiscount
                              ? 'Giảm hạng ${LoyaltyRules.tierFor(memberPoints!).label} ($tierPercent%)'
                              : 'Giảm giá (${promotion?.code})',
                          value: '-${AppFormatters.currency(discount)}',
                          animateValue: true,
                        ),
                      if (depositAmount > 0)
                        LabeledValueRow(
                          label: 'Đã cọc (đặt bàn)',
                          value: '-${AppFormatters.currency(depositAmount)}',
                          animateValue: true,
                        ),
                      const SizedBox(height: 8),
                      const DashedDivider(),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Text('Tổng tiền',
                              style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  color: AppColors.textPrimary)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: AnimatedValueText(
                                  AppFormatters.currency(total),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 28,
                                    color: AppColors.textPrimary,
                                    letterSpacing: -0.6,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (memberPoints != null && total > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Icon(Icons.stars_rounded, size: 14, color: AppColors.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                'Khách được +${LoyaltyRules.pointsEarned(total)} điểm',
                                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                )),
                const SizedBox(height: 18),

                // ── Phương thức thanh toán ───────────────────────────────
                appear(Text('Phương thức thanh toán', style: _sectionStyle)),
                const SizedBox(height: 10),
                appear(Row(
                  children: [
                    for (final method in PaymentMethod.values) ...[
                      if (method != PaymentMethod.values.first) const SizedBox(width: 8),
                      Expanded(
                        child: _MethodTile(
                          method: method,
                          selected: _method == method,
                          onTap: () => _onMethodChanged(method, order, _promotion),
                        ),
                      ),
                    ],
                  ],
                )),
                const SizedBox(height: 14),

                if (_method == PaymentMethod.cash)
                  appear(_CashTenderPanel(
                    total: total,
                    controller: _tenderedCtrl,
                    onChanged: () => setState(() {}),
                  )),
                // ── Panel QR hoặc Thẻ (hiện khi chọn tương ứng) ─────────
                if (_method == PaymentMethod.qr && !transferReceived)
                  appear(noShift
                      ? const EmptyState(
                          icon: Icons.lock_clock_outlined,
                          title: 'Mở ca trước khi cho khách quét mã',
                          message: 'Chưa mở ca thì không ghi nhận được thanh toán.',
                        )
                      : _CashierQrPanel(amount: total, orderCode: order.displayCode)),
                if (_method == PaymentMethod.card)
                  appear(const _CardPaymentPanel()),
                const SizedBox(height: 24),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                children: [
                  if (transferReceived)
                    AppButton(
                      label: noShift ? 'Mở ca để xuất hóa đơn' : 'Xuất hóa đơn',
                      icon: Icons.receipt_long_rounded,
                      isLoading: _paying,
                      onPressed: _cancelling
                          ? null
                          : noShift
                              ? () => showOpenShiftDialog(context)
                              : () => _pay(order, promotion: effectivePromotion, viaSepay: true),
                    )
                  else if (_method == PaymentMethod.qr && !noShift)
                    _SepayWaitingBox(
                      orderCode: order.displayCode,
                      amount: total,
                      checking: _checking || _paying,
                      onCheckNow: () => _checkNow(order),
                      // Dự phòng khi SePay chậm / lỗi: thu ngân xem app ngân hàng rồi tự xác nhận.
                      onManualConfirm: _cancelling ? null : () => _confirmUnservedThenPay(order, effectivePromotion),
                    )
                  else
                    AppButton(
                    label: noShift
                        ? 'Mở ca để thu tiền'
                        : shortCash
                            ? 'Khách đưa chưa đủ tiền'
                            : 'Xác nhận thanh toán',
                    isLoading: _paying,
                    onPressed: _cancelling || shortCash
                        ? null
                        : noShift
                            ? () => showOpenShiftDialog(context)
                            : () => _confirmUnservedThenPay(order, effectivePromotion),
                  ),
                  // Đơn đã nhận tiền thì không hủy được nữa (server cũng từ chối hủy đơn đã trả).
                  if (!transferReceived) ...[
                  const SizedBox(height: 10),
                  AppButton(
                    label: 'Hủy đơn',
                    icon: Icons.cancel_outlined,
                    variant: AppButtonVariant.outlined,
                    dense: true,
                    isLoading: _cancelling,
                    onPressed: _paying ? null : () => _cancel(order),
                  ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberSection(Order order, Customer? member, {required bool linked}) {
    if (linked) {
      final tier = LoyaltyRules.tierFor(order.customerPoints);
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: AppColors.primaryLight, shape: BoxShape.circle),
              child: Icon(Icons.verified_user_outlined, color: AppColors.textPrimary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(order.customerName ?? 'Khách thành viên',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    '${tier.label} · ${order.customerPoints} điểm · '
                    '${order.reservationId != null ? 'khách đặt bàn' : 'đã gắn vào đơn'}',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    if (member != null) {
      final tier = LoyaltyRules.tierFor(member.points);
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: AppColors.primaryLight, shape: BoxShape.circle),
              child: Icon(Icons.badge_outlined, color: AppColors.textPrimary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(member.name,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    '${tier.label} · ${member.points} điểm · ${member.memberCode}',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            PressScale(
              onTap: () => setState(() => _member = null),
              scale: 0.9,
              child: Icon(Icons.close_rounded, size: 20, color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return PressScale(
      onTap: () => _scanMember(order),
      scale: 0.97,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code_scanner_rounded, color: AppColors.textPrimary, size: 20),
            const SizedBox(width: 10),
            Text(
              'Quét QR hoặc nhập mã thành viên',
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Panel QR chuyển khoản (Thu ngân)
// ─────────────────────────────────────────────────────────────────────────────

class _CashierQrPanel extends StatelessWidget {
  final double amount;
  final String orderCode;

  const _CashierQrPanel({required this.amount, required this.orderCode});

  @override
  Widget build(BuildContext context) {
    final bank = SettingsRepository.instance.bank;
    if (bank == null) {
      return const EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Chưa tải được thông tin chuyển khoản',
        message: 'Đăng nhập lại để tải tài khoản ngân hàng của nhà hàng, hoặc chọn thu tiền mặt / thẻ.',
      );
    }
    final noteText = orderCode;
    final qrUrl = bank.qrImageUrl(amount, noteText);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(children: [
            Icon(Icons.account_balance_rounded, size: 18, color: AppColors.textPrimary),
            const SizedBox(width: 8),
            Text(
              'Khách quét QR thanh toán',
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.textPrimary),
            ),
          ]),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black12, blurRadius: 12, offset: Offset(0, 4)),
                ],
              ),
              child: Image.network(
                qrUrl,
                width: 200,
                height: 200,
                fit: BoxFit.contain,
                loadingBuilder: (ctx, child, prog) {
                  if (prog == null) return child;
                  return const SizedBox(
                    width: 200,
                    height: 200,
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                },
                errorBuilder: (ctx, _, __) => Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.qr_code_2_rounded,
                          size: 72, color: AppColors.textSecondary),
                      const SizedBox(height: 8),
                      Text('Không tải được QR',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _InfoRowQ(label: 'Ngân hàng', value: bank.name),
          const SizedBox(height: 8),
          _InfoRowQ(label: 'Số TK', value: bank.accountNo),
          const SizedBox(height: 8),
          _InfoRowQ(label: 'Chủ TK', value: bank.accountName),
          const SizedBox(height: 8),
          _InfoRowQ(
              label: 'Số tiền',
              value: AppFormatters.currency(amount),
              highlight: true),
          const SizedBox(height: 8),
          _InfoRowQ(label: 'Nội dung', value: noteText),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(Icons.info_outline_rounded, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Yêu cầu khách quét mã QR bằng app ngân hàng. '
                  'Nhập đúng nội dung chuyển khoản để hệ thống xác nhận.',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.textPrimary, height: 1.4),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _InfoRowQ extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _InfoRowQ(
      {required this.label, required this.value, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(label,
              style:
                  TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight:
                  highlight ? FontWeight.w800 : FontWeight.w600,
              color: highlight
                  ? AppColors.primary
                  : AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Panel hướng dẫn thanh toán thẻ (POS)
// ─────────────────────────────────────────────────────────────────────────────

class _CardPaymentPanel extends StatelessWidget {
  const _CardPaymentPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.credit_card_rounded,
                size: 18, color: AppColors.textPrimary),
            const SizedBox(width: 8),
            Text(
              'Thanh toán qua máy POS',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: AppColors.textPrimary),
            ),
          ]),
          const SizedBox(height: 16),
          Center(
            child: Container(
              width: 230,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              decoration: BoxDecoration(
                color: AppColors.ink,
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26,
                      blurRadius: 16,
                      offset: Offset(0, 6)),
                ],
              ),
              child: Column(
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('POS Terminal',
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                      Icon(Icons.wifi_rounded,
                          color: Colors.white54, size: 15),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Container(
                    height: 40,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.nfc_rounded,
                            color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text('CHẠM / CÀ THẺ',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                letterSpacing: 0.5)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CardBadge('VISA'),
                      SizedBox(width: 6),
                      _CardBadge('MC'),
                      SizedBox(width: 6),
                      _CardBadge('JCB'),
                      SizedBox(width: 6),
                      _CardBadge('NAPAS'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const _PosStep(
            icon: Icons.looks_one_rounded,
            text:
                'Yêu cầu khách đưa thẻ hoặc điện thoại (Apple Pay / Google Pay)',
          ),
          const SizedBox(height: 10),
          const _PosStep(
            icon: Icons.looks_two_rounded,
            text: 'Chạm thẻ hoặc cà thẻ vào máy POS',
          ),
          const SizedBox(height: 10),
          const _PosStep(
            icon: Icons.looks_3_rounded,
            text: 'Khách nhập PIN nếu được yêu cầu',
          ),
          const SizedBox(height: 10),
          const _PosStep(
            icon: Icons.looks_4_rounded,
            text:
                'Chờ máy in biên lai, sau đó nhấn "Xác nhận thanh toán"',
          ),
        ],
      ),
    );
  }
}

class _CardBadge extends StatelessWidget {
  final String label;
  const _CardBadge(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5)),
    );
  }
}

class _PosStep extends StatelessWidget {
  final IconData icon;
  final String text;
  const _PosStep({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textPrimary,
                  height: 1.4)),
        ),
      ],
    );
  }
}

/// Viên lựa chọn voucher.
class _ChoicePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoicePill(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: PressScale(
        onTap: onTap,
        scale: 0.94,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.ink : AppColors.surface,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color:
                  selected ? AppColors.textOnDark : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Ô phương thức thanh toán.
class _MethodTile extends StatelessWidget {
  final PaymentMethod method;
  final bool selected;
  final VoidCallback onTap;

  const _MethodTile(
      {required this.method, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.textOnDark : AppColors.textPrimary;
    return Semantics(
      button: true,
      selected: selected,
      child: PressScale(
        onTap: onTap,
        scale: 0.95,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: Curves.easeOut,
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.ink : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(paymentMethodIcon(method), size: 21, color: fg),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(method.label,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: fg)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hộp thoại hủy đơn: chọn lý do (Nhập nhầm / Khách bỏ về / Hết món / Khác) + ghi chú.
/// "Khác" bắt buộc ghi chú. Trả về lựa chọn, hoặc null nếu không hủy.
/// Khóa lý do "Khách bỏ về" (OrderStaffRepository.cancelReasons) — trường hợp khách hủy.
const _customerCancelReason = 'customer_left';

class _CancelReasonDialog extends StatefulWidget {
  final String orderCode;

  /// Tiền cọc của đơn (khách đặt bàn đã cọc); 0 = không cọc.
  final double deposit;

  const _CancelReasonDialog({required this.orderCode, this.deposit = 0});

  @override
  State<_CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<_CancelReasonDialog> {
  String? _reason;
  final _noteCtrl = TextEditingController();

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  bool get _valid => _reason != null && (_reason != 'other' || _noteCtrl.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Hủy đơn #${widget.orderCode}?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Chọn lý do hủy (bắt buộc). Hành động này không thể hoàn tác.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            for (final entry in OrderStaffRepository.cancelReasons.entries)
              RadioListTile<String>(
                value: entry.key,
                groupValue: _reason,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(entry.value),
                onChanged: (v) => setState(() => _reason = v),
              ),
            if (widget.deposit > 0) ...[
              const SizedBox(height: 4),
              _DepositNote(deposit: widget.deposit, reason: _reason),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _noteCtrl,
              maxLength: 255,
              maxLines: 2,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: _reason == 'other' ? 'Ghi rõ lý do (bắt buộc)' : 'Ghi chú thêm (không bắt buộc)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Không')),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          onPressed: _valid ? () => Navigator.of(context).pop((reason: _reason!, note: _noteCtrl.text.trim())) : null,
          child: const Text('Hủy đơn'),
        ),
      ],
    );
  }
}


/// Dải cảnh báo "Bạn chưa mở ca" + nút mở ca ngay tại màn thanh toán.
class _NoShiftBanner extends StatelessWidget {
  final VoidCallback onOpen;

  const _NoShiftBanner({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_clock_outlined, color: AppColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Bạn chưa mở ca nên chưa thu tiền được.',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ),
          TextButton(onPressed: onOpen, child: const Text('Mở ca ngay')),
        ],
      ),
    );
  }
}

/// Tiền mặt: nhập / chọn nhanh tiền khách đưa → tiền thối lại hoặc còn thiếu.
/// Chỉ để thu ngân tính nhẩm cho đúng, không gửi lên server.
class _CashTenderPanel extends StatelessWidget {
  final double total;
  final TextEditingController controller;
  final VoidCallback onChanged;

  const _CashTenderPanel({required this.total, required this.controller, required this.onChanged});

  /// Mệnh giá hay gặp lớn hơn hoặc bằng tổng tiền: vừa đủ, làm tròn lên 10k / 50k / 100k / 500k.
  List<double> get _suggestions {
    double up(double step) => (total / step).ceil() * step;
    final list = <double>{total, up(10000), up(50000), up(100000), up(500000)}.where((v) => v > 0).toList()..sort();
    return list.take(4).toList();
  }

  void _set(double value) {
    controller.text = formatMoneyDigits(value.round().toString());
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final tendered = parseMoney(controller.text);
    final change = tendered == null ? null : tendered - total;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tiền khách đưa', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: const [MoneyInputFormatter()],
            decoration: const InputDecoration(hintText: 'Không bắt buộc', suffixText: 'đ', isDense: true),
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (i, v) in _suggestions.indexed)
                ActionChip(
                  label: Text(i == 0 && v == total ? 'Vừa đủ' : AppFormatters.currency(v),
                      style: TextStyle(fontSize: 12.5, color: AppColors.textPrimary)),
                  backgroundColor: AppColors.primaryLight,
                  side: BorderSide(color: AppColors.border),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _set(v),
                ),
            ],
          ),
          if (change != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(change >= 0 ? 'Tiền thối lại' : 'Còn thiếu',
                    style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                const Spacer(),
                Text(AppFormatters.currency(change.abs()),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: change >= 0 ? AppColors.textPrimary : AppColors.error,
                    )),
              ],
            ),
          ],
        ],
      ),
    );
  }
}


/// Ghi chú tiền cọc trong hộp hủy đơn (nhóm chốt 26/11: khách hủy thì quán giữ cọc).
class _DepositNote extends StatelessWidget {
  final double deposit;
  final String? reason;

  const _DepositNote({required this.deposit, required this.reason});

  @override
  Widget build(BuildContext context) {
    final money = AppFormatters.currency(deposit);
    final String text;
    if (reason == _customerCancelReason) {
      text = 'Khách hủy nên quán giữ tiền cọc $money, không hoàn lại.';
    } else if (reason == null) {
      text = 'Đơn có tiền cọc $money. Khách hủy (chọn "Khách bỏ về") thì quán giữ cọc, không hoàn lại.';
    } else {
      text = 'Đơn có tiền cọc $money. Lý do này không phải khách hủy: báo quản lý để xử lý tiền cọc.';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.savings_outlined, size: 18, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, color: AppColors.textPrimary, height: 1.35)),
          ),
        ],
      ),
    );
  }
}

/// Dải nhắc "chưa ra món" ở màn thanh toán (mục 4, phương án A).
class _UnservedNote extends StatelessWidget {
  final OrderStatus status;

  const _UnservedNote({required this.status});

  @override
  Widget build(BuildContext context) {
    final visual = orderStatusVisual(status);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.soup_kitchen_outlined, color: AppColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Bếp chưa ra món. Thanh toán bây giờ sẽ đóng đơn và trả bàn.',
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary, height: 1.35)),
          ),
          const SizedBox(width: 8),
          StatusBadge(label: orderStepShortLabel(status), color: visual.color, background: visual.background),
        ],
      ),
    );
  }
}


/// Khung "Đang chờ chuyển khoản..." giống màn thanh toán của khách: app tự kiểm tra mỗi 3 giây,
/// có nút kiểm tra ngay và nút xác nhận thủ công (khi thu ngân đã thấy tiền vào tài khoản).
class _SepayWaitingBox extends StatelessWidget {
  final String orderCode;
  final double amount;
  final bool checking;
  final VoidCallback onCheckNow;
  final VoidCallback? onManualConfirm;

  const _SepayWaitingBox({
    required this.orderCode,
    required this.amount,
    required this.checking,
    required this.onCheckNow,
    required this.onManualConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.primaryDark),
              ),
              const SizedBox(width: 10),
              Text('Đang chờ khách chuyển khoản...',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Khách chuyển ${AppFormatters.currency(amount)} với nội dung "$orderCode". '
            'Nhận được tiền là app tự hoàn tất thanh toán.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.4),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: checking ? null : onCheckNow,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Kiểm tra ngay'),
              ),
              TextButton(
                onPressed: checking ? null : onManualConfirm,
                child: const Text('Xác nhận thủ công'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../data/cart_store.dart';
import '../../core/api/api_exception.dart';
import '../../data/mock_data.dart';
import '../../data/reservation_repository.dart';
import '../../models/invoice.dart';
import '../../models/reservation.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_animations.dart';
import 'booking_confirmation_screen.dart';

/// Phiên đặt bàn qua app của Khách hàng, gồm 3 bước:
/// **Đặt bàn → Đặt món trước (có thể bỏ qua) → Thanh toán**.
///
/// Bàn được giữ ngay khi xong bước 1. Nếu trong [holdDuration] (10 phút) khách
/// chưa hoàn tất cả 3 bước, hoặc khách chủ động thoát giữa chừng, lượt đặt bàn
/// bị huỷ để bàn không bị giữ vô ích ("ngâm bàn").
///
/// LƯU Ý CHO BACKEND: việc tự huỷ ở đây chỉ chạy khi app đang mở. Cơ chế giữ
/// bàn và hết hạn thật phải được xử lý phía server (app có thể bị tắt giữa
/// chừng); app chỉ hiển thị đồng hồ đếm ngược và gọi huỷ khi hết giờ.
class BookingCheckout {
  BookingCheckout._();

  static final BookingCheckout instance = BookingCheckout._();

  /// Thời gian tối đa để hoàn tất 3 bước kể từ lúc giữ bàn.
  /// Để `static` không `const` để widget test có thể rút ngắn khi kiểm tra hết hạn.
  static Duration holdDuration = const Duration(minutes: 10);

  Reservation? _reservation;
  DateTime? _deadline;
  bool _active = false;
  double _tableDeposit = 0.0;

  /// Các món khách đặt trước trong phiên này. Dùng chung với danh sách món khách
  /// đã chọn ở Thực đơn / Trang chủ ([AppCart.customer]) nên món chọn trước khi
  /// đặt bàn có sẵn ở bước "Đặt món trước".
  CartStore get preOrder => AppCart.customer;

  Reservation? get reservation => _reservation;

  /// Tiền cọc cấu hình theo từng bàn của lượt đặt này.
  double get tableDeposit => _tableDeposit > 0 ? _tableDeposit : (_reservation?.depositAmount ?? 0.0);

  /// Phiên đang chạy: bàn đang được giữ, chưa thanh toán, chưa huỷ.
  bool get isActive => _active && _reservation != null;

  Duration get remaining {
    final deadline = _deadline;
    if (deadline == null) return Duration.zero;
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get isExpired => isActive && remaining == Duration.zero;

  /// Bắt đầu giữ bàn sau khi khách xác nhận ở bước Đặt bàn.
  void start(Reservation reservation, {double tableDeposit = 0.0}) {
    _reservation = reservation;
    _tableDeposit = tableDeposit > 0 ? tableDeposit : (reservation.depositAmount ?? 0.0);
    _deadline = DateTime.now().add(holdDuration);
    _active = true;
  }

  /// Tỉ lệ cọc khi đặt món trước (nhóm chốt 26/11: cọc 50%).
  static const depositRate = 0.5;

  /// Tiền cọc khách chuyển khi đặt món trước: 50% tiền món, làm tròn LÊN 100đ. Đúng công thức
  /// `Reservation::calculateDeposit` ở backend để số khách chuyển khớp số server ghi nhận (trước
  /// đây app bắt chuyển 100% tiền món trong khi server chỉ ghi 50% là cọc → khách trả hai lần).
  static double depositFor(double preOrderTotal) =>
      preOrderTotal <= 0 ? 0 : ((preOrderTotal * depositRate) / 100).ceilToDouble() * 100;

  /// Tiền cọc món ăn đặt trước (50% tiền món nếu có).
  double get foodDeposit => depositFor(preOrder.subtotal);

  /// Tổng tiền cọc của phiên: Tiền cọc theo từng bàn + Tiền cọc món đặt trước (nếu có).
  double get deposit => tableDeposit + foodDeposit;

  /// Bản lượt đặt này trên server (null nếu không tải được hoặc không tìm thấy).
  Future<Reservation?> fetchServerCopy() async {
    final id = _reservation?.id;
    if (id == null) return null;
    try {
      final list = await ReservationRepository.instance.fetchMine();
      return list.where((r) => r.id == id).firstOrNull;
    } on ApiException {
      return null;
    }
  }

  /// Server đã xác nhận lượt đặt (vd SePay nhận tiền cọc nhưng app chưa kịp biết vì mất mạng):
  /// kết thúc phiên bằng bản của server, KHÔNG hủy.
  void finishConfirmed(Reservation confirmed) {
    MockData.upsertReservation(confirmed);
    preOrder.clear();
    _active = false;
  }

  /// Lượt đặt trên server đã được xác nhận (không còn ở trạng thái giữ bàn).
  static bool isConfirmedOnServer(Reservation? r) =>
      r != null && r.status == ReservationStatus.upcoming && !r.isHeld;

  /// Hủy an toàn khi khách thoát / hết giờ: hỏi server trước. Nếu lượt đã được xác nhận (đã nhận
  /// cọc) thì KHÔNG hủy — trước đây app vẫn hủy, và theo quy định giữ cọc khi khách hủy thì khách
  /// mất tiền mà không có bàn. Trả về bản đã xác nhận để nơi gọi mở màn thành công; null = đã hủy.
  Future<Reservation?> releaseSafely() async {
    if (!isActive) return null;
    final server = await fetchServerCopy();
    if (isConfirmedOnServer(server)) {
      finishConfirmed(server!);
      return server;
    }
    release();
    return null;
  }

  /// Huỷ lượt giữ bàn (hết giờ hoặc khách thoát): hiện "đã huỷ" ngay trên máy và báo server nhả bàn.
  /// Báo server chạy nền; nếu thất bại (mất mạng) thì server cũng tự nhả khi hết hạn giữ bàn.
  /// Các món đã chọn vẫn được giữ lại để khách đặt lại không phải chọn từ đầu.
  /// Gọi qua [releaseSafely], trừ khi đã biết chắc server chưa xác nhận.
  void release() {
    if (!isActive) return;
    final reservation = _reservation!;
    _active = false;
    MockData.upsertReservation(reservation.copyWith(status: ReservationStatus.cancelled, clearHold: true));
    unawaited(_cancelOnServer(reservation.id));
  }

  static Future<void> _cancelOnServer(String id) async {
    try {
      await ReservationRepository.instance.cancel(id);
    } on ApiException {
      // Bỏ qua: lượt giữ bàn sẽ tự hết hạn ở server.
    }
  }

  /// Khách đã thanh toán xong: xác nhận lượt đặt trên server (kèm món đặt trước nếu có), kết thúc phiên.
  /// [payment] là phương thức khách chọn (null nếu không đặt món). Trả về lượt đặt đã xác nhận.
  ///
  /// Ném [ApiException] nếu server từ chối (vd. hết hạn giữ bàn, món hết hàng); khi đó phiên VẪN còn
  /// để khách xử lý (quay lại sửa món hoặc đặt lại).
  Future<Reservation> complete({PaymentMethod? payment}) async {
    final reservation = _reservation!;
    final totalDeposit = deposit;
    final confirmed = await ReservationRepository.instance.confirm(
      reservation.id,
      items: preOrder.items,
      payment: payment,
    );
    final withDeposit = confirmed.copyWith(
      depositAmount: confirmed.depositAmount != null && confirmed.depositAmount! > 0
          ? confirmed.depositAmount
          : (totalDeposit > 0 ? totalDeposit : null),
      depositPaidAt: totalDeposit > 0 ? (confirmed.depositPaidAt ?? DateTime.now()) : confirmed.depositPaidAt,
    );
    MockData.upsertReservation(withDeposit);
    preOrder.clear();
    _active = false;
    return withDeposit;
  }
}

/// Định dạng thời gian còn lại dạng mm:ss.
String formatRemaining(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Dùng chung cho màn "Đặt món trước" và "Thanh toán": cập nhật đồng hồ mỗi
/// giây và xử lý khi hết hạn giữ bàn (huỷ lượt đặt, báo khách, quay về).
mixin BookingHoldTimer<T extends StatefulWidget> on State<T> {
  Timer? _ticker;
  bool _handlingExpiry = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    final checkout = BookingCheckout.instance;
    // Chỉ màn đang ở trên cùng xử lý hết hạn, tránh hai màn cùng hiện thông báo.
    if (checkout.isExpired && (ModalRoute.of(context)?.isCurrent ?? false)) {
      _handleExpired();
      return;
    }
    setState(() {});
  }

  Future<void> _handleExpired() async {
    if (_handlingExpiry) return;
    _handlingExpiry = true;
    _ticker?.cancel();
    final navigator = Navigator.of(context);
    final confirmed = await BookingCheckout.instance.releaseSafely();
    if (!mounted) return;
    if (confirmed != null) {
      // Đã nhận cọc ngay trước khi hết giờ → lượt đặt vẫn còn, mở màn thành công.
      BookingConfirmationScreen.open(navigator, confirmed);
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Hết thời gian giữ bàn'),
        content: Text(
          'Bạn chưa hoàn tất đặt bàn trong ${BookingCheckout.holdDuration.inMinutes} phút nên lượt '
          'giữ bàn đã được huỷ để nhường bàn cho khách khác. Vui lòng đặt lại.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Đặt lại')),
        ],
      ),
    );
    navigator.popUntil((route) => route.settings.name == AppRoutes.customerHome || route.isFirst);
  }
}

/// Thanh 3 bước của luồng đặt bàn qua app.
/// Mỗi bước chiếm 1/3 chiều ngang: chấm tròn ở trên, nhãn ở dưới, nối với nhau
/// bằng đường kẻ - co giãn được trên mọi bề ngang màn hình.
class CheckoutSteps extends StatelessWidget {
  /// Bước hiện tại, tính từ 0: 0 = Đặt bàn, 1 = Đặt món, 2 = Thanh toán.
  final int current;

  const CheckoutSteps({super.key, required this.current});

  static const _labels = ['Đặt bàn', 'Đặt món', 'Thanh toán'];

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _labels.length; i++)
          Expanded(
            child: _Step(
              index: i,
              label: _labels[i],
              done: i < current,
              active: i == current,
              // Đường nối bên trái tô vàng khi đã tới bước này; bên phải khi đã qua bước này.
              leftLine: i == 0 ? null : i <= current,
              rightLine: i == _labels.length - 1 ? null : i < current,
            ),
          ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final int index;
  final String label;
  final bool done;
  final bool active;

  /// null = không vẽ đường nối phía đó; true/false = đã tô màu hay chưa.
  final bool? leftLine;
  final bool? rightLine;

  const _Step({
    required this.index,
    required this.label,
    required this.done,
    required this.active,
    required this.leftLine,
    required this.rightLine,
  });

  Widget _line(bool? filled) => Expanded(
        child: filled == null
            ? const SizedBox()
            : Container(height: 2, color: filled ? AppColors.primary : AppColors.border),
      );

  @override
  Widget build(BuildContext context) {
    final Color fill = done ? AppColors.primary : (active ? AppColors.ink : AppColors.surfaceAlt);
    final Color fg =
        done ? AppColors.textOnPrimary : (active ? AppColors.textOnDark : AppColors.textSecondary);
    return Column(
      children: [
        Row(
          children: [
            _line(leftLine),
            AnimatedContainer(
              duration: AppMotion.normal,
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
              child: done
                  ? Icon(Icons.check_rounded, size: 16, color: fg)
                  : Text('${index + 1}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: fg)),
            ),
            _line(rightLine),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active || done ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Dải thông báo thời gian giữ bàn còn lại; chuyển sang màu cảnh báo khi còn dưới 2 phút.
class HoldCountdownBanner extends StatelessWidget {
  final Duration remaining;

  const HoldCountdownBanner({super.key, required this.remaining});

  @override
  Widget build(BuildContext context) {
    final urgent = remaining < const Duration(minutes: 2);
    final fg = urgent ? AppColors.error : AppColors.textPrimary;
    return AnimatedContainer(
      duration: AppMotion.normal,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: urgent ? AppColors.errorBg : AppColors.primaryLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.timer_outlined, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: 'Bàn được giữ trong ',
                children: [
                  TextSpan(
                    text: formatRemaining(remaining),
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  const TextSpan(text: '. Quá hạn lượt đặt bàn sẽ tự huỷ.'),
                ],
              ),
              style: TextStyle(fontSize: 13, color: fg, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

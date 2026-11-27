import 'package:flutter/foundation.dart';

import '../core/api/api_client.dart';
import '../models/shift.dart';

/// Quản lý ca làm việc (thu ngân).
class ShiftRepository {
  ShiftRepository({ApiClient? api}) : _api = api ?? ApiClient.instance;

  static ShiftRepository instance = ShiftRepository();

  final ApiClient _api;

  /// Ca đang mở của thu ngân đang đăng nhập (null = chưa mở ca / chưa tải).
  ///
  /// Trước đây Tổng quan, Ca làm và Thanh toán mỗi màn tự tải một lần lúc mở nên lệch nhau:
  /// mở ca xong Tổng quan vẫn ghi "Chưa mở", thu tiền xong tab Ca làm vẫn 0đ. Giờ mọi thao tác
  /// (tải, mở, đóng ca) đều cập nhật giá trị này và các màn cùng nghe nó.
  final ValueNotifier<Shift?> current = ValueNotifier<Shift?>(null);

  /// Đã tải ca hiện tại ít nhất một lần (để phân biệt "chưa mở ca" với "chưa biết").
  bool loaded = false;

  /// Lấy ca đang mở của thu ngân hiện tại.
  /// Trả về null nếu chưa mở ca.
  Future<Shift?> fetchCurrent() async {
    final res = await _api.get('/shifts/current');
    // Server trả data: null khi chưa có ca đang mở
    final shift = res.data == null ? null : Shift.fromApiJson(res.map);
    loaded = true;
    current.value = shift;
    return shift;
  }

  /// Admin: các ca mở trong ngày [date], mới nhất trước (báo cáo ca).
  Future<List<Shift>> fetchByDate(DateTime date) async {
    final day = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final res = await _api.get('/shifts', query: {'date': day});
    return [for (final s in res.list) Shift.fromApiJson(s)];
  }

  /// Mở ca mới với số tiền đầu ca.
  Future<Shift> openShift({required double openingCash}) async {
    final res = await _api.post('/shifts', body: {
      'opening_cash': openingCash,
    });
    final shift = Shift.fromApiJson(res.map);
    loaded = true;
    current.value = shift;
    return shift;
  }

  /// Đóng ca: nhập tiền mặt đếm được.
  Future<Shift> closeShift({
    required String shiftId,
    required double closingCashCounted,
  }) async {
    final id = int.tryParse(shiftId);
    if (id == null) throw Exception('ID ca không hợp lệ');
    final res = await _api.patch('/shifts/$id/close', body: {
      'closing_cash_counted': closingCashCounted,
    });
    current.value = null;
    return Shift.fromApiJson(res.map);
  }
}

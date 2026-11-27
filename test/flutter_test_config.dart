import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineflow/core/api/api_client.dart';
import 'package:dineflow/core/session/session_store.dart';
import 'package:dineflow/data/auth_repository.dart';
import 'package:dineflow/data/menu_repository.dart';
import 'package:dineflow/data/mock_data.dart';
import 'package:dineflow/models/food.dart';
import 'package:dineflow/data/invoice_repository.dart';
import 'package:dineflow/data/order_repository.dart';
import 'package:dineflow/models/invoice.dart';
import 'package:dineflow/models/promotion.dart';
import 'package:dineflow/data/table_repository.dart';
import 'package:dineflow/data/reservation_repository.dart';
import 'package:dineflow/data/report_repository.dart';
import 'package:dineflow/models/revenue.dart';
import 'package:dineflow/models/order_item.dart';
import 'package:dineflow/models/reservation.dart';
import 'package:dineflow/models/order.dart';
import 'package:dineflow/models/food_category.dart';
import 'package:dineflow/models/table_model.dart';

/// Flutter tự chạy file này trước mọi test: nạp thực đơn từ
/// `assets/data/foods.json` giống như `main()` làm khi mở app, và gắn một
/// backend GIẢ để test giao diện không gọi mạng thật.
///
/// Backend giả: mọi lần đăng nhập / đăng ký đều thành công với một Khách hàng.
/// (Test về lớp API thật nằm ở `api_auth_test.dart`, tự dựng client riêng.)
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  await MockData.loadFoods();

  AuthRepository.instance = AuthRepository(
    api: ApiClient(client: _fakeBackend(), session: SessionStore(), baseUrl: 'http://fake/api'),
    session: SessionStore(),
  );

  MenuRepository.instance = _OfflineMenu();
  TableRepository.instance = _OfflineTables();
  OrderRepository.instance = _OfflineOrders();
  InvoiceRepository.instance = _OfflineInvoices();
  ReservationRepository.instance = _OfflineReservations();
  ReportRepository.instance = _OfflineReport();

  await testMain();
}

/// Báo cáo giả: trả đúng báo cáo đang có (không gọi mạng).
class _OfflineReport extends ReportRepository {
  _OfflineReport()
      : super(api: ApiClient(client: _fakeBackend(), session: SessionStore(), baseUrl: 'http://fake/api'));

  @override
  Future<ReportOverview> fetchOverview() async => MockData.report;
}

/// Đặt bàn giả: chạy trong bộ nhớ, không gọi mạng. Mô phỏng đúng hành vi cơ bản của server:
/// giữ bàn tạo lượt đặt có hạn, xác nhận gỡ hạn và lưu món đặt trước, hủy đổi trạng thái.
class _OfflineReservations extends ReservationRepository {
  _OfflineReservations()
      : super(api: ApiClient(client: _fakeBackend(), session: SessionStore(), baseUrl: 'http://fake/api'));

  Reservation _current(String id) => MockData.reservations.firstWhere((r) => r.id == id);

  @override
  Future<List<Reservation>> fetchMine() async => MockData.reservations;

  @override
  Future<List<Reservation>> fetchForDate(DateTime date) async => MockData.reservations;

  @override
  Future<Reservation> hold({
    required List<TableModel> tables,
    required DateTime dateTime,
    required int guestCount,
    String? note,
  }) async {
    final sequence = MockData.reservations.length + 1;
    final tableDeposit = tables.fold(0.0, (sum, t) => sum + t.depositAmount);
    return Reservation(
      id: 'r${DateTime.now().microsecondsSinceEpoch}',
      code: 'DF${(1000 + sequence * 137) % 9000 + 1000}',
      customerId: MockData.currentCustomer.id,
      tableIds: tables.map((t) => t.id).toList(),
      tableNumbers: tables.map((t) => t.number).toList(),
      area: tables.first.area,
      capacity: tables.fold(0, (sum, t) => sum + t.capacity),
      dateTime: dateTime,
      guestCount: guestCount,
      note: note,
      depositAmount: tableDeposit > 0 ? tableDeposit : null,
      holdExpiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  Future<Reservation> confirm(String reservationId,
      {List<OrderItem> items = const [], PaymentMethod? payment}) async {
    final current = _current(reservationId);
    final foodDeposit = (items.fold(0.0, (sum, i) => sum + i.total) * 0.5 / 100).ceilToDouble() * 100;
    final totalDeposit = (current.depositAmount ?? 0.0) + foodDeposit;
    return current.copyWith(
      preOrderItems: items.isEmpty ? null : items,
      preOrderPayment: items.isEmpty ? null : payment,
      depositAmount: totalDeposit > 0 ? totalDeposit : current.depositAmount,
      depositPaidAt: totalDeposit > 0 ? DateTime.now() : null,
      clearHold: true,
    );
  }

  @override
  Future<Reservation> cancel(String reservationId) async =>
      _current(reservationId).copyWith(status: ReservationStatus.cancelled, clearHold: true);
}

/// Hóa đơn giả: không gọi mạng. `pay` dựng hóa đơn từ đơn mẫu giống cách server tính
/// (voucher rồi trừ điểm) để test giao diện thấy kết quả hợp lý.
class _OfflineInvoices extends InvoiceRepository {
  _OfflineInvoices()
      : super(api: ApiClient(client: _fakeBackend(), session: SessionStore(), baseUrl: 'http://fake/api'));

  @override
  Future<List<Invoice>> fetchAll() async => MockData.invoices;

  @override
  Future<List<Promotion>> fetchAvailablePromotions() async => MockData.availablePromotions;

  @override
  Future<Invoice> pay(
    String orderId, {
    required PaymentMethod method,
    String? promotionCode,
    String? memberCode,
    int pointsUsed = 0,
  }) async {
    final order = MockData.orderById(orderId);
    final promo = promotionCode == null
        ? null
        : MockData.availablePromotions.firstWhere((p) => p.code == promotionCode);
    final discount = (promo?.discountFor(order.subtotal) ?? 0) + pointsUsed;

    return Invoice(
      id: 'inv-test',
      orderId: order.id,
      tableNumber: order.tableNumber,
      items: order.items,
      subtotal: order.subtotal,
      discount: discount,
      total: order.subtotal - discount,
      paymentMethod: method,
      createdAt: DateTime.now(),
      cashierName: MockData.currentCashier.name,
    );
  }
}

/// Đơn hàng giả: trả đúng đơn mẫu đang có (không gọi mạng).
class _OfflineOrders extends OrderRepository {
  _OfflineOrders()
      : super(api: ApiClient(client: _fakeBackend(), session: SessionStore(), baseUrl: 'http://fake/api'));

  @override
  Future<List<Order>> fetchAll() async => MockData.orders;
}

/// Danh sách bàn giả: trả đúng bàn mẫu đang có (không gọi mạng).
class _OfflineTables extends TableRepository {
  _OfflineTables()
      : super(api: ApiClient(client: _fakeBackend(), session: SessionStore(), baseUrl: 'http://fake/api'));

  @override
  Future<List<TableModel>> fetch() async => MockData.tables;

  @override
  Future<List<TableModel>> fetchAvailability(DateTime dateTime) async =>
      [for (final t in MockData.tables) t.copyWith(available: t.status == TableStatus.empty)];
}

/// Thực đơn giả: trả đúng thực đơn mẫu đã nạp từ assets (không gọi mạng),
/// để test giao diện vẫn thấy đủ món sau khi "đăng nhập".
class _OfflineMenu extends MenuRepository {
  _OfflineMenu()
      : super(api: ApiClient(client: _fakeBackend(), session: SessionStore(), baseUrl: 'http://fake/api'));

  @override
  Future<({List<FoodCategory> categories, List<Food> foods})> fetch() async =>
      (categories: MockData.categories, foods: MockData.foods);
}

MockClient _fakeBackend() {
  const user = {
    'id': 4,
    'name': 'Phạm Thị Khách',
    'email': 'customer@dineflow.com',
    'phone': '0901000004',
    'role': 'customer',
    'status': 'active',
    'avatar_url': null,
  };

  return MockClient((request) async {
    final path = request.url.path;
    dynamic data;
    if (path.endsWith('/me')) {
      data = user;
    } else if (path.contains('/toggle-status')) {
      data = {
        'id': 2,
        'name': 'Trần Thị Order',
        'email': 'order@dineflow.vn',
        'phone': '0901000002',
        'role': 'order_staff',
        'status': 'locked',
      };
    } else if (path.endsWith('/tables') || path.endsWith('/tables/available')) {
      data = [
        for (final t in MockData.tables)
          {
            'id': t.id,
            'number': t.number,
            'area': t.area,
            'capacity': t.capacity,
            'status': t.status.name,
            'is_locked': t.isLocked,
            'is_active': t.isActive,
            'deposit_amount': t.depositAmount,
            'available': t.status == TableStatus.empty,
          }
      ];
    } else if (path.endsWith('/users')) {
      data = [
        for (final u in MockData.users)
          {
            'id': u.id,
            'name': u.name,
            'email': u.email,
            'phone': u.phone,
            'role': u.role.name,
            'status': u.status.name,
          }
      ];
    } else if (path.endsWith('/reservations') || path.endsWith('/reservations/my')) {
      data = [];
    } else if (path.endsWith('/foods')) {
      data = [];
    } else if (path.endsWith('/categories')) {
      data = [];
    } else if (path.endsWith('/promotions')) {
      data = [];
    } else if (path.endsWith('/invoices')) {
      data = [];
    } else if (path.endsWith('/orders')) {
      data = [];
    } else {
      data = {'token': 'test-token', 'token_type': 'Bearer', 'user': user};
    }
    final body = jsonEncode({
      'status': 'success',
      'message': 'OK',
      'data': data,
    });
    return http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json'});
  });
}

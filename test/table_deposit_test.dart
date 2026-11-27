import 'package:flutter_test/flutter_test.dart';
import 'package:dineflow/models/invoice.dart';
import 'package:dineflow/models/order.dart';
import 'package:dineflow/models/order_item.dart';
import 'package:dineflow/models/reservation.dart';
import 'package:dineflow/models/table_model.dart';
import 'package:dineflow/screens/customer/booking_checkout.dart';

void main() {
  group('1. TableModel depositAmount', () {
    test('Khởi tạo TableModel có depositAmount mặc định là 0.0', () {
      const table = TableModel(
        id: 'tb-1',
        number: 'Bàn 1',
        area: 'Tầng 1',
        capacity: 4,
      );
      expect(table.depositAmount, 0.0);
    });

    test('Đọc deposit_amount từ API JSON thành công', () {
      final json = {
        'id': 10,
        'number': 'Bàn VIP 1',
        'area': 'Tầng 2',
        'capacity': 6,
        'status': 'empty',
        'is_locked': false,
        'is_active': true,
        'deposit_amount': 200000,
      };

      final table = TableModel.fromApiJson(json);
      expect(table.depositAmount, 200000.0);
      expect(table.number, 'Bàn VIP 1');
      expect(table.capacity, 6);
    });

    test('copyWith giữ và cập nhật depositAmount chính xác', () {
      const table = TableModel(
        id: 'tb-2',
        number: 'Bàn 2',
        area: 'Tầng 1',
        capacity: 2,
        depositAmount: 50000,
      );

      final copy = table.copyWith(depositAmount: 80000);
      expect(copy.depositAmount, 80000.0);

      final unchanged = table.copyWith(capacity: 3);
      expect(unchanged.depositAmount, 50000.0);
    });

    test('fromAvailabilityJson giữ nguyên depositAmount của bàn', () {
      final json = {
        'id': 15,
        'number': 'Bàn 5',
        'area': 'Sân vườn',
        'capacity': 4,
        'status': 'empty',
        'is_locked': false,
        'is_active': true,
        'deposit_amount': 100000,
        'available': true,
      };

      final table = TableModel.fromAvailabilityJson(json);
      expect(table.depositAmount, 100000.0);
      expect(table.available, true);
    });
  });

  group('2. BookingCheckout - Tính tiền cọc theo từng bàn & món', () {
    test('Lượt đặt không đặt món trước nhưng có cọc bàn: bắt buộc cọc tiền bàn', () {
      final checkout = BookingCheckout.instance;
      checkout.preOrder.clear();

      final reservation = Reservation(
        id: 'res-test-1',
        code: 'DF1234',
        customerId: 'cust-1',
        tableIds: ['t1'],
        tableNumbers: ['Bàn 1'],
        area: 'Tầng 1',
        capacity: 4,
        dateTime: DateTime.now().add(const Duration(days: 1)),
        guestCount: 4,
        depositAmount: 100000,
      );

      checkout.start(reservation, tableDeposit: 100000);

      expect(checkout.tableDeposit, 100000.0);
      expect(checkout.foodDeposit, 0.0);
      expect(checkout.deposit, 100000.0);
    });

    test('Ghép nhiều bàn: tổng cọc bàn là tổng tiền cọc của tất cả các bàn được chọn', () {
      final checkout = BookingCheckout.instance;
      checkout.preOrder.clear();

      const table1 = TableModel(id: 't1', number: 'Bàn 1', area: 'Tầng 1', capacity: 4, depositAmount: 100000);
      const table2 = TableModel(id: 't2', number: 'Bàn 2', area: 'Tầng 1', capacity: 2, depositAmount: 50000);
      final selectedTables = [table1, table2];

      final totalTableDeposit = selectedTables.fold(0.0, (sum, t) => sum + t.depositAmount);
      expect(totalTableDeposit, 150000.0);

      final reservation = Reservation(
        id: 'res-test-2',
        code: 'DF5678',
        customerId: 'cust-1',
        tableIds: ['t1', 't2'],
        tableNumbers: ['Bàn 1', 'Bàn 2'],
        area: 'Tầng 1',
        capacity: 6,
        dateTime: DateTime.now().add(const Duration(days: 1)),
        guestCount: 5,
        depositAmount: totalTableDeposit,
      );

      checkout.start(reservation, tableDeposit: totalTableDeposit);
      expect(checkout.deposit, 150000.0);
    });

    test('Có đặt món trước: tổng cọc = cọc bàn + 50% tiền món', () {
      final checkout = BookingCheckout.instance;
      checkout.preOrder.clear();

      final reservation = Reservation(
        id: 'res-test-3',
        code: 'DF9999',
        customerId: 'cust-1',
        tableIds: ['t1'],
        tableNumbers: ['Bàn 1'],
        area: 'Tầng 1',
        capacity: 4,
        dateTime: DateTime.now().add(const Duration(days: 1)),
        guestCount: 3,
        depositAmount: 100000,
      );

      checkout.start(reservation, tableDeposit: 100000);

      // Thêm 2 món 80.000đ = 160.000đ
      const item = OrderItem(id: 'oi-1', foodId: 'f-1', foodName: 'Lẩu hải sản', price: 80000, quantity: 2);
      checkout.preOrder.addItem(item);

      expect(checkout.preOrder.subtotal, 160000.0);
      expect(checkout.foodDeposit, 80000.0); // 50% của 160k
      expect(checkout.tableDeposit, 100000.0);
      // Tổng cọc = 100k (bàn) + 80k (món) = 180k
      expect(checkout.deposit, 180000.0);
    });
  });

  group('3. Khấu trừ cọc vào bill khi ăn xong (Order & Invoice)', () {
    test('Đơn hàng có cọc bàn: hasDeposit = true, trừ cọc vào tổng thanh toán', () {
      final order = Order(
        id: 'ord-100',
        tableNumber: 'Bàn 1',
        staffName: 'Order Staff',
        items: const [
          OrderItem(id: 'oi-1', foodId: 'f-1', foodName: 'Lẩu bò', price: 300000, quantity: 1),
          OrderItem(id: 'oi-2', foodId: 'f-2', foodName: 'Nước ngọt', price: 20000, quantity: 2),
        ],
        status: OrderStatus.serving,
        createdAt: DateTime.now(),
        depositAmount: 100000, // Tiền cọc đã trả khi đặt bàn
      );

      expect(order.subtotal, 340000.0);
      expect(order.hasDeposit, isTrue);
      expect(order.depositAmount, 100000.0);

      final finalPayment = (order.subtotal - order.depositAmount).clamp(0.0, double.infinity);
      expect(finalPayment, 240000.0);
    });

    test('Hóa đơn Invoice ghi nhận đúng khoản cọc đã khấu trừ', () {
      final invoice = Invoice(
        id: 'inv-100',
        code: 'HD00010',
        orderId: 'ord-100',
        tableNumber: 'Bàn 1',
        items: const [
          OrderItem(id: 'oi-1', foodId: 'f-1', foodName: 'Lẩu bò', price: 300000, quantity: 1),
        ],
        subtotal: 300000,
        discount: 30000, // 10% voucher
        depositAmount: 100000, // Tiền cọc bàn
        total: 170000, // 300k - 30k - 100k = 170k
        paymentMethod: PaymentMethod.cash,
        createdAt: DateTime.now(),
        cashierName: 'Thu Ngân',
      );

      expect(invoice.hasDeposit, isTrue);
      expect(invoice.depositAmount, 100000.0);
      expect(invoice.total, 170000.0);
    });
  });

  group('4. Chính sách huỷ cọc - mất cọc 100%, không hoàn trả', () {
    test('Huỷ lượt đặt chuyển trạng thái cancelled và bảo lưu số tiền cọc đã mất', () {
      final reservation = Reservation(
        id: 'res-cancel',
        code: 'DF8888',
        customerId: 'cust-1',
        tableIds: ['t1'],
        tableNumbers: ['Bàn 1'],
        area: 'Tầng 1',
        capacity: 4,
        dateTime: DateTime.now(),
        guestCount: 2,
        depositAmount: 100000,
        depositPaidAt: DateTime.now(),
        status: ReservationStatus.upcoming,
      );

      expect(reservation.isDepositPaid, isTrue);

      final cancelled = reservation.copyWith(status: ReservationStatus.cancelled);
      expect(cancelled.status, ReservationStatus.cancelled);
      // Tiền cọc vẫn được lưu để nhà hàng theo dõi và đối soát
      expect(cancelled.depositAmount, 100000.0);
      expect(cancelled.isDepositPaid, isTrue);
    });
  });
}

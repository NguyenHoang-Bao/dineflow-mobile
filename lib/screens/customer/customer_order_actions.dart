import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../data/cart_store.dart';
import '../../models/food.dart';
import '../../models/order_item.dart';

/// Thêm một phần món vào [store]; nếu đã có dòng cùng món (chưa có tuỳ chọn hay
/// ghi chú riêng) thì tăng số lượng dòng đó. Dòng đã có tuỳ chọn hoặc ghi chú
/// riêng (vd "ít đá") được coi là suất khác nên vẫn giữ tách ra.
///
/// Chỉ dùng cho món KHÔNG có size/topping; món có tùy chọn đi qua [addFoodOrPickOptions].
void addOneFood(CartStore store, Food food) {
  final existingIndex = store.items.indexWhere(
    (item) => item.foodId == food.id && item.note.isEmpty && item.selectedOptions.isEmpty,
  );

  if (existingIndex != -1) {
    final existing = store.items[existingIndex];
    store.updateQuantity(existing.id, existing.quantity + 1);
  } else {
    store.addItem(OrderItem(
      id: '${food.id}-${DateTime.now().millisecondsSinceEpoch}',
      foodId: food.id,
      foodName: food.name,
      price: food.price,
      quantity: 1,
    ));
  }
}

/// Nút "+" ở Trang chủ / Thực đơn / Đặt món trước.
///
/// Món có size/topping (vd Cà phê sữa đá, Trà sữa) thì mở màn chi tiết món để khách chọn —
/// trước đây "+" thêm thẳng món không size, server nhận như size nhỏ nhất và bếp không biết khách
/// muốn size nào. Màn chi tiết món thêm vào cùng giỏ [AppCart.customer] nên đặt món trước vẫn thấy.
/// Món không có tùy chọn thì thêm ngay như cũ.
void addFoodOrPickOptions(BuildContext context, CartStore store, Food food) {
  if (food.options.isNotEmpty) {
    Navigator.of(context).pushNamed(AppRoutes.customerFoodDetail, arguments: food.id);
    return;
  }
  addOneFood(store, food);
}

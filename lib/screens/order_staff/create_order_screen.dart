import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../data/app_data.dart';
import '../../data/cart_store.dart';
import '../../data/mock_data.dart';
import '../../data/order_repository.dart';
import '../../models/food.dart';
import '../../models/food_option.dart';
import '../../models/order.dart';
import '../../models/order_item.dart';
import '../../models/table_model.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header_band.dart';
import '../../widgets/app_search_bar.dart';
import '../../widgets/category_chip.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/live_data.dart';
import '../../widgets/order_items_card.dart';
import '../../widgets/quantity_stepper.dart';

/// Màn hình Order món tại bàn: chọn món, size/topping, số lượng, ghi chú, gửi order.
///
/// Theo mockup "Order món": số lượng chỉnh ngay trên từng dòng món (nút + khi
/// chưa chọn, bộ − số + khi đã chọn), tổng tiền và nút Gửi Order ở thanh dưới.
///
/// Món có size/topping (nhóm chốt 13/11, cùng quy tắc màn chi tiết món của khách): bấm + mở
/// bảng chọn, size mặc định là size đầu tiên, topping chọn thêm tùy ý. Mỗi tổ hợp tùy chọn
/// là một dòng riêng (vd Trà sữa M và Trà sữa L), mỗi dòng có số lượng và ghi chú riêng.
/// Giá cuối cùng do server tính từ option_ids.
class CreateOrderScreen extends StatefulWidget {
  final String? tableId;
  const CreateOrderScreen({super.key, this.tableId});

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

class _CreateOrderScreenState extends State<CreateOrderScreen> {
  final CartStore _draft = AppCart.staffOrder;
  String? _selectedCategoryId;
  String _keyword = '';
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _draft.clear();
    _draft.addListener(_onChanged);
  }

  @override
  void dispose() {
    _draft.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  TableModel? get _table {
    if (widget.tableId == null) return null;
    // Dùng where().firstOrNull thay firstWhere để tránh "Bad state: No element"
    // khi MockData.tables đang được refresh bởi LiveData ở màn trước.
    final matches = MockData.tables.where((t) => t.id == widget.tableId);
    return matches.isEmpty ? null : matches.first;
  }

  /// Món khớp danh mục + từ khóa. Tìm không cần dấu: "com suon" ra "Cơm sườn nướng".
  /// Gồm cả món tạm hết để nhân viên trả lời khách ngay; món tạm hết hiện mờ ở cuối, không chọn được.
  List<Food> get _matchingFoods {
    final key = AppFormatters.searchKey(_keyword);
    return MockData.foods.where((food) {
      final matchesCategory = _selectedCategoryId == null || food.categoryId == _selectedCategoryId;
      final matchesKeyword = key.isEmpty || AppFormatters.searchKey(food.name).contains(key);
      return matchesCategory && matchesKeyword;
    }).toList();
  }

  /// Lý do bàn này không nhận order mới, hoặc null nếu được. Sơ đồ bàn đã không mở màn này cho
  /// các bàn đó; kiểm tra lại ở đây vì dữ liệu bàn có thể đổi trong lúc đang chọn món
  /// (server hiện chưa chặn order vào bàn khóa / bàn đã vô hiệu hóa).
  String? _blockReason(TableModel? table) {
    if (table == null) return null;
    if (!table.isActive) return '${table.number} đã ngừng phục vụ, không nhận order.';
    if (table.status == TableStatus.serving) return null; // gọi thêm cho khách đang ngồi
    if (table.status == TableStatus.locked) {
      return '${table.number} đang được Admin khóa tạm. Hãy chọn bàn khác hoặc nhờ Admin mở khóa.';
    }
    if (table.status == TableStatus.reserved) {
      final r = table.nextReservation;
      return '${table.number} đang giữ cho khách đặt'
          '${r == null ? '' : ' lúc ${AppFormatters.time(r.dateTime)} (mã ${r.code})'}. '
          'Hãy chọn bàn khác; khách đặt tới thì nhận bàn ở Lịch đặt bàn.';
    }
    return null;
  }

  /// Dòng của món KHÔNG có tùy chọn trong order đang tạo. Mỗi món chỉ có một dòng: chạm lại
  /// vào món đã có thì tăng số lượng của chính dòng đó, không đẻ dòng trùng.
  OrderItem? _lineOf(Food food) {
    for (final item in _draft.items) {
      if (item.foodId == food.id) return item;
    }
    return null;
  }

  /// Mọi dòng của một món (món có size/topping có thể có nhiều dòng, mỗi tổ hợp một dòng).
  List<OrderItem> _linesOf(Food food) => _draft.items.where((i) => i.foodId == food.id).toList();

  /// Bấm + / chạm vào món: món có tùy chọn thì mở bảng chọn, không có thì thêm 1 phần.
  void _addFood(Food food) {
    if (food.options.isNotEmpty) {
      _pickOptions(food);
      return;
    }
    final existing = _lineOf(food);
    if (existing != null) {
      _draft.updateQuantity(existing.id, existing.quantity + 1);
      return;
    }
    _addLine(food, const []);
  }

  Future<void> _pickOptions(Food food) async {
    final options = await showModalBottomSheet<List<FoodOption>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _OptionSheet(food: food),
    );
    if (options == null || !mounted) return;

    // Cùng tổ hợp tùy chọn và chưa có ghi chú → cộng vào dòng sẵn có thay vì tạo dòng trùng.
    String key(Iterable<FoodOption> list) => (list.map((o) => o.id).toList()..sort()).join(',');
    final wanted = key(options);
    for (final line in _linesOf(food)) {
      if (key(line.selectedOptions) == wanted && line.note.isEmpty) {
        _draft.updateQuantity(line.id, line.quantity + 1);
        return;
      }
    }
    _addLine(food, options);
  }

  void _addLine(Food food, List<FoodOption> options) {
    _draft.addItem(OrderItem(
      id: '${food.id}-${DateTime.now().microsecondsSinceEpoch}',
      foodId: food.id,
      foodName: food.name,
      price: food.price,
      quantity: 1,
      selectedOptions: options,
    ));
  }

  /// Đặt số lượng từ bộ − số +; giảm về 0 thì món rời khỏi order.
  void _setQuantity(Food food, int quantity) {
    final line = _lineOf(food);
    if (line == null) {
      if (quantity > 0) _addFood(food);
      return;
    }
    _draft.updateQuantity(line.id, quantity);
  }

  Future<void> _editNote(OrderItem item) async {
    // Lấy navigator context trước khi await để không dùng context sau khoảng chờ.
    // useRootNavigator: true tránh lỗi "_dependents.isEmpty" khi parent widget
    // bị dispose trong lúc dialog đang mở (vd do LiveData refresh).
    final nav = Navigator.of(context, rootNavigator: true);
    final result = await showDialog<String>(
      context: nav.context,
      useRootNavigator: true,
      // _NoteDialog là StatefulWidget riêng: controller được tạo trong initState()
      // và huỷ trong dispose() — Flutter gọi dispose() SAU KHI animation đóng
      // dialog hoàn tất, tránh lỗi "TextEditingController used after being disposed".
      builder: (ctx) => _NoteDialog(
        foodName: item.foodName,
        initialNote: item.note,
      ),
    );
    // Kiểm tra mounted trước khi cập nhật state để tránh setState sau dispose.
    if (result != null && mounted) _draft.updateNote(item.id, result.trim());
  }

  /// Hỏi lại trước khi rời màn hình khi order đang có món, tránh mất công nhập.
  /// Nói rõ chỉ bỏ các món CHƯA GỬI (trước đây "Huỷ order" dễ hiểu nhầm là hủy đơn của bàn).
  Future<bool> _confirmDiscard() async {
    if (_draft.isEmpty) return true;
    return showConfirmDialog(
      context,
      title: 'Bỏ các món chưa gửi?',
      message: 'Có ${_draft.totalQuantity} món chưa gửi bếp. Rời màn hình sẽ mất các món này; '
          'các món đã gửi trước đó của bàn vẫn giữ nguyên.',
      confirmLabel: 'Bỏ món',
      cancelLabel: 'Tiếp tục order',
      destructive: true,
    );
  }

  /// Xem lại toàn bộ món sắp gửi (món nằm rải rác theo danh mục nên khó đọc lại cho khách).
  void _showReview() {
    if (_draft.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ReviewSheet(items: _draft.items, total: _draft.subtotal),
    );
  }

  /// Gửi order lên server. Thành công: tải lại bàn + đơn rồi đóng màn; lỗi: giữ nguyên các món đã chọn.
  Future<void> _submitOrder() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    // Lấy trước khi await để không dùng context sau khoảng chờ.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    void say(String text, {bool error = false}) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), backgroundColor: error ? AppColors.error : null));

    try {
      final result = await OrderRepository.instance.create(tableId: widget.tableId, items: _draft.items);
      // Đơn đã tạo ở server: đóng màn ngay, tải lại bàn + đơn chạy nền (các màn phía sau tự cập nhật).
      unawaited(AppData.refresh({LiveSource.tables, LiveSource.orders}, force: true));
      say(result.message);
      _draft.clear();
      navigator.pop();
    } on ApiException catch (e) {
      say(e.message, error: true);
      // Lỗi thường do trạng thái bàn vừa đổi (vd khách đặt tới giờ) → tải lại để banner cập nhật.
      unawaited(AppData.refresh({LiveSource.tables, LiveSource.orders}, force: true));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Đơn hiện tại của bàn (có thể đã thanh toán / đã hoàn thành).
  Order? _currentOrder(TableModel? table) =>
      table?.currentOrderId == null ? null : MockData.findOrder(table!.currentOrderId!);

  /// Server chỉ cộng món vào đơn còn mở và chưa thanh toán; ngược lại tạo đơn mới. Trước đây
  /// màn này luôn ghi "thêm vào đơn #…" kể cả khi server sẽ tạo hóa đơn thứ hai.
  String? _subtitle(TableModel? table) {
    if (table == null) return null;
    final order = _currentOrder(table);
    final target = order == null
        ? 'đơn mới'
        : order.acceptsMoreItems
            ? 'thêm vào đơn #${order.displayCode}'
            : 'hóa đơn mới (đơn #${order.displayCode} ${order.isPaid ? 'đã thanh toán' : 'đã hoàn thành'})';
    return '${table.area} · ${table.capacity} khách · $target';
  }

  @override
  Widget build(BuildContext context) {
    // Dựng lại khi bàn / đơn đổi (vd khách đặt vừa tới giờ) để banner chặn luôn đúng.
    return LiveData(
      sources: const {LiveSource.tables, LiveSource.orders},
      builder: (context, _) => _buildScreen(context),
    );
  }

  Widget _buildScreen(BuildContext context) {
    final foods = _matchingFoods;
    final table = _table;
    final blockReason = _blockReason(table);
    final currentOrder = _currentOrder(table);

    return PopScope(
      canPop: _draft.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Lấy navigator trước khi chờ hộp thoại để không dùng context sau await.
        final navigator = Navigator.of(context);
        final shouldDiscard = await _confirmDiscard();
        if (!shouldDiscard) return;
        _draft.clear();
        navigator.pop();
      },
      child: Scaffold(
        backgroundColor: AppColors.surfaceAlt,
        body: Column(
          children: [
            AppHeaderBand(
              title: table != null ? 'Order · ${table.number}' : 'Tạo Order',
              subtitle: _subtitle(table),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: AppSearchBar(
                hint: 'Tìm món...',
                fillColor: AppColors.surface,
                onChanged: (v) => setState(() => _keyword = v),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: CategoryChip(
                      label: 'Tất cả',
                      selected: _selectedCategoryId == null,
                      onTap: () => setState(() => _selectedCategoryId = null),
                    ),
                  ),
                  for (final c in MockData.categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: CategoryChip(
                        label: c.name,
                        selected: _selectedCategoryId == c.id,
                        onTap: () => setState(() => _selectedCategoryId = c.id),
                      ),
                    ),
                ],
              ),
            ),
            if (blockReason != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: _Banner(text: blockReason),
              ),
            const SizedBox(height: 12),
            Expanded(child: _buildFoodList(foods, currentOrder)),
            _buildBottomBar(blocked: blockReason != null),
          ],
        ),
      ),
    );
  }

  Widget _buildFoodList(List<Food> foods, Order? currentOrder) {
    final available = foods.where((f) => f.isAvailable).toList();
    final soldOut = foods.where((f) => !f.isAvailable).toList();
    // Món bàn đã gọi trước đó (cùng đơn sẽ được cộng thêm) — để khỏi gọi trùng.
    final ordered = currentOrder != null && currentOrder.acceptsMoreItems ? currentOrder.items : const <OrderItem>[];

    if (foods.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Không tìm thấy món phù hợp',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ),
      );
    }

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      children: [
        if (ordered.isNotEmpty) ...[
          _OrderedSummary(items: ordered),
          const SizedBox(height: 12),
        ],
        if (available.isNotEmpty)
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                for (var i = 0; i < available.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: AppColors.border),
                  FadeSlideIn.staggered(
                    index: i,
                    offsetY: 8,
                    child: available[i].options.isEmpty
                        ? _FoodRow(
                            food: available[i],
                            line: _lineOf(available[i]),
                            onAdd: () => _addFood(available[i]),
                            onQuantityChanged: (q) => _setQuantity(available[i], q),
                            onEditNote: _editNote,
                          )
                        : _OptionFoodRow(
                            food: available[i],
                            lines: _linesOf(available[i]),
                            onAdd: () => _addFood(available[i]),
                            onQuantityChanged: (line, q) => _draft.updateQuantity(line.id, q),
                            onEditNote: _editNote,
                          ),
                  ),
                ],
              ],
            ),
          ),
        if (soldOut.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text('Tạm hết · ${soldOut.length} món',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textSecondary)),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                for (var i = 0; i < soldOut.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: AppColors.border),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(soldOut[i].name,
                              style: TextStyle(
                                  fontSize: 14.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                        ),
                        Text('Tạm hết',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBottomBar({required bool blocked}) {
    final empty = _draft.isEmpty;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Row(
            children: [
              Expanded(
                // Chạm vào phần tổng tiền để xem lại toàn bộ món sắp gửi.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: empty ? null : _showReview,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              empty ? 'Chưa chọn món' : '${_draft.totalQuantity} món · Xem lại',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: empty ? AppColors.textSecondary : AppColors.textPrimary,
                                fontWeight: empty ? FontWeight.w400 : FontWeight.w700,
                                decoration: empty ? null : TextDecoration.underline,
                              ),
                            ),
                          ),
                          if (!empty) Icon(Icons.expand_less_rounded, size: 18, color: AppColors.textPrimary),
                        ],
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: AnimatedValueText(
                          AppFormatters.currency(_draft.subtotal),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 22,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppButton(
                  label: 'Gửi Order',
                  icon: Icons.near_me_outlined,
                  dense: true,
                  isLoading: _submitting,
                  onPressed: empty || blocked ? null : _submitOrder,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dải cảnh báo đỏ nhạt: vì sao bàn này không nhận order.
class _Banner extends StatelessWidget {
  final String text;

  const _Banner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.errorBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block_rounded, size: 18, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 13, color: AppColors.textPrimary, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// "Bàn đã gọi": các món đã gửi của đơn đang mở, thu gọn mặc định.
class _OrderedSummary extends StatefulWidget {
  final List<OrderItem> items;

  const _OrderedSummary({required this.items});

  @override
  State<_OrderedSummary> createState() => _OrderedSummaryState();
}

class _OrderedSummaryState extends State<_OrderedSummary> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final qty = widget.items.fold<int>(0, (sum, i) => sum + i.quantity);
    final total = widget.items.fold<double>(0, (sum, i) => sum + i.total);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: [
                  Icon(Icons.receipt_long_outlined, size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Bàn đã gọi: $qty món · ${AppFormatters.currency(total)}',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  ),
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: AppColors.textSecondary),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final i in widget.items)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${i.quantity}× ${i.foodName}'
                        '${i.optionsLabel.isEmpty ? '' : ' (${i.optionsLabel})'}'
                        '${i.note.trim().isEmpty ? '' : ' — ${i.note.trim()}'}',
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.35),
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

/// Bảng xem lại các món sắp gửi: tên, size/topping, ghi chú, thành tiền.
class _ReviewSheet extends StatelessWidget {
  final List<OrderItem> items;
  final double total;

  const _ReviewSheet({required this.items, required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text('Món sắp gửi bếp',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.textPrimary)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                children: [OrderItemsCard(items: items, quantityColor: AppColors.primaryLight)],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Text('Tổng cộng', style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                  const Spacer(),
                  Text(AppFormatters.currency(total),
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog nhập ghi chú cho món (vd "ít cay", "không hành").
/// Dùng StatefulWidget để TextEditingController được tạo trong initState()
/// và huỷ trong dispose() đúng vòng đời — tránh lỗi "used after being disposed".
class _NoteDialog extends StatefulWidget {
  final String foodName;
  final String initialNote;

  const _NoteDialog({required this.foodName, required this.initialNote});

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialNote);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Ghi chú hay dùng: chạm để thêm nhanh thay vì gõ (đang bận phục vụ, gõ có dấu chậm).
  static const _quickNotes = ['Ít đá', 'Không đá', 'Ít ngọt', 'Ít cay', 'Không hành', 'Mang về'];

  void _appendQuick(String note) {
    final current = _ctrl.text.trim();
    if (current.toLowerCase().contains(note.toLowerCase())) return;
    final next = current.isEmpty ? note : '$current, ${note.toLowerCase()}';
    if (next.length > 100) return;
    _ctrl.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Ghi chú: ${widget.foodName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLength: 100,
            maxLines: 3,
            minLines: 2,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: 'Vd: ít cay, không hành...',
              counterText: '',
            ),
            onSubmitted: (_) => Navigator.pop(context, _ctrl.text),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final note in _quickNotes)
                ActionChip(
                  label: Text(note, style: TextStyle(fontSize: 12.5, color: AppColors.textPrimary)),
                  backgroundColor: AppColors.primaryLight,
                  side: BorderSide(color: AppColors.border),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _appendQuick(note),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, widget.initialNote),
          child: const Text('Hủy'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}

/// Một dòng món: tên, giá (và ghi chú khi đã chọn) bên trái; nút + hoặc bộ
/// − số + bên phải. Chạm vào dòng cũng thêm 1 phần cho nhanh.
class _FoodRow extends StatelessWidget {
  final Food food;
  final OrderItem? line;
  final VoidCallback onAdd;
  final ValueChanged<int> onQuantityChanged;
  final ValueChanged<OrderItem> onEditNote;

  const _FoodRow({
    required this.food,
    required this.line,
    required this.onAdd,
    required this.onQuantityChanged,
    required this.onEditNote,
  });

  @override
  Widget build(BuildContext context) {
    final line = this.line;
    final quantity = line?.quantity ?? 0;

    return PressScale(
      onTap: onAdd,
      scale: 0.98,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(food.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(AppFormatters.currency(food.price),
                      style: TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                  // Ghi chú cho bếp (vd "ít cay") chỉ hiện với món đã chọn.
                  if (line != null) _NoteLink(note: line.note, onTap: () => onEditNote(line)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            AnimatedSwitcher(
              duration: AppMotion.fast,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: quantity == 0
                  ? PressScale(
                      key: const ValueKey('add'),
                      onTap: onAdd,
                      scale: 0.85,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.add_rounded, size: 22, color: AppColors.textPrimary),
                      ),
                    )
                  : QuantityStepper(
                      key: const ValueKey('stepper'),
                      value: quantity,
                      min: 0,
                      size: QuantityStepperSize.large,
                      onChanged: onQuantityChanged,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteLink extends StatelessWidget {
  final String note;
  final VoidCallback onTap;

  const _NoteLink({required this.note, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasNote = note.isNotEmpty;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_note_rounded,
                size: 17, color: hasNote ? AppColors.accent : AppColors.textSecondary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                hasNote ? note : 'Thêm ghi chú',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: hasNote ? FontWeight.w700 : FontWeight.w500,
                  color: hasNote ? AppColors.accent : AppColors.textSecondary,
                  decoration: hasNote ? null : TextDecoration.underline,
                  decorationColor: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dòng món CÓ size/topping: tên + giá gốc và nút + (mở bảng chọn); bên dưới là từng dòng đã chọn
/// (vd "Size L, Trân châu · 45.000đ") với bộ − số + và ghi chú riêng.
class _OptionFoodRow extends StatelessWidget {
  final Food food;
  final List<OrderItem> lines;
  final VoidCallback onAdd;
  final void Function(OrderItem line, int quantity) onQuantityChanged;
  final ValueChanged<OrderItem> onEditNote;

  const _OptionFoodRow({
    required this.food,
    required this.lines,
    required this.onAdd,
    required this.onQuantityChanged,
    required this.onEditNote,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PressScale(
            onTap: onAdd,
            scale: 0.98,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(food.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.textPrimary)),
                      const SizedBox(height: 2),
                      Text(
                        '${AppFormatters.currency(food.price)} · ${[
                          if (food.sizes.isNotEmpty) 'chọn size',
                          if (food.toppings.isNotEmpty) 'topping',
                        ].join(', ')}',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(12)),
                  child: Icon(Icons.add_rounded, size: 22, color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
          for (final line in lines)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
              decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(14)),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          line.optionsLabel.isEmpty ? 'Không tùy chọn' : line.optionsLabel,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                        ),
                        Text(AppFormatters.currency(line.unitPrice),
                            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                        _NoteLink(note: line.note, onTap: () => onEditNote(line)),
                      ],
                    ),
                  ),
                  QuantityStepper(
                    value: line.quantity,
                    min: 0,
                    onChanged: (q) => onQuantityChanged(line, q),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Bảng chọn size/topping cho một món. Cùng quy tắc với màn chi tiết món của khách:
/// size mặc định là size đầu tiên (chỉ chọn một), topping chọn thêm tùy ý.
/// Trả về danh sách tùy chọn đã chọn; đóng bảng thì trả về null.
class _OptionSheet extends StatefulWidget {
  final Food food;

  const _OptionSheet({required this.food});

  @override
  State<_OptionSheet> createState() => _OptionSheetState();
}

class _OptionSheetState extends State<_OptionSheet> {
  late FoodOption? _size = widget.food.sizes.isNotEmpty ? widget.food.sizes.first : null;
  final Set<String> _toppingIds = {};

  List<FoodOption> get _selected => [
        if (_size != null) _size!,
        ...widget.food.toppings.where((t) => _toppingIds.contains(t.id)),
      ];

  double get _unitPrice => widget.food.price + _selected.fold(0.0, (sum, o) => sum + o.extraPrice);

  @override
  Widget build(BuildContext context) {
    final food = widget.food;
    final label = TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.textPrimary);

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(food.name,
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.textPrimary)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                children: [
                  if (food.sizes.isNotEmpty) ...[
                    Text('Chọn size', style: label),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final size in food.sizes)
                          CategoryChip(
                            label: size.extraPrice > 0
                                ? '${size.name} (+${AppFormatters.currency(size.extraPrice)})'
                                : size.name,
                            selected: _size?.id == size.id,
                            onTap: () => setState(() => _size = size),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (food.toppings.isNotEmpty) ...[
                    Text('Chọn topping', style: label),
                    const SizedBox(height: 4),
                    for (final topping in food.toppings)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _toppingIds.contains(topping.id),
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppColors.primary,
                        checkColor: AppColors.textOnPrimary,
                        title: Text(topping.name, style: const TextStyle(fontSize: 14)),
                        secondary: Text('+${AppFormatters.currency(topping.extraPrice)}',
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _toppingIds.add(topping.id);
                          } else {
                            _toppingIds.remove(topping.id);
                          }
                        }),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: AppButton(
                label: 'Thêm vào order · ${AppFormatters.currency(_unitPrice)}',
                onPressed: () => Navigator.of(context).pop(_selected),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../models/food.dart';
import '../../models/food_category.dart';
import '../../models/food_option.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_animations.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/food_image.dart';
import '../../widgets/status_badge.dart';

/// Quản lý thực đơn: danh sách món + danh mục.
/// Kết nối thật với AdminRepository (Laravel API).
///
/// Thuật ngữ thống nhất: món **Đang bán** / **Tạm ngưng** (cờ `is_available`). Tạm ngưng thì
/// món ẩn khỏi thực đơn của khách và NV Order nhưng vẫn giữ nguyên dữ liệu, bật lại được.
class MenuManagementScreen extends StatefulWidget {
  const MenuManagementScreen({super.key});

  @override
  State<MenuManagementScreen> createState() => _MenuManagementScreenState();
}

class _MenuManagementScreenState extends State<MenuManagementScreen> with SingleTickerProviderStateMixin {
  final _repo = AdminRepository.instance;

  late final TabController _tabs = TabController(length: 2, vsync: this);

  // ── State ──
  List<Food> _foods = [];
  List<FoodCategory> _categories = [];
  bool _loading = true;
  String? _error;

  /// Bộ lọc tab Món ăn: tìm theo tên + danh mục (null = tất cả).
  String _search = '';
  String? _categoryFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _repo.fetchFoods(),
        _repo.fetchCategories(),
      ]);
      if (!mounted) return;
      setState(() {
        _foods = results[0] as List<Food>;
        _categories = results[1] as List<FoodCategory>;
        // Danh mục đang lọc vừa bị xóa ở nơi khác → bỏ lọc.
        if (_categoryFilter != null && !_categories.any((c) => c.id == _categoryFilter)) _categoryFilter = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _loading = false; });
    }
  }

  // ── Đang bán / Tạm ngưng ────────────────────────────────────────────────

  Future<void> _toggleAvailable(Food food) async {
    try {
      final updated = await _repo.toggleFoodAvailable(food.id);
      setState(() {
        final i = _foods.indexWhere((f) => f.id == food.id);
        if (i >= 0) _foods[i] = updated;
      });
      _snack(updated.isAvailable ? '"${food.name}" đã mở bán lại' : '"${food.name}" tạm ngưng bán (ẩn khỏi thực đơn)');
    } on ApiException catch (e) {
      _snack(e.message, isError: true);
    }
  }

  // ── Xóa món ──────────────────────────────────────────────────────────────

  Future<void> _confirmDeleteFood(Food food) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Xóa món ăn',
      message: 'Xóa vĩnh viễn "${food.name}"?\n'
          'Hóa đơn cũ vẫn giữ tên món. Nếu chỉ tạm hết, hãy chọn "Tạm ngưng bán" thay vì xóa.',
      confirmLabel: 'Xóa',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.deleteFood(food.id);
      setState(() => _foods.removeWhere((f) => f.id == food.id));
      _snack('Đã xóa "${food.name}"');
    } on ApiException catch (e) {
      _snack(e.message, isError: true);
    }
  }

  // ── Form món ──────────────────────────────────────────────────────────────

  void _showFoodForm([Food? food]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FoodFormSheet(
        existing: food,
        categories: _categories,
        onSaved: (name, price, desc, categoryId, isAvailable) async {
          Navigator.of(ctx).pop();
          setState(() => _loading = true);
          try {
            if (food == null) {
              await _repo.createFood(
                name: name, price: price, description: desc,
                categoryId: int.tryParse(categoryId) ?? 0, isAvailable: isAvailable,
              );
              _snack('Đã thêm "$name"');
            } else {
              await _repo.updateFood(
                food.id,
                name: name, price: price, description: desc,
                categoryId: int.tryParse(categoryId), isAvailable: isAvailable,
              );
              _snack('Đã cập nhật "$name"');
            }
            _load();
          } on ApiException catch (e) {
            _snack(e.message, isError: true);
            setState(() => _loading = false);
          }
        },
      ),
    );
  }

  // ── Form danh mục ─────────────────────────────────────────────────────────

  void _showCategoryForm([FoodCategory? cat]) {
    final nameCtrl = TextEditingController(text: cat?.name ?? '');
    final formKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FormSheetWrapper(
        title: cat == null ? 'Thêm danh mục' : 'Sửa danh mục',
        formKey: formKey,
        children: [
          AppTextField(
            controller: nameCtrl,
            label: 'Tên danh mục',
            hint: 'VD: Đồ uống nóng',
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Vui lòng nhập tên danh mục' : null,
          ),
          const SizedBox(height: 20),
          AppButton(
            label: cat == null ? 'Thêm danh mục' : 'Lưu thay đổi',
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              Navigator.of(ctx).pop();
              setState(() => _loading = true);
              try {
                if (cat == null) {
                  await _repo.createCategory(name: nameCtrl.text.trim());
                  _snack('Đã thêm danh mục "${nameCtrl.text.trim()}"');
                } else {
                  await _repo.updateCategory(cat.id, name: nameCtrl.text.trim());
                  _snack('Đã cập nhật "${cat.name}"');
                }
                _load();
              } on ApiException catch (e) {
                _snack(e.message, isError: true);
                setState(() => _loading = false);
              }
            },
          ),
        ],
      ),
    );
  }

  // ── Xóa danh mục ─────────────────────────────────────────────────────────
  // Cùng quy tắc với server và trang web /admin: chỉ xóa được danh mục RỖNG.
  // Trước đây app xóa lần lượt từng món rồi mới xóa danh mục (lách quy tắc của server):
  // một lần bấm mất cả nhóm món, và nếu một món giữa chừng đang nằm trong đơn chưa thanh toán
  // thì các món trước nó đã bị xóa còn danh mục vẫn còn (xóa dở dang).

  Future<void> _confirmDeleteCategory(FoodCategory cat) async {
    final count = _foods.where((f) => f.categoryId == cat.id).length;

    if (count > 0) {
      final showFoods = await showConfirmDialog(
        context,
        title: 'Chưa xóa được danh mục',
        message: 'Danh mục "${cat.name}" còn $count món.\n'
            'Hãy chuyển các món sang danh mục khác (Sửa món → Danh mục) hoặc xóa từng món trước.',
        cancelLabel: 'Đóng',
        confirmLabel: 'Xem các món',
      );
      if (showFoods && mounted) {
        setState(() {
          _categoryFilter = cat.id;
          _search = '';
        });
        _tabs.animateTo(0);
      }
      return;
    }

    final ok = await showConfirmDialog(
      context,
      title: 'Xóa danh mục',
      message: 'Xóa "${cat.name}"?\nHành động này không thể hoàn tác.',
      confirmLabel: 'Xóa',
      destructive: true,
    );
    if (!ok) return;

    try {
      await _repo.deleteCategory(cat.id);
      setState(() => _categories.removeWhere((c) => c.id == cat.id));
      _snack('Đã xóa danh mục "${cat.name}"');
    } on ApiException catch (e) {
      // vd. vừa có người thêm món vào danh mục này trên web
      _snack(e.message, isError: true);
      _load();
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: isError ? AppColors.error : null));
  }

  /// Món sau khi lọc theo danh mục + tên (không phân biệt hoa/thường).
  List<Food> get _visibleFoods {
    final q = _search.trim().toLowerCase();
    return _foods
        .where((f) => _categoryFilter == null || f.categoryId == _categoryFilter)
        .where((f) => q.isEmpty || f.name.toLowerCase().contains(q))
        .toList();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final categoryNames = {for (final c in _categories) c.id: c.name};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quản lý thực đơn', style: TextStyle(fontWeight: FontWeight.w800)),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: _loading ? 'Món ăn' : 'Món ăn (${_foods.length})'),
            Tab(text: _loading ? 'Danh mục' : 'Danh mục (${_categories.length})'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Thêm mới',
            onPressed: () => _tabs.index == 0 ? _showFoodForm() : _showCategoryForm(),
          ),
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
                : TabBarView(controller: _tabs, children: [
                    Column(
                      children: [
                        _FoodFilters(
                          // key theo bộ lọc để ô tìm kiếm xóa chữ khi "Xem các món" đặt lại bộ lọc
                          key: ValueKey('filters-$_categoryFilter'),
                          categories: _categories,
                          foods: _foods,
                          selectedCategory: _categoryFilter,
                          initialSearch: _search,
                          onSearch: (v) => setState(() => _search = v),
                          onCategory: (id) => setState(() => _categoryFilter = id),
                        ),
                        Expanded(
                          child: _FoodTab(
                            foods: _visibleFoods,
                            categoryNames: categoryNames,
                            filtered: _search.trim().isNotEmpty || _categoryFilter != null,
                            onRefresh: _load,
                            onEdit: _showFoodForm,
                            onToggle: _toggleAvailable,
                            onDelete: _confirmDeleteFood,
                          ),
                        ),
                      ],
                    ),
                    _CategoryTab(
                      categories: _categories,
                      foods: _foods,
                      onRefresh: _load,
                      onEdit: _showCategoryForm,
                      onDelete: _confirmDeleteCategory,
                    ),
                  ]),
      ),
    );
  }
}

// ── Bộ lọc tab Món ăn ───────────────────────────────────────────────────────

class _FoodFilters extends StatelessWidget {
  final List<FoodCategory> categories;
  final List<Food> foods;
  final String? selectedCategory;
  final String initialSearch;
  final ValueChanged<String> onSearch;
  final ValueChanged<String?> onCategory;

  const _FoodFilters({
    super.key,
    required this.categories,
    required this.foods,
    required this.selectedCategory,
    required this.initialSearch,
    required this.onSearch,
    required this.onCategory,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        children: [
          TextFormField(
            initialValue: initialSearch,
            onChanged: onSearch,
            decoration: InputDecoration(
              hintText: 'Tìm món…',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text('Tất cả (${foods.length})'),
                  selected: selectedCategory == null,
                  onSelected: (_) => onCategory(null),
                ),
              ),
              for (final c in categories)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text('${c.name} (${foods.where((f) => f.categoryId == c.id).length})'),
                    selected: selectedCategory == c.id,
                    onSelected: (_) => onCategory(c.id),
                  ),
                ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ── Tab Món ăn ──────────────────────────────────────────────────────────────

class _FoodTab extends StatelessWidget {
  final List<Food> foods;
  final Map<String, String> categoryNames;
  final bool filtered;
  final Future<void> Function() onRefresh;
  final void Function(Food) onEdit;
  final void Function(Food) onToggle;
  final void Function(Food) onDelete;

  const _FoodTab({
    required this.foods,
    required this.categoryNames,
    required this.filtered,
    required this.onRefresh,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (foods.isEmpty) {
      return Center(
        child: Text(filtered ? 'Không có món nào khớp bộ lọc' : 'Chưa có món nào',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
        itemCount: foods.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) {
          final food = foods[i];
          return FadeSlideIn.staggered(
            index: i,
            child: _FoodRow(
              food: food,
              categoryName: categoryNames[food.categoryId] ?? 'Chưa có danh mục',
              onEdit: () => onEdit(food),
              onToggle: () => onToggle(food),
              onDelete: () => onDelete(food),
            ),
          );
        },
      ),
    );
  }
}

/// Một món trong danh sách: ảnh, tên, "giá · danh mục", tóm tắt size/topping trên một dòng,
/// công tắc bán / ngưng và menu Sửa / Xóa. Chạm vào thẻ để sửa.
///
/// Gọn hơn trước: bỏ nhãn "Đang bán" (công tắc đã cho biết), chỉ hiện nhãn "Tạm ngưng" khi món
/// ngưng bán; các size/topping gom thành một dòng chữ thay cho một hàng chip riêng.
class _FoodRow extends StatelessWidget {
  final Food food;
  final String categoryName;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _FoodRow({
    required this.food,
    required this.categoryName,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  /// "Size S/M/L · Topping: Trân châu, Pudding" — tên tùy chọn, không kèm giá.
  String get _optionsSummary {
    final sizes = food.options.where((o) => o.type == FoodOptionType.size).map((o) => o.name.replaceFirst('Size ', ''));
    final toppings = food.options.where((o) => o.type == FoodOptionType.topping).map((o) => o.name);
    return [
      if (sizes.isNotEmpty) 'Size ${sizes.join('/')}',
      if (toppings.isNotEmpty) 'Topping: ${toppings.join(', ')}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final on = food.isAvailable;
    final summary = _optionsSummary;
    return Material(
      color: on ? AppColors.surface : AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onEdit,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Opacity(
                opacity: on ? 1 : 0.45,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: food.image != null
                      ? FoodImage(food: food, borderRadius: 10, iconSize: 20)
                      : Container(
                          decoration: BoxDecoration(
                              color: food.color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                          child: Icon(food.icon, color: food.color, size: 20),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(food.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14.5,
                                  color: on ? AppColors.textPrimary : AppColors.textSecondary)),
                        ),
                        if (!on) ...[
                          const SizedBox(width: 6),
                          StatusBadge(label: 'Tạm ngưng', color: AppColors.warning, background: AppColors.warningBg),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${AppFormatters.currency(food.price)} · $categoryName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                    ),
                    if (summary.isNotEmpty)
                      Text(summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              // Công tắc bán / ngưng ngay trên thẻ (thao tác hay dùng nhất), Sửa / Xóa trong menu.
              Tooltip(
                message: on ? 'Tạm ngưng bán' : 'Mở bán lại',
                child: Transform.scale(
                  scale: 0.85,
                  child: Switch.adaptive(value: on, onChanged: (_) => onToggle()),
                ),
              ),
              SizedBox(
                width: 36,
                child: PopupMenuButton<String>(
                  tooltip: 'Thao tác',
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onSelected: (v) {
                    if (v == 'edit') onEdit();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Sửa món')),
                    PopupMenuItem(value: 'delete', child: Text('Xóa món', style: TextStyle(color: AppColors.error))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Tab Danh mục ────────────────────────────────────────────────────────────

class _CategoryTab extends StatelessWidget {
  final List<FoodCategory> categories;
  final List<Food> foods;
  final Future<void> Function() onRefresh;
  final void Function(FoodCategory) onEdit;
  final void Function(FoodCategory) onDelete;

  const _CategoryTab({
    required this.categories,
    required this.foods,
    required this.onRefresh,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return Center(child: Text('Chưa có danh mục nào', style: TextStyle(color: AppColors.textSecondary)));
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: _list(),
    );
  }

  Widget _list() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      itemCount: categories.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final cat = categories[i];
        final count = foods.where((f) => f.categoryId == cat.id).length;
        return FadeSlideIn.staggered(
          index: i,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(10)),
                child: Icon(cat.icon, color: AppColors.textPrimary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(cat.name, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: AppColors.textPrimary)),
                Text('$count món', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ])),
              IconButton(icon: const Icon(Icons.edit_outlined, size: 20), tooltip: 'Sửa', onPressed: () => onEdit(cat)),
              IconButton(
                icon: Icon(Icons.delete_outline, size: 20, color: AppColors.error),
                tooltip: 'Xóa',
                onPressed: () => onDelete(cat),
              ),
            ]),
          ),
        );
      },
    );
  }
}

// ── Food Form Sheet ──────────────────────────────────────────────────────────

class _FoodFormSheet extends StatefulWidget {
  final Food? existing;
  final List<FoodCategory> categories;
  final void Function(String name, double price, String desc, String categoryId, bool isAvailable) onSaved;

  const _FoodFormSheet({this.existing, required this.categories, required this.onSaved});

  @override
  State<_FoodFormSheet> createState() => _FoodFormSheetState();
}

class _FoodFormSheetState extends State<_FoodFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _nameCtrl = TextEditingController(text: widget.existing?.name);
  late final _priceCtrl = TextEditingController(text: widget.existing != null ? widget.existing!.price.toStringAsFixed(0) : '');
  late final _descCtrl = TextEditingController(text: widget.existing?.description);
  late String? _categoryId = widget.existing?.categoryId ?? (widget.categories.isNotEmpty ? widget.categories.first.id : null);
  late bool _isAvailable = widget.existing?.isAvailable ?? true;

  @override
  void dispose() {
    _nameCtrl.dispose(); _priceCtrl.dispose(); _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return _FormSheetWrapper(
      title: isNew ? 'Thêm món mới' : 'Sửa món',
      formKey: _formKey,
      children: [
        AppTextField(
          controller: _nameCtrl, label: 'Tên món', hint: 'VD: Cà phê sữa đá',
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Vui lòng nhập tên món' : null,
        ),
        const SizedBox(height: 14),
        AppTextField(
          controller: _priceCtrl, label: 'Giá (đồng)', hint: 'VD: 45000',
          keyboardType: TextInputType.number,
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Vui lòng nhập giá';
            if (double.tryParse(v.replaceAll('.', '').replaceAll(',', '')) == null) return 'Giá không hợp lệ';
            return null;
          },
        ),
        const SizedBox(height: 14),
        AppTextField(controller: _descCtrl, label: 'Mô tả (không bắt buộc)', hint: 'Mô tả ngắn về món', maxLines: 2),
        const SizedBox(height: 14),
        if (widget.categories.isNotEmpty) ...[
          Text('Danh mục', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _categoryId,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.border)),
            ),
            items: widget.categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
            onChanged: (v) => setState(() => _categoryId = v),
          ),
          const SizedBox(height: 14),
        ],
        Container(
          decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(12)),
          child: SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            title: const Text('Đang bán', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(_isAvailable ? 'Khách và NV Order thấy món trong thực đơn' : 'Tạm ngưng: ẩn khỏi thực đơn, bật lại được', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            value: _isAvailable, activeThumbColor: AppColors.success,
            onChanged: (v) => setState(() => _isAvailable = v),
          ),
        ),
        const SizedBox(height: 20),
        AppButton(
          label: isNew ? 'Thêm món' : 'Lưu thay đổi',
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            if (_categoryId == null) return;
            widget.onSaved(
              _nameCtrl.text.trim(),
              double.parse(_priceCtrl.text.replaceAll('.', '').replaceAll(',', '')),
              _descCtrl.text.trim(),
              _categoryId!,
              _isAvailable,
            );
          },
        ),
      ],
    );
  }
}

// ── Khung form chung ────────────────────────────────────────────────────────

class _FormSheetWrapper extends StatelessWidget {
  final String title;
  final GlobalKey<FormState> formKey;
  final List<Widget> children;

  const _FormSheetWrapper({required this.title, required this.formKey, required this.children});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)))),
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 20),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

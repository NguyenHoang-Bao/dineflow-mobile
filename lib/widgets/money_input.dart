import 'package:flutter/services.dart';

/// Định dạng ô nhập tiền theo kiểu Việt Nam khi đang gõ: "560000" → "560.000".
///
/// Ô tiền trước đây để sẵn "0" và không có dấu chấm, nên gõ 500000 thành "0500000" và rất dễ
/// gõ thừa / thiếu một số 0 khi mở hoặc đóng ca.
class MoneyInputFormatter extends TextInputFormatter {
  const MoneyInputFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final text = formatMoneyDigits(digits);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// "560000" → "560.000"; chuỗi rỗng giữ rỗng.
String formatMoneyDigits(String digits) {
  if (digits.isEmpty) return '';
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// Đọc số tiền từ ô đã định dạng ("560.000" → 560000). Ô trống → null.
double? parseMoney(String text) {
  final digits = text.replaceAll(RegExp(r'\D'), '');
  return digits.isEmpty ? null : double.parse(digits);
}

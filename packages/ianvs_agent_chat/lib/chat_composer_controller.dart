import 'package:flutter/material.dart';

/// Host-owned draft and focus. Dispose it only after its composer is unmounted.
/// Reuse one controller for a logical conversation; binding a different identity
/// resets its draft. Separate controllers can retain separate text drafts.
class ChatComposerController extends ChangeNotifier {
  ChatComposerController({String text = ''})
    : editingController = TextEditingController(text: text),
      _lastText = text {
    editingController.addListener(_changed);
  }

  final TextEditingController editingController;
  final FocusNode focusNode = FocusNode();
  String _lastText;
  int _revision = 0;
  int _clearGeneration = 0;
  Object? _identity;
  bool _bound = false;

  String get text => editingController.text;
  TextSelection get selection => editingController.selection;
  set selection(TextSelection value) => editingController.selection = value;
  int get revision => _revision;
  int get clearGeneration => _clearGeneration;

  void replaceText(String text, {TextSelection? selection}) {
    editingController.value = TextEditingValue(
      text: text,
      selection: selection ?? TextSelection.collapsed(offset: text.length),
    );
  }

  void insertText(String insertion) {
    final selected = selection;
    final start = selected.isValid ? selected.start : text.length;
    final end = selected.isValid ? selected.end : text.length;
    replaceText(
      text.replaceRange(start, end, insertion),
      selection: TextSelection.collapsed(offset: start + insertion.length),
    );
  }

  void requestFocus() => focusNode.requestFocus();

  /// Clears the text and the mounted composer's attachments/history cursor.
  void clear() {
    _clearGeneration++;
    editingController.clear();
    markDraftChanged();
  }

  void bindSession(Object identity) {
    if (_bound && _identity != identity) clear();
    _bound = true;
    _identity = identity;
  }

  void markDraftChanged() {
    _revision++;
    notifyListeners();
  }

  void _changed() {
    if (_lastText != text) {
      _lastText = text;
      _revision++;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    editingController.removeListener(_changed);
    editingController.dispose();
    focusNode.dispose();
    super.dispose();
  }
}

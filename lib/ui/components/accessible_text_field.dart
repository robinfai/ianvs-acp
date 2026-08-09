import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

typedef AccessibleTextFieldBuilder = Widget Function(FocusNode focusNode);

/// Gives a Flutter text field a stable native accessibility name on macOS.
///
/// Flutter's macOS text-input bridge currently replaces editable semantic
/// nodes with an AppKit text field without forwarding their semantic label or
/// description. On macOS this widget therefore exposes a transparent, public
/// platform-view proxy and keeps it synchronized with the real Flutter field.
/// Other platforms use the regular Flutter semantics tree.
class AccessibleTextField extends StatefulWidget {
  const AccessibleTextField({
    super.key,
    required this.label,
    required this.description,
    required this.controller,
    required this.onChanged,
    required this.builder,
    this.enabled = true,
    this.multiline = false,
  });

  final String label;
  final String description;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final AccessibleTextFieldBuilder builder;
  final bool enabled;
  final bool multiline;

  @override
  State<AccessibleTextField> createState() => _AccessibleTextFieldState();
}

class _AccessibleTextFieldState extends State<AccessibleTextField> {
  static const _viewType = 'com.ianvs.acp/accessible-text-field';
  static const _channelPrefix = 'com.ianvs.acp/accessible-text-field/';

  final FocusNode _focusNode = FocusNode();
  MethodChannel? _channel;
  int _proxyGeneration = 0;
  bool _nativeProxyReady = false;

  bool get _isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleNativeUpdate);
    _focusNode.addListener(_scheduleNativeUpdate);
    SemanticsBinding.instance.addSemanticsEnabledListener(
      _handleSemanticsEnabledChanged,
    );
    _handleSemanticsEnabledChanged();
  }

  @override
  void didUpdateWidget(covariant AccessibleTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_scheduleNativeUpdate);
      widget.controller.addListener(_scheduleNativeUpdate);
    }
    _scheduleNativeUpdate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleNativeUpdate);
    _focusNode.removeListener(_scheduleNativeUpdate);
    SemanticsBinding.instance.removeSemanticsEnabledListener(
      _handleSemanticsEnabledChanged,
    );
    _proxyGeneration += 1;
    _clearChannel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.builder(_focusNode);
    if (!_nativeProxyReady) {
      return MergeSemantics(
        child: Semantics.fromProperties(
          properties: SemanticsProperties(
            label: widget.label,
            hint: widget.description,
          ),
          child: field,
        ),
      );
    }

    final proxyGeneration = _proxyGeneration;
    return Stack(
      children: [
        ExcludeSemantics(child: field),
        Positioned.fill(
          child: AppKitView(
            viewType: _viewType,
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            creationParams: _nativeState,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: (viewId) =>
                _handlePlatformViewCreated(viewId, proxyGeneration),
          ),
        ),
      ],
    );
  }

  Map<String, Object> get _nativeState => <String, Object>{
    'label': widget.label,
    'description': widget.description,
    'value': widget.controller.text,
    'enabled': widget.enabled,
    'focused': _focusNode.hasFocus,
    'multiline': widget.multiline,
  };

  void _handlePlatformViewCreated(int viewId, int generation) {
    if (!mounted ||
        !_nativeProxyReady ||
        generation != _proxyGeneration ||
        !SemanticsBinding.instance.semanticsEnabled) {
      return;
    }
    _clearChannel();
    final channel = MethodChannel('$_channelPrefix$viewId');
    _channel = channel;
    channel.setMethodCallHandler(_handleNativeCall);
    _scheduleNativeUpdate();
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (!mounted) return null;
    switch (call.method) {
      case 'focus':
        if (widget.enabled) _focusNode.requestFocus();
      case 'setText':
        if (!widget.enabled) return null;
        final text = call.arguments as String?;
        if (text == null || text == widget.controller.text) return null;
        widget.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        widget.onChanged(text);
      default:
        throw MissingPluginException(
          'Unknown text-field proxy call ${call.method}',
        );
    }
    return null;
  }

  void _scheduleNativeUpdate() {
    final channel = _channel;
    if (!mounted || channel == null) return;
    unawaited(
      channel.invokeMethod<void>('update', _nativeState).catchError((_) {}),
    );
  }

  void _handleSemanticsEnabledChanged() {
    final generation = ++_proxyGeneration;
    final shouldEnable = _isMacOS && SemanticsBinding.instance.semanticsEnabled;
    if (!shouldEnable) {
      _clearChannel();
      if (_nativeProxyReady && mounted) {
        setState(() => _nativeProxyReady = false);
      }
      return;
    }

    // Let Flutter commit the ordinary semantics root before adding an AppKit
    // subview. The engine only attaches that root while the Flutter view has no
    // native accessibility children.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _proxyGeneration ||
          !SemanticsBinding.instance.semanticsEnabled) {
        return;
      }
      setState(() => _nativeProxyReady = true);
    });
  }

  void _clearChannel() {
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      channel.setMethodCallHandler(null);
    }
  }
}

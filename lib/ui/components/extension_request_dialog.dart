import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../state/chat_controller.dart';
import '../theme/app_design_tokens.dart';

class ExtensionRequestDialog extends StatefulWidget {
  const ExtensionRequestDialog({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ExtensionRequestDialog> createState() => _ExtensionRequestDialogState();
}

class _ExtensionRequestDialogState extends State<ExtensionRequestDialog> {
  late final TextEditingController _methodController;
  late final TextEditingController _paramsController;
  bool _sending = false;
  String? _error;
  Object? _result;

  @override
  void initState() {
    super.initState();
    _methodController = TextEditingController(
      text: _defaultExtensionMethod(widget.controller),
    );
    _paramsController = TextEditingController(text: '{}');
  }

  @override
  void dispose() {
    _methodController.dispose();
    _paramsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Extension Request'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _methodController,
                decoration: const InputDecoration(
                  labelText: 'Method',
                  prefixIcon: Icon(Icons.extension_rounded),
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _paramsController,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Params JSON',
                  alignLabelWithHint: true,
                  prefixIcon: Icon(Icons.data_object_rounded),
                ),
                style: const TextStyle(fontFamily: 'monospace'),
                autocorrect: false,
                enableSuggestions: false,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _MessageBox(
                  icon: Icons.error_outline_rounded,
                  title: 'Error',
                  value: _error!,
                  color: AppColors.danger,
                ),
              ],
              if (_result != null) ...[
                const SizedBox(height: 12),
                _MessageBox(
                  icon: Icons.check_circle_outline_rounded,
                  title: 'Result',
                  value: _prettyJson(_result),
                  color: AppColors.success,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _sending ? null : () => unawaited(_send()),
          icon: _sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_rounded),
          label: const Text('Send'),
        ),
      ],
    );
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
      _result = null;
    });

    try {
      final result = await widget.controller.sendExtensionRequest(
        method: _methodController.text,
        params: _parseParams(_paramsController.text),
      );
      if (!mounted) return;
      setState(() {
        _result = result;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({
    required this.icon,
    required this.title,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 7),
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          SelectableText(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

Map<String, Object?> _parseParams(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const <String, Object?>{};
  final decoded = jsonDecode(text);
  if (decoded is! Map) {
    throw const FormatException('Params JSON must be an object.');
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

String _prettyJson(Object? value) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(value);
}

String _defaultExtensionMethod(ChatController controller) {
  final meta = controller.capabilities?.extensionMeta ?? const {};
  if (meta.isEmpty) return '_';
  final firstKey = meta.keys.first.trim();
  if (firstKey.isEmpty) return '_';
  return '_$firstKey/';
}

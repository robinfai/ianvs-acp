import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/theme/app_design_tokens.dart';
import 'mermaid_render_options.dart';
import 'mermaid_view.dart';
import 'native_merman_renderer.dart';

class MermaidExamplePage extends StatefulWidget {
  const MermaidExamplePage({super.key});

  @override
  State<MermaidExamplePage> createState() => _MermaidExamplePageState();
}

class _MermaidExamplePageState extends State<MermaidExamplePage> {
  static const _sample = '''
flowchart TD
  A[Prompt] --> B{Needs tool?}
  B -- yes --> C[Call ACP tool]
  B -- no --> D[Answer]
  C --> E[Stream result]
  E --> D
''';

  late final TextEditingController _sourceController;
  late final NativeMermanRenderer _renderer;
  Timer? _debounce;
  String _source = _sample;

  @override
  void initState() {
    super.initState();
    _sourceController = TextEditingController(text: _sample);
    _renderer = NativeMermanRenderer();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sourceController.dispose();
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mermaid Preview')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 820;
          final editor = _SourceEditor(
            controller: _sourceController,
            onChanged: _queueSourceUpdate,
          );
          final preview = _PreviewPane(source: _source, renderer: _renderer);

          if (compact) {
            return Column(
              children: [
                SizedBox(height: 260, child: editor),
                const Divider(height: 1),
                Expanded(child: preview),
              ],
            );
          }

          return Row(
            children: [
              SizedBox(width: 360, child: editor),
              const VerticalDivider(width: 1),
              Expanded(child: preview),
            ],
          );
        },
      ),
    );
  }

  void _queueSourceUpdate(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _source = value;
      });
    });
  }
}

class _SourceEditor extends StatelessWidget {
  const _SourceEditor({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      expands: true,
      maxLines: null,
      minLines: null,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(
        fontFamily: AppTypography.monoFamily,
        fontFamilyFallback: AppTypography.monoFallback,
        fontSize: 13,
      ),
      decoration: const InputDecoration(
        labelText: 'Source',
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(16),
      ),
    );
  }
}

class _PreviewPane extends StatelessWidget {
  const _PreviewPane({required this.source, required this.renderer});

  final String source;
  final NativeMermanRenderer renderer;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: MermaidView(
          source: source,
          renderer: renderer,
          options: MermaidRenderOptions.flutterSvgDefault,
          semanticsLabel: 'Mermaid diagram preview',
        ),
      ),
    );
  }
}

import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:ianvs_design/ianvs_design.dart';
import 'llm.dart';

/// Optional ready-to-use host for a configurable OpenAI-compatible session.
/// Configuration stays in memory. Removing this widget disposes its session.
class LlmChatPanel extends StatefulWidget {
  const LlmChatPanel({
    super.key,
    this.initialEndpoint = '',
    this.initialModel = '',
    this.tools = const [],
  });
  final String initialEndpoint;
  final String initialModel;
  final List<ChatTool> tools;
  @override
  State<LlmChatPanel> createState() => _LlmChatPanelState();
}

class _LlmChatPanelState extends State<LlmChatPanel> {
  final _form = GlobalKey<FormState>();
  late final _endpoint = TextEditingController(text: widget.initialEndpoint);
  late final _model = TextEditingController(text: widget.initialModel);
  final _apiKey = TextEditingController();
  LlmChatSession? _session;
  bool _images = false;
  String? _error;
  @override
  void dispose() {
    _session?.dispose();
    _endpoint.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _connect() {
    if (!_form.currentState!.validate()) return;
    try {
      final next = LlmChatSession(
        client: OpenAiChatClient(
          endpoint: Uri.parse(_endpoint.text.trim()),
          model: _model.text.trim(),
          apiKey: _apiKey.text.trim(),
        ),
        supportsImages: _images,
        tools: widget.tools,
      );
      _apiKey.clear();
      setState(() {
        _session = next;
        _error = null;
      });
    } catch (_) {
      setState(() => _error = 'Check the endpoint and model settings.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session != null) {
      return Column(
        children: [
          ListenableBuilder(
            listenable: session,
            builder: (context, _) => ListTile(
              dense: true,
              title: Text(session.client.model),
              subtitle: Text(session.client.endpoint.host),
              trailing: TextButton(
                onPressed: session.state.isSending
                    ? null
                    : () {
                        setState(() => _session = null);
                        session.dispose();
                      },
                child: const Text('New connection'),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: AgentChatView(session: session)),
        ],
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Connect a model',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Use an OpenAI-compatible Chat Completions service.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                IanvsFieldRow(
                  label: 'Completion endpoint',
                  breakpoint: double.infinity,
                  child: TextFormField(
                    key: const Key('llm-endpoint'),
                    controller: _endpoint,
                    decoration: const InputDecoration(
                      hintText: 'https://provider.example/v1/chat/completions',
                    ),
                    validator: (value) {
                      final uri = Uri.tryParse(value?.trim() ?? '');
                      return uri != null &&
                              uri.hasAuthority &&
                              ['http', 'https'].contains(uri.scheme) &&
                              uri.userInfo.isEmpty &&
                              !uri.hasFragment
                          ? null
                          : 'Enter a full HTTP(S) completion endpoint.';
                    },
                  ),
                ),
                const SizedBox(height: 16),
                IanvsFieldRow(
                  label: 'Model',
                  breakpoint: double.infinity,
                  child: TextFormField(
                    key: const Key('llm-model'),
                    controller: _model,
                    decoration: const InputDecoration(),
                    validator: (value) => value?.trim().isNotEmpty == true
                        ? null
                        : 'Enter a model name.',
                  ),
                ),
                const SizedBox(height: 16),
                IanvsFieldRow(
                  label: 'API key',
                  breakpoint: double.infinity,
                  helper:
                      'Optional for local services. Kept only for this connection.',
                  child: TextFormField(
                    key: const Key('llm-api-key'),
                    controller: _apiKey,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(),
                  ),
                ),
                const SizedBox(height: 12),
                IanvsSettingsRow(
                  title: 'Model supports images',
                  value: _images,
                  onChanged: (value) => setState(() => _images = value),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 16),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    key: const Key('llm-connect'),
                    onPressed: _connect,
                    child: const Text('Start conversation'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:ianvs_agent_chat/llm_chat_panel.dart';
import 'package:ianvs_design/ianvs_design.dart';

/// Owns window chrome; the reusable chat panel only owns its content.
class IndependentLlmPage extends StatelessWidget {
  const IndependentLlmPage({super.key});

  @override
  Widget build(BuildContext context) {
    final macos = Theme.of(context).platform == TargetPlatform.macOS;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const Key('independent-llm-toolbar'),
              constraints: const BoxConstraints(minHeight: 52),
              padding: EdgeInsetsDirectional.fromSTEB(
                macos ? 88 : 12,
                8,
                16,
                8,
              ),
              decoration: BoxDecoration(
                color: context.ianvs.chrome,
                border: Border(
                  bottom: BorderSide(color: context.ianvs.separator),
                ),
              ),
              child: Row(
                children: [
                  IanvsIconButton(
                    key: const Key('independent-llm-back'),
                    tooltip: '返回会话',
                    icon: Icons.arrow_back_rounded,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Independent LLM chat',
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Expanded(child: LlmChatPanel()),
          ],
        ),
      ),
    );
  }
}

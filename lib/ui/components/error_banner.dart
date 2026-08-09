import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.detail,
    this.onOpen,
    this.onRetry,
    this.onCopy,
  });

  final String message;
  final String? detail;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final trimmedDetail = detail?.trim();
    final hasActions = onOpen != null || onRetry != null || onCopy != null;
    return Semantics(
      liveRegion: true,
      container: true,
      label: [
        'Error: $message',
        if (trimmedDetail?.isNotEmpty == true) trimmedDetail!,
      ].join('. '),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(11, 8, 9, 8),
          decoration: BoxDecoration(
            color: const Color(0xfffff7f7),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: const Color(0xffffcdd2)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final messageBlock = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.error_outline_rounded,
                      color: AppColors.danger,
                      size: 17,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message,
                          style: const TextStyle(
                            color: AppColors.danger,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0,
                          ),
                        ),
                        if (trimmedDetail?.isNotEmpty == true) ...[
                          const SizedBox(height: 2),
                          Text(
                            trimmedDetail!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
              final actions = Wrap(
                spacing: 2,
                runSpacing: 2,
                alignment: WrapAlignment.end,
                children: [
                  if (onOpen != null)
                    TextButton.icon(
                      key: const Key('error-banner-open'),
                      onPressed: onOpen,
                      icon: const Icon(Icons.open_in_new_rounded, size: 15),
                      label: const Text('Open config'),
                    ),
                  if (onRetry != null)
                    TextButton.icon(
                      key: const Key('error-banner-retry'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry'),
                    ),
                  if (onCopy != null)
                    IconButton(
                      key: const Key('error-banner-copy'),
                      tooltip: 'Copy diagnostics',
                      onPressed: onCopy,
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      color: AppColors.textSecondary,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                    ),
                ],
              );

              if (compact && hasActions) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    messageBlock,
                    const SizedBox(height: 3),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: messageBlock),
                  if (hasActions) ...[const SizedBox(width: 8), actions],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

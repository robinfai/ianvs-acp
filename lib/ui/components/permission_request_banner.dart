import 'package:flutter/material.dart';

import '../../acp/acp_permission_request.dart';
import '../theme/app_design_tokens.dart';

class PermissionRequestBanner extends StatelessWidget {
  const PermissionRequestBanner({
    super.key,
    required this.request,
    required this.onAllow,
    required this.onDeny,
    required this.onCancel,
  });

  final AcpPermissionRequest request;
  final VoidCallback onAllow;
  final VoidCallback onDeny;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xfffffbeb),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: const Color(0xfffde68a)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.privacy_tip_outlined,
              color: AppColors.warning,
              size: 17,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    request.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${request.displayRationale} (${request.displayKind})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onDeny,
              icon: const Icon(Icons.block_rounded, size: 15),
              label: Text(request.denyActionLabel),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: onAllow,
              icon: const Icon(Icons.check_rounded, size: 15),
              label: Text(request.allowActionLabel),
            ),
            IconButton(
              tooltip: 'Cancel permission request',
              onPressed: onCancel,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

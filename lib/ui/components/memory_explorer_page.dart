import 'package:flutter/material.dart';

import '../theme/app_design_tokens.dart';

class MemoryExplorerPage extends StatelessWidget {
  const MemoryExplorerPage({super.key, this.onClearData});

  final VoidCallback? onClearData;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.bg,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          title: const Text(
            'Memory',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: OutlinedButton.icon(
                onPressed: onClearData,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Clear data'),
              ),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            labelColor: AppColors.primaryDark,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primaryDark,
            tabs: [
              Tab(text: 'All memory'),
              Tab(text: 'Candidates'),
              Tab(text: 'Change requests'),
              Tab(text: 'Audit log'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _MemoryExplorerPane(),
            _MemoryExplorerPane(),
            _MemoryExplorerPane(),
            _MemoryExplorerPane(),
          ],
        ),
      ),
    );
  }
}

class _MemoryExplorerPane extends StatelessWidget {
  const _MemoryExplorerPane();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          'No memory records yet.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

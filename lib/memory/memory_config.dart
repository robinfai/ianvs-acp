class MemoryConfig {
  const MemoryConfig({
    this.enabled = false,
    this.dataDir,
    this.embedding = const MemoryEmbeddingConfig(),
    this.extractor = const MemoryExtractorConfig(),
    this.llm = const MemoryLlmConfig(),
    this.review = const MemoryReviewConfig(),
    this.maintenance = const MemoryMaintenanceConfig(),
    this.profile = const MemoryProfileConfig(),
  });

  final bool enabled;
  final String? dataDir;
  final MemoryEmbeddingConfig embedding;
  final MemoryExtractorConfig extractor;
  final MemoryLlmConfig llm;
  final MemoryReviewConfig review;
  final MemoryMaintenanceConfig maintenance;
  final MemoryProfileConfig profile;

  factory MemoryConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryConfig();
    return MemoryConfig(
      enabled: raw['enabled'] as bool? ?? false,
      dataDir: raw['data_dir'] as String? ?? raw['dataDir'] as String?,
      embedding: MemoryEmbeddingConfig.fromJson(raw['embedding']),
      extractor: MemoryExtractorConfig.fromJson(raw['extractor']),
      llm: MemoryLlmConfig.fromJson(raw['llm']),
      review: MemoryReviewConfig.fromJson(raw['review']),
      maintenance: MemoryMaintenanceConfig.fromJson(raw['maintenance']),
      profile: MemoryProfileConfig.fromJson(raw['profile']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    if (dataDir != null) 'data_dir': dataDir,
    'embedding': embedding.toJson(),
    'extractor': extractor.toJson(),
    'llm': llm.toJson(),
    'review': review.toJson(),
    'maintenance': maintenance.toJson(),
    'profile': profile.toJson(),
  };
}

class MemoryProfileConfig {
  const MemoryProfileConfig({this.maxItems = 4});

  final int maxItems;

  factory MemoryProfileConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryProfileConfig();
    return MemoryProfileConfig(
      maxItems: _nonNegativeIntFromWire(raw['max_items'] ?? raw['maxItems'], 4),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{'max_items': maxItems};
}

class MemoryEmbeddingConfig {
  const MemoryEmbeddingConfig({
    this.provider = 'fastembed-local',
    this.model = 'intfloat/multilingual-e5-small',
    this.variant = 'onnx-qint8',
    this.dimension = 384,
    this.downloadPolicy = 'lazy',
  });

  final String provider;
  final String model;
  final String variant;
  final int dimension;
  final String downloadPolicy;

  factory MemoryEmbeddingConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryEmbeddingConfig();
    return MemoryEmbeddingConfig(
      provider: raw['provider'] as String? ?? 'fastembed-local',
      model: raw['model'] as String? ?? 'intfloat/multilingual-e5-small',
      variant: raw['variant'] as String? ?? 'onnx-qint8',
      dimension: raw['dimension'] as int? ?? 384,
      downloadPolicy:
          raw['download_policy'] as String? ??
          raw['downloadPolicy'] as String? ??
          'lazy',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'model': model,
    'variant': variant,
    'dimension': dimension,
    'download_policy': downloadPolicy,
  };
}

class MemoryExtractorConfig {
  const MemoryExtractorConfig({
    this.provider = 'acp-sidecar',
    this.agent = 'Codex',
    this.model = 'gpt-5-mini',
    this.fallbackProvider = 'rules',
    this.globalInstructions = '',
    this.workspaceInstructions = '',
    this.repoInstructions = '',
  });

  final String provider;
  final String agent;
  final String model;
  final String fallbackProvider;
  final String globalInstructions;
  final String workspaceInstructions;
  final String repoInstructions;

  factory MemoryExtractorConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryExtractorConfig();
    return MemoryExtractorConfig(
      provider: raw['provider'] as String? ?? 'acp-sidecar',
      agent: raw['agent'] as String? ?? 'Codex',
      model: raw['model'] as String? ?? 'gpt-5-mini',
      fallbackProvider:
          raw['fallback_provider'] as String? ??
          raw['fallbackProvider'] as String? ??
          'rules',
      globalInstructions:
          raw['global_instructions'] as String? ??
          raw['globalInstructions'] as String? ??
          '',
      workspaceInstructions:
          raw['workspace_instructions'] as String? ??
          raw['workspaceInstructions'] as String? ??
          '',
      repoInstructions:
          raw['repo_instructions'] as String? ??
          raw['repoInstructions'] as String? ??
          '',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'agent': agent,
    'model': model,
    'fallback_provider': fallbackProvider,
    if (globalInstructions.trim().isNotEmpty)
      'global_instructions': globalInstructions,
    if (workspaceInstructions.trim().isNotEmpty)
      'workspace_instructions': workspaceInstructions,
    if (repoInstructions.trim().isNotEmpty)
      'repo_instructions': repoInstructions,
  };
}

class MemoryLlmConfig {
  const MemoryLlmConfig({
    this.provider = 'openai-compatible',
    this.baseUrl = 'http://127.0.0.1:11434/v1',
    this.model = 'qwen2.5:7b',
    this.apiKeyEnv = 'OLLAMA_API_KEY',
  });

  final String provider;
  final String baseUrl;
  final String model;
  final String apiKeyEnv;

  factory MemoryLlmConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryLlmConfig();
    return MemoryLlmConfig(
      provider: raw['provider'] as String? ?? 'openai-compatible',
      baseUrl:
          raw['base_url'] as String? ??
          raw['baseUrl'] as String? ??
          'http://127.0.0.1:11434/v1',
      model: raw['model'] as String? ?? 'qwen2.5:7b',
      apiKeyEnv:
          raw['api_key_env'] as String? ??
          raw['apiKeyEnv'] as String? ??
          'OLLAMA_API_KEY',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'base_url': baseUrl,
    'model': model,
    'api_key_env': apiKeyEnv,
  };
}

class MemoryReviewConfig {
  const MemoryReviewConfig({
    this.approvalMode = MemoryApprovalMode.autoHighConfidence,
    this.autoOpen = 'high_confidence',
    this.highConfidenceThreshold = 0.85,
  });

  final String approvalMode;
  final String autoOpen;
  final double highConfidenceThreshold;

  factory MemoryReviewConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryReviewConfig();
    return MemoryReviewConfig(
      approvalMode: _approvalModeFromWire(
        raw['approval_mode'] ?? raw['approvalMode'],
      ),
      autoOpen: _autoOpenFromWire(raw['auto_open'] ?? raw['autoOpen']),
      highConfidenceThreshold:
          (raw['high_confidence_threshold'] as num? ??
                  raw['highConfidenceThreshold'] as num? ??
                  0.85)
              .toDouble(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'approval_mode': approvalMode,
    'auto_open': autoOpen,
    'high_confidence_threshold': highConfidenceThreshold,
  };
}

String _autoOpenFromWire(Object? value) {
  final mode = _modeFromWire(value);
  return MemoryReviewAutoOpen.isKnown(mode)
      ? mode
      : MemoryReviewAutoOpen.highConfidence;
}

String _approvalModeFromWire(Object? value) {
  final mode = _modeFromWire(value);
  return MemoryApprovalMode.isKnown(mode)
      ? mode
      : MemoryApprovalMode.autoHighConfidence;
}

class MemoryApprovalMode {
  const MemoryApprovalMode._();

  static const String manual = 'manual';
  static const String autoHighConfidence = 'auto_high_confidence';
  static const String autoApprove = 'auto_approve';

  static bool isKnown(String mode) {
    return mode == manual || mode == autoHighConfidence || mode == autoApprove;
  }
}

class MemoryReviewAutoOpen {
  const MemoryReviewAutoOpen._();

  static const String highConfidence = 'high_confidence';
  static const String never = 'never';

  static bool isKnown(String mode) {
    return mode == highConfidence || mode == never;
  }
}

class MemoryMaintenanceConfig {
  const MemoryMaintenanceConfig({
    this.enabled = true,
    this.mode = 'high_confidence_auto',
    this.costMode = 'low_cost',
    this.runAfterExtraction = true,
    this.idleEnabled = true,
    this.idleAfterTurns = 6,
    this.idleMaxPendingReviews = 0,
    this.highConfidenceThreshold = 0.90,
    this.reviewThreshold = 0.75,
    this.maxItemsPerBatch = 12,
    this.manualOnlyActions = const ['delete'],
  });

  final bool enabled;
  final String mode;
  final String costMode;
  final bool runAfterExtraction;
  final bool idleEnabled;
  final int idleAfterTurns;
  final int idleMaxPendingReviews;
  final double highConfidenceThreshold;
  final double reviewThreshold;
  final int maxItemsPerBatch;
  final List<String> manualOnlyActions;

  factory MemoryMaintenanceConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryMaintenanceConfig();
    final manualOnlyActions =
        raw['manual_only_actions'] ?? raw['manualOnlyActions'];
    return MemoryMaintenanceConfig(
      enabled: raw['enabled'] as bool? ?? true,
      mode: _maintenanceModeFromWire(raw['mode']),
      costMode:
          raw['cost_mode'] as String? ??
          raw['costMode'] as String? ??
          'low_cost',
      runAfterExtraction:
          raw['run_after_extraction'] as bool? ??
          raw['runAfterExtraction'] as bool? ??
          true,
      idleEnabled:
          raw['idle_enabled'] as bool? ?? raw['idleEnabled'] as bool? ?? true,
      idleAfterTurns: _positiveIntFromWire(
        raw['idle_after_turns'] ?? raw['idleAfterTurns'],
        6,
      ),
      idleMaxPendingReviews: _nonNegativeIntFromWire(
        raw['idle_max_pending_reviews'] ?? raw['idleMaxPendingReviews'],
        0,
      ),
      highConfidenceThreshold:
          (raw['high_confidence_threshold'] as num? ??
                  raw['highConfidenceThreshold'] as num? ??
                  0.90)
              .toDouble(),
      reviewThreshold:
          (raw['review_threshold'] as num? ??
                  raw['reviewThreshold'] as num? ??
                  0.75)
              .toDouble(),
      maxItemsPerBatch:
          raw['max_items_per_batch'] as int? ??
          raw['maxItemsPerBatch'] as int? ??
          12,
      manualOnlyActions: manualOnlyActions is List
          ? manualOnlyActions
                .whereType<String>()
                .map(_modeFromWire)
                .where((action) => action.isNotEmpty)
                .toList(growable: false)
          : const ['delete'],
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'mode': mode,
    'cost_mode': costMode,
    'run_after_extraction': runAfterExtraction,
    'idle_enabled': idleEnabled,
    'idle_after_turns': idleAfterTurns,
    'idle_max_pending_reviews': idleMaxPendingReviews,
    'high_confidence_threshold': highConfidenceThreshold,
    'review_threshold': reviewThreshold,
    'max_items_per_batch': maxItemsPerBatch,
    'manual_only_actions': manualOnlyActions,
  };
}

String _maintenanceModeFromWire(Object? value) {
  final mode = _modeFromWire(value);
  return switch (mode) {
    'manual_review' || 'high_confidence_auto' || 'disabled' || 'off' => mode,
    _ => 'high_confidence_auto',
  };
}

String _modeFromWire(Object? value) {
  if (value is! String) return '';
  return value.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
}

int _positiveIntFromWire(Object? value, int fallback) {
  if (value is int && value > 0) return value;
  if (value is num && value > 0) return value.round();
  return fallback;
}

int _nonNegativeIntFromWire(Object? value, int fallback) {
  if (value is int && value >= 0) return value;
  if (value is num && value >= 0) return value.round();
  return fallback;
}

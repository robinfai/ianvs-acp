class MemoryConfig {
  const MemoryConfig({
    this.enabled = true,
    this.autoStartDaemon = true,
    this.dataDir,
    this.embedding = const MemoryEmbeddingConfig(),
    this.extractor = const MemoryExtractorConfig(),
    this.llm = const MemoryLlmConfig(),
    this.review = const MemoryReviewConfig(),
  });

  final bool enabled;
  final bool autoStartDaemon;
  final String? dataDir;
  final MemoryEmbeddingConfig embedding;
  final MemoryExtractorConfig extractor;
  final MemoryLlmConfig llm;
  final MemoryReviewConfig review;

  factory MemoryConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryConfig();
    return MemoryConfig(
      enabled: raw['enabled'] as bool? ?? true,
      autoStartDaemon:
          raw['auto_start_daemon'] as bool? ??
          raw['autoStartDaemon'] as bool? ??
          true,
      dataDir: raw['data_dir'] as String? ?? raw['dataDir'] as String?,
      embedding: MemoryEmbeddingConfig.fromJson(raw['embedding']),
      extractor: MemoryExtractorConfig.fromJson(raw['extractor']),
      llm: MemoryLlmConfig.fromJson(raw['llm']),
      review: MemoryReviewConfig.fromJson(raw['review']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'auto_start_daemon': autoStartDaemon,
    if (dataDir != null) 'data_dir': dataDir,
    'embedding': embedding.toJson(),
    'extractor': extractor.toJson(),
    'llm': llm.toJson(),
    'review': review.toJson(),
  };
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
  });

  final String provider;
  final String agent;
  final String model;
  final String fallbackProvider;

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
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'agent': agent,
    'model': model,
    'fallback_provider': fallbackProvider,
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
    this.autoOpen = 'high_confidence',
    this.highConfidenceThreshold = 0.85,
  });

  final String autoOpen;
  final double highConfidenceThreshold;

  factory MemoryReviewConfig.fromJson(Object? raw) {
    if (raw is! Map) return const MemoryReviewConfig();
    return MemoryReviewConfig(
      autoOpen:
          raw['auto_open'] as String? ??
          raw['autoOpen'] as String? ??
          'high_confidence',
      highConfidenceThreshold:
          (raw['high_confidence_threshold'] as num? ??
                  raw['highConfidenceThreshold'] as num? ??
                  0.85)
              .toDouble(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'auto_open': autoOpen,
    'high_confidence_threshold': highConfidenceThreshold,
  };
}

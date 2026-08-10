import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../config/acp_client_config.dart';
import '../config/acp_config_store.dart';
import '../config/macos_keychain_secret_store.dart';
import '../config/secret_store.dart';
import '../ui/theme/app_theme.dart';
import 'startup_options.dart';

typedef AcpBootstrapConfigLoader =
    Future<AcpClientConfig> Function(
      String? configPath,
      SecretStore secretStore,
    );
typedef AcpBootstrapSecretStoreFactory =
    SecretStore Function(bool allowUserInteraction);

Future<AcpClientConfig> _loadConfig(
  String? configPath,
  SecretStore secretStore,
) =>
    AcpConfigStore.loadConfig(configPath: configPath, secretStore: secretStore);

SecretStore _createSecretStore(bool allowUserInteraction) =>
    allowUserInteraction
    ? const MacosKeychainSecretStore.withUserInteraction()
    : const MacosKeychainSecretStore();

final class AcpClientBootstrap extends StatefulWidget {
  const AcpClientBootstrap({
    super.key,
    required this.configPath,
    required this.startupOptions,
    this.loadConfig = _loadConfig,
    this.createSecretStore = _createSecretStore,
    this.configLoadTimeout = const Duration(seconds: 15),
  });

  final String? configPath;
  final StartupOptions startupOptions;
  final AcpBootstrapConfigLoader loadConfig;
  final AcpBootstrapSecretStoreFactory createSecretStore;
  final Duration configLoadTimeout;

  @override
  State<AcpClientBootstrap> createState() => _AcpClientBootstrapState();
}

final class _AcpClientBootstrapState extends State<AcpClientBootstrap> {
  AcpClientConfig? _config;
  SecretStore? _secretStore;
  Object? _error;
  bool _loading = true;
  bool _keychainApprovalRequired = false;
  bool _keychainAttemptTimedOut = false;
  bool _continueWithoutConfiguration = false;
  int _loadSerial = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_load(allowUserInteraction: false));
    });
  }

  Future<void> _load({required bool allowUserInteraction}) async {
    final serial = ++_loadSerial;
    setState(() {
      _loading = true;
      _error = null;
      _keychainApprovalRequired = false;
      _keychainAttemptTimedOut = false;
      _continueWithoutConfiguration = false;
    });
    final secretStore = widget.createSecretStore(allowUserInteraction);
    try {
      final config = await widget
          .loadConfig(widget.configPath, secretStore)
          .timeout(widget.configLoadTimeout);
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _config = config;
        _secretStore = secretStore;
        _loading = false;
      });
    } on SecretStoreInteractionRequiredException catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _error = error;
        _loading = false;
        _keychainApprovalRequired = true;
      });
    } on TimeoutException catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _error = error;
        _loading = false;
        _keychainApprovalRequired = true;
        _keychainAttemptTimedOut = allowUserInteraction;
      });
    } catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final secretStore = _secretStore;
    if (config != null && secretStore != null) {
      return _buildClient(config: config, secretStore: secretStore);
    }
    if (_continueWithoutConfiguration ||
        (!_loading && !_keychainApprovalRequired)) {
      return _buildClient(
        config: AcpClientConfig(configPath: widget.configPath),
        secretStore: const MacosKeychainSecretStore(),
        startupError: 'Could not load ACP config: $_error',
        configurationWritable: false,
      );
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ACP Client',
      theme: AppTheme.light,
      home: Scaffold(
        body: Center(
          child: _loading
              ? const SizedBox.square(
                  key: Key('acp-bootstrap-loading'),
                  dimension: 28,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : _KeychainApprovalPrompt(
                  approvalTimedOut: _keychainAttemptTimedOut,
                  onApprove: _keychainAttemptTimedOut
                      ? null
                      : () {
                          unawaited(_load(allowUserInteraction: true));
                        },
                  onContinue: () {
                    setState(() {
                      _continueWithoutConfiguration = true;
                    });
                  },
                ),
        ),
      ),
    );
  }

  Widget _buildClient({
    required AcpClientConfig config,
    required SecretStore secretStore,
    String? startupError,
    bool configurationWritable = true,
  }) {
    final options = widget.startupOptions;
    return AcpClientApp(
      config: config,
      secretStore: secretStore,
      startupError: startupError,
      onRetryStartup: startupError == null
          ? null
          : () => unawaited(_load(allowUserInteraction: false)),
      configurationWritable: configurationWritable,
      initialResumeSessionId: options.resumeSessionId,
      initialResumeCwd: options.resumeCwd,
      initialResumeAgentName: options.resumeAgentName,
    );
  }
}

final class _KeychainApprovalPrompt extends StatelessWidget {
  const _KeychainApprovalPrompt({
    required this.approvalTimedOut,
    required this.onApprove,
    required this.onContinue,
  });

  final bool approvalTimedOut;
  final VoidCallback? onApprove;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline_rounded, size: 30),
            const SizedBox(height: 18),
            Text(
              approvalTimedOut
                  ? 'Keychain access did not finish'
                  : 'Keychain access required',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Text(
              approvalTimedOut
                  ? 'macOS did not finish unlocking credentials saved by an '
                        'earlier build. Continue without them, then re-enter '
                        'the affected credentials in Settings.'
                  : 'ACP Client needs your approval to read credentials saved '
                        'by an earlier build. The system may ask you to confirm '
                        'access.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            if (onApprove case final approve?) ...[
              FilledButton(
                key: const Key('approve-keychain-access'),
                onPressed: approve,
                child: const Text('Allow Keychain Access'),
              ),
              const SizedBox(height: 8),
            ],
            approvalTimedOut
                ? FilledButton(
                    key: const Key('continue-without-keychain'),
                    onPressed: onContinue,
                    child: const Text('Continue without configuration'),
                  )
                : TextButton(
                    key: const Key('continue-without-keychain'),
                    onPressed: onContinue,
                    child: const Text('Continue without configuration'),
                  ),
          ],
        ),
      ),
    );
  }
}

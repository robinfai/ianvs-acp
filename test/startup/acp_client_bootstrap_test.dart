import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/secret_store.dart';
import 'package:ianvs_acp/startup/acp_client_bootstrap.dart';
import 'package:ianvs_acp/startup/startup_options.dart';

void main() {
  testWidgets(
    'renders before config load and requires an explicit interactive retry',
    (tester) async {
      final interactiveLoad = Completer<AcpClientConfig>();
      final interactionModes = <bool>[];
      var loadCount = 0;

      await tester.pumpWidget(
        AcpClientBootstrap(
          configPath: '/tmp/acp-bootstrap/settings.json',
          startupOptions: const StartupOptions(),
          createSecretStore: (allowUserInteraction) {
            interactionModes.add(allowUserInteraction);
            return const _BootstrapSecretStore();
          },
          configLoadTimeout: const Duration(milliseconds: 1),
          loadConfig: (configPath, secretStore) async {
            loadCount += 1;
            if (loadCount == 1) {
              throw const SecretStoreInteractionRequiredException();
            }
            return interactiveLoad.future;
          },
        ),
      );
      await tester.pump();

      expect(find.text('Keychain access required'), findsOneWidget);
      expect(interactionModes, <bool>[false]);

      await tester.tap(find.byKey(const Key('approve-keychain-access')));
      await tester.pump(const Duration(milliseconds: 2));

      expect(interactionModes, <bool>[false, true]);
      expect(find.text('Keychain access did not finish'), findsOneWidget);
      expect(find.byKey(const Key('approve-keychain-access')), findsNothing);
      expect(
        find.byKey(const Key('continue-without-keychain')),
        findsOneWidget,
      );
      expect(find.text('Keychain access required'), findsNothing);
    },
  );
}

final class _BootstrapSecretStore implements SecretStore {
  const _BootstrapSecretStore();

  @override
  Future<void> delete(String reference) async {}

  @override
  Future<String?> get(String reference) async => null;

  @override
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  }) async => referenceFor(namespace: namespace, key: key);

  @override
  String referenceFor({required String namespace, required String key}) =>
      keychainReferenceFor(namespace: namespace, key: key);

  @override
  bool referenceMatches(
    String reference, {
    required String namespace,
    required String key,
  }) => reference == referenceFor(namespace: namespace, key: key);
}

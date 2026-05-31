import 'package:stream_channel/stream_channel.dart';

/// Abstraction over the underlying transport (stdio, TCP, etc.).
abstract class AcpTransport {
  /// Bi-directional line/JSON channel used by the JSON-RPC peer.
  StreamChannel<String> get channel;

  /// Start the transport and connect streams.
  Future<void> start();

  /// Stop the transport and clean up resources.
  Future<void> stop();
}

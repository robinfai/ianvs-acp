const Set<String> _supportedAcpEndpointSchemes = <String>{
  'http',
  'https',
  'ws',
  'wss',
};

Uri parseAndValidateAcpEndpoint(
  String value, {
  Set<String> allowedSchemes = _supportedAcpEndpointSchemes,
}) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) {
    throw const FormatException('ACP endpoint must be a valid URL.');
  }
  validateAcpEndpoint(uri, allowedSchemes: allowedSchemes);
  return uri;
}

void validateAcpEndpoint(
  Uri uri, {
  Set<String> allowedSchemes = _supportedAcpEndpointSchemes,
}) {
  final scheme = uri.scheme.toLowerCase();
  if (!allowedSchemes.contains(scheme)) {
    throw const FormatException('ACP endpoint uses an unsupported scheme.');
  }
  if (uri.host.trim().isEmpty) {
    throw const FormatException('ACP endpoint requires a host.');
  }
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'ACP endpoint credentials must be provided through protected headers.',
    );
  }
  if ((scheme == 'http' || scheme == 'ws') && !_isLoopback(uri.host)) {
    throw const FormatException(
      'Remote ACP endpoints require TLS (https or wss).',
    );
  }
}

bool _isLoopback(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}

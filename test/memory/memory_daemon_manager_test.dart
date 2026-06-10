import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_daemon_manager.dart';

void main() {
  test('parses ready JSON line', () {
    final ready = MemoryDaemonReady.fromStdoutLine(
      '{"type":"ready","port":43129}',
    );
    expect(ready.port, 43129);
    expect(ready.baseUrl, 'http://127.0.0.1:43129');
  });

  test('builds daemon env with token but args omit token', () {
    const launch = MemoryDaemonLaunch(
      executable: '/tmp/memory-core',
      dataDir: '/tmp/data',
      token: 'secret-token',
    );
    expect(launch.env['MEMORY_DAEMON_TOKEN'], 'secret-token');
    expect(launch.args.join(' '), isNot(contains('secret-token')));
    expect(launch.args, contains('--port'));
    expect(launch.args, contains('0'));
  });
}

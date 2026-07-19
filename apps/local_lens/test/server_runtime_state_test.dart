import 'package:flutter_test/flutter_test.dart';
import 'package:local_lens/models/server_runtime_state.dart';

void main() {
  test('runtime state reports running status', () {
    const state = ServerRuntimeState(
      status: ServerRuntimeStatus.running,
      processId: 9527,
      restartCount: 1,
    );

    expect(state.isRunning, isTrue);
    expect(state.processId, 9527);
    expect(state.restartCount, 1);
  });

  test('copyWith can clear process and error', () {
    const state = ServerRuntimeState(
      status: ServerRuntimeStatus.failed,
      processId: 100,
      lastError: 'boom',
    );

    final stopped = state.copyWith(
      status: ServerRuntimeStatus.stopped,
      clearProcessId: true,
      clearError: true,
    );

    expect(stopped.status, ServerRuntimeStatus.stopped);
    expect(stopped.processId, isNull);
    expect(stopped.lastError, isNull);
  });
}

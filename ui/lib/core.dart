import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'diagnostics.dart';

/// Private JSON-lines channel. No HTTP control listener or shared auth token.
abstract class CpvApi {
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]);
  Future<void> close();
}

class CpvCore implements CpvApi {
  CpvCore(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final response = jsonDecode(line) as Map<String, dynamic>;
            final c = _pending.remove(response['id']);
            if (response.containsKey('error')) {
              c?.completeError(Exception(response['error']));
            } else {
              c?.complete(response['result']);
            }
          } catch (_) {
            /* Ignore malformed third-party output, never execute it. */
          }
        }, onDone: () => _fail('CPV core disconnected'));
    _process.stderr.transform(utf8.decoder).listen((text) {
      _error = text.trim();
      Diagnostics.record('core_stderr', {'message': text}, force: true);
    });
    _process.exitCode.then(
      (code) => _fail(_error.isEmpty ? 'CPV core exited ($code)' : _error),
    );
  }
  final Process _process;
  final Map<int, Completer<dynamic>> _pending = {};
  String _error = '';
  int _id = 0;
  bool _closed = false;
  bool _shuttingDown = false;
  Future<void>? _closing;
  static Future<CpvCore> start() async {
    final override = Platform.environment['CPV_CORE'];
    final folder = File(Platform.resolvedExecutable).parent.path;
    final executable =
        override ?? '$folder${Platform.pathSeparator}cpv-core.exe';
    return CpvCore(
      await Process.start(
        executable,
        const [],
        mode: ProcessStartMode.normal,
        environment: {
          if (Diagnostics.directory != null)
            'CPV_DIAGNOSTIC_DIR': Diagnostics.directory!.path,
          if (Diagnostics.enabled) 'CPV_DIAGNOSTICS': '1',
        },
      ),
    );
  }

  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_closed || (_shuttingDown && method != 'shutdown')) {
      throw StateError(_error.isEmpty ? 'CPV core disconnected' : _error);
    }
    final id = ++_id;
    final started = DateTime.now();
    final c = Completer<dynamic>();
    _pending[id] = c;
    try {
      _process.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'args': args}),
      );
      final result = await c.future.timeout(
        Duration(seconds: method == 'install_certificate' ? 600 : 60),
      );
      if (!['state', 'catalog'].contains(method)) {
        Diagnostics.record('rpc', {
          'method': method,
          'ok': true,
          'elapsed_ms': DateTime.now().difference(started).inMilliseconds,
        });
      }
      return result;
    } catch (e) {
      Diagnostics.record('rpc_error', {
        'method': method,
        'error': e.toString(),
      }, force: true);
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(String message) {
    if (_closed) return;
    _closed = true;
    _error = message;
    Diagnostics.record('core_disconnected', {
      'message': message,
    }, force: !_shuttingDown);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(message));
    }
    _pending.clear();
  }

  @override
  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    _shuttingDown = true;
    try {
      if (!_closed) await call('shutdown').timeout(const Duration(seconds: 5));
    } catch (_) {
      // The host may already have exited. Closing a window is still safe.
    } finally {
      try {
        await _process.stdin.close();
      } catch (_) {}
    }
    try {
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _process.kill();
    }
  }
}

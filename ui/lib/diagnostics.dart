import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Bounded local diagnostic events. No HTTP traffic or private CA files.
class Diagnostics {
  static Directory? directory;
  static bool enabled = false;
  static Future<void> _pending = Future.value();
  static int _queued = 0;
  static String safe(String value) {
    final lower = value.toLowerCase();
    if ([
      'authorization',
      'access_token',
      'refresh_token',
      'password',
      'private key',
      'private_key',
      'cookie',
    ].any(lower.contains)) {
      return '[敏感字段已隐藏 / sensitive field redacted]';
    }
    final home = Platform.environment['USERPROFILE'];
    if (home != null) {
      value = value
          .replaceAll(home, '%USERPROFILE%')
          .replaceAll(home.replaceAll(r'\', '/'), '%USERPROFILE%');
    }
    return value.length > 2000 ? value.substring(0, 2000) : value;
  }

  static Object? scrub(Object? value) {
    if (value is String) return safe(value);
    if (value is Map) {
      return value.map(
        (key, value) => MapEntry(
          key.toString(),
          [
                'authorization',
                'cookie',
                'password',
                'access_token',
                'refresh_token',
                'private_key',
              ].contains(key.toString().toLowerCase())
              ? '[redacted]'
              : scrub(value),
        ),
      );
    }
    if (value is List) return value.map(scrub).toList();
    return value;
  }

  static Future<void> initialize({required bool detailed}) async {
    enabled = detailed;
    final candidates = [
      if (Platform.environment['CPV_DIAGNOSTIC_DIR'] case final String value)
        value,
      if (Platform.environment['CPV_PROFILE'] case final String value)
        '$value/diagnostics',
      if (Platform.environment['LOCALAPPDATA'] case final String value)
        '$value/CPV/RustProfile/diagnostics',
      '${File(Platform.resolvedExecutable).parent.path}/.CPV/Profile/diagnostics',
    ];
    for (final path in candidates) {
      try {
        final dir = Directory(path);
        await dir.create(recursive: true);
        final probe = File('${dir.path}/.write-check-$pid');
        await probe.writeAsString('ok');
        await probe.delete();
        directory = dir;
        break;
      } catch (_) {}
    }
    record('ui_startup', {
      'version': '2.0.0-preview.2',
      'operating_system': Platform.operatingSystemVersion,
      'architecture': Platform.version.split(' ').last,
    }, force: true);
  }

  static void record(
    String event,
    Map<String, Object?> data, {
    bool force = false,
  }) {
    if (directory == null || (!enabled && !force) || _queued >= 128) return;
    final row = jsonEncode({
      'time_epoch_ms': DateTime.now().millisecondsSinceEpoch,
      'event': event,
      'data': scrub(data),
    });
    _queued++;
    _pending = _pending
        .then((_) async {
          final file = File('${directory!.path}/ui.jsonl');
          if (await file.exists() && await file.length() > 1024 * 1024) {
            await file.copy('${file.path}.1');
            await file.writeAsString('');
          }
          await file.writeAsString(
            '$row\n',
            mode: FileMode.append,
            flush: true,
          );
        })
        .catchError((_) {})
        .whenComplete(() => _queued--);
  }

  static Future<void> flush() => _pending;
  static Future<void> exportStartup(String path, String error) async {
    await flush();
    final events = <Object>[];
    if (directory != null) {
      final file = File('${directory!.path}/ui.jsonl');
      if (await file.exists()) {
        final input = await file.open();
        try {
          final length = await input.length();
          await input.setPosition(
            length > 200 * 1024 ? length - 200 * 1024 : 0,
          );
          final text = utf8.decode(
            await input.read(200 * 1024),
            allowMalformed: true,
          );
          for (final line in text.split('\n').reversed.take(700)) {
            try {
              events.add(scrub(jsonDecode(line))!);
            } catch (_) {}
          }
        } finally {
          await input.close();
        }
      }
    }
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 1,
        'product': '自定义星球和变种 / Custom Planets & Variants',
        'version': '2.0.0-preview.2',
        'startup_error': safe(error),
        'operating_system': Platform.operatingSystemVersion,
        'events': events,
      }),
      flush: true,
    );
  }
}

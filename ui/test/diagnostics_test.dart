import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cpv/diagnostics.dart';

void main() {
  test(
    'diagnostic export excludes credentials and bounds local journal',
    () async {
      final dir = await Directory.systemTemp.createTemp('cpv-diagnostic-test-');
      Diagnostics.directory = dir;
      Diagnostics.enabled = true;
      Diagnostics.record('test', {
        'error': 'access_token=secret-value',
        'password': 'plain-secret',
        'ordinary': 'visible',
      });
      await Diagnostics.flush();
      final path = '${dir.path}/report.json';
      await Diagnostics.exportStartup(path, 'ordinary failure');
      final text = await File(path).readAsString();
      final report = jsonDecode(text);
      expect(text, isNot(contains('secret-value')));
      expect(text, isNot(contains('plain-secret')));
      expect(report['events'], isNotEmpty);
      expect(text, contains('visible'));
      Diagnostics.directory = null;
      Diagnostics.enabled = false;
      for (final file in dir.listSync()) {
        if (file is File) await file.delete();
      }
      await dir.delete();
    },
  );
}

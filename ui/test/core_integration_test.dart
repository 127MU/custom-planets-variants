import 'dart:io';
import 'package:cpv/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native core shutdown is idempotent under simultaneous exit callbacks',
    () async {
      final exe = File('../backend/target/release/cpv-core.exe').absolute;
      final profile = Directory(
        'build/ipc-close-${DateTime.now().microsecondsSinceEpoch}',
      ).absolute;
      await profile.create(recursive: true);
      final process = await Process.start(
        exe.path,
        [],
        environment: {'CPV_PROFILE': profile.path},
      );
      final core = CpvCore(process);
      final initial = await core.call('bootstrap');
      expect(initial['state']['active'], false);
      await Future.wait([core.close(), core.close(), core.close()]);
      expect(await process.exitCode, 0);
      await expectLater(core.call('state'), throwsStateError);
    },
  );
}

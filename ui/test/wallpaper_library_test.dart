import 'dart:convert';
import 'dart:io';

import 'package:cpv/wallpaper_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finds local video projects and ignores other types and escaped paths', () async {
    final root = await Directory.systemTemp.createTemp('cpv-wallpaper');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/outside.mp4').writeAsString('');
    for (final (id, type, file) in [
      ('1', 'video', 'loop.mp4'),
      ('2', 'scene', 'loop.mp4'),
      ('3', 'video', '../outside.mp4'),
      ('4', 'video', 'missing.mp4'),
    ]) {
      final directory = await Directory('${root.path}/$id').create();
      await File('${directory.path}/loop.mp4').writeAsString('');
      await File('${directory.path}/project.json').writeAsString(jsonEncode({
        'type': type,
        'file': file,
        'title': 'Wallpaper $id',
      }));
    }
    final results = await findWallpaperVideos([root.path, root.path]);
    expect(results.map((entry) => entry.title), ['Wallpaper 1']);
    expect(results.single.path, endsWith('/1/loop.mp4'));
  });
}

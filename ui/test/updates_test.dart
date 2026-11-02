import 'dart:io';
import 'package:cpv/updates.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> manifest() => {
  'schema': 1,
  'repository': projectRepository,
  'version': '2.0.1',
  'asset': '自定义星球和变种_2.0.1.exe',
  'notes': '修复说明',
  'sha256': 'a' * 64,
};
void main() {
  test(
    'blocked GitHub automatically falls back to a Chinese mirror on every check',
    () async {
      final attempts = <Uri>[];
      final client = UpdateClient(
        fetch: (uri) async {
          attempts.add(uri);
          if (uri.host == 'api.github.com') {
            throw const SocketException('unreachable');
          }
          return manifest();
        },
      );
      final first = await client.check();
      final second = await client.check();
      expect(first.version, '2.0.1');
      expect(first.newerThan('2.0.0'), isTrue);
      expect(second.source, 'GH-Proxy');
      expect(attempts.length, 4);
      expect(attempts[0].host, 'api.github.com');
      expect(attempts[1].host, 'gh-proxy.com');
      expect(first.downloadUri(0).host, 'github.com');
      expect(first.downloadUri(1).host, 'gh-proxy.com');
      expect(first.downloadUri(2).host, 'ghfast.top');
      expect(
        first.downloadUri(1).toString(),
        contains('127MU/custom-planets-variants/releases/download/v2.0.1/'),
      );
    },
  );
  test('malformed first mirror falls back to the second mirror', () async {
    final client = UpdateClient(
      fetch: (uri) async {
        if (uri.host == 'api.github.com') {
          throw const SocketException('blocked');
        }
        if (uri.host == 'gh-proxy.com') {
          return {...manifest(), 'repository': 'foreign/project'};
        }
        return manifest();
      },
    );
    expect((await client.check()).source, 'GHFast');
  });
  test('GitHub release notes and download stay pinned to this repository', () {
    final update = UpdateInfo.github({
      'tag_name': 'v2.0.1',
      'draft': false,
      'prerelease': false,
      'body': 'Official release notes',
      'assets': [
        {
          'name': 'CPV_2.0.1.exe',
          'browser_download_url': 'https://untrusted.invalid/file.exe',
          'digest': 'sha256:${'b' * 64}',
        },
      ],
    });
    expect(update.notes, 'Official release notes');
    expect(update.downloadUri(0).host, 'github.com');
    expect(update.sha256, 'b' * 64);
  });
  test('reject external URLs and prerelease labels in release metadata', () {
    expect(
      () => UpdateInfo.manifest({
        ...manifest(),
        'asset': 'https://evil/file.exe',
      }, 'test'),
      throwsFormatException,
    );
    expect(
      () =>
          UpdateInfo.manifest({...manifest(), 'version': '2.0.1-rc.1'}, 'test'),
      throwsFormatException,
    );
    expect(
      () => UpdateInfo.manifest({
        ...manifest(),
        'repository': 'someone/else',
      }, 'test'),
      throwsFormatException,
    );
    expect(UpdateInfo.manifest(manifest(), 'test').newerThan('2.0.2'), isFalse);
  });
}

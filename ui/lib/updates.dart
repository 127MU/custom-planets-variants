import 'dart:convert';
import 'dart:io';

const productVersion = '2.0.0';
const projectRepository = '127MU/custom-planets-variants';
final projectUri = Uri.https('github.com', '/$projectRepository');
const updateMirrors = ['https://gh-proxy.com/', 'https://ghfast.top/'];

List<int> releaseVersion(String value) {
  if (!RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$').hasMatch(value) ||
      value.length > 24) {
    throw const FormatException('Invalid stable version');
  }
  return value.split('.').map(int.parse).toList();
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.asset,
    required this.notes,
    required this.sha256,
    required this.source,
  });
  final String version, asset, notes, sha256, source;
  Uri get releaseUri =>
      Uri.https('github.com', '/$projectRepository/releases/tag/v$version');
  Uri downloadUri(int route) {
    if (route < 0 || route > 2) {
      throw const FormatException('Invalid download route');
    }
    final original = Uri.https(
      'github.com',
      '/$projectRepository/releases/download/v$version/$asset',
    );
    return route == 0
        ? original
        : Uri.parse('${updateMirrors[route - 1]}$original');
  }

  bool newerThan(String current) {
    final a = releaseVersion(version), b = releaseVersion(current);
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  factory UpdateInfo.manifest(Map<String, dynamic> data, String source) {
    if (data['schema'] != 1 || data['repository'] != projectRepository) {
      throw const FormatException('Unknown update manifest');
    }
    final version = data['version'] as String;
    releaseVersion(version);
    final asset = data['asset'] as String;
    if (asset.isEmpty ||
        asset.length > 180 ||
        !asset.endsWith('.exe') ||
        asset.contains('..') ||
        RegExp(r'[/\\?#%\x00-\x1f]').hasMatch(asset)) {
      throw const FormatException('Invalid release asset');
    }
    final notes = data['notes'] as String? ?? '';
    final sha = data['sha256'] as String? ?? '';
    if (notes.length > 100000 ||
        (sha.isNotEmpty && !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha))) {
      throw const FormatException('Invalid update data');
    }
    return UpdateInfo(
      version: version,
      asset: asset,
      notes: notes,
      sha256: sha,
      source: source,
    );
  }
  factory UpdateInfo.github(Map<String, dynamic> data) {
    if (data['draft'] == true || data['prerelease'] == true) {
      throw const FormatException('Not a stable release');
    }
    final tag = data['tag_name'] as String;
    if (!tag.startsWith('v')) {
      throw const FormatException('Invalid release tag');
    }
    final assets = (data['assets'] as List).cast<Map<String, dynamic>>();
    final asset = assets.firstWhere(
      (item) =>
          item['name'] is String && (item['name'] as String).endsWith('.exe'),
    );
    final digest = asset['digest'] as String? ?? '';
    return UpdateInfo.manifest({
      'schema': 1,
      'repository': projectRepository,
      'version': tag.substring(1),
      'asset': asset['name'],
      'notes': data['body'] ?? '',
      'sha256': digest.startsWith('sha256:') ? digest.substring(7) : '',
    }, 'GitHub');
  }
}

typedef FetchUpdate = Future<Map<String, dynamic>> Function(Uri uri);

class UpdateClient {
  UpdateClient({FetchUpdate? fetch}) : fetch = fetch ?? _readJson;
  final FetchUpdate fetch;
  Future<UpdateInfo> check() async {
    final sources = [
      Uri.https('api.github.com', '/repos/$projectRepository/releases/latest'),
      for (final mirror in updateMirrors)
        Uri.parse(
          '${mirror}https://github.com/$projectRepository/releases/latest/download/latest.json',
        ),
    ];
    for (var i = 0; i < sources.length; i++) {
      try {
        final value = await fetch(sources[i]);
        return i == 0
            ? UpdateInfo.github(value)
            : UpdateInfo.manifest(value, i == 1 ? 'GH-Proxy' : 'GHFast');
      } catch (_) {
        /* A failed or malformed source must not block the mirrors. */
      }
    }
    throw const HttpException(
      'GitHub and both mirror update sources are unavailable',
    );
  }

  static bool _publicSource(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      ([
            'github.com',
            'api.github.com',
            'gh-proxy.com',
            'ghfast.top',
          ].contains(uri.host) ||
          uri.host.endsWith('.githubusercontent.com'));
  static Future<Map<String, dynamic>> _readJson(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    client.findProxy = (url) => HttpClient.findProxyFromEnvironment(url);
    try {
      return await (() async {
        var current = uri;
        for (var redirects = 0; redirects < 5; redirects++) {
          if (!_publicSource(current)) {
            throw const HttpException('Invalid update source');
          }
          final request = await client.getUrl(current);
          request.followRedirects = false;
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'CPV/$productVersion',
          );
          final response = await request.close();
          if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null) throw const HttpException('Missing redirect');
            current = current.resolve(location);
            await response.drain<void>();
            continue;
          }
          if (response.statusCode != 200) {
            throw HttpException('Update HTTP ${response.statusCode}');
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > 1048576) {
              throw const FormatException('Update response too large');
            }
            bytes.addAll(chunk);
          }
          return Map<String, dynamic>.from(
            jsonDecode(utf8.decode(bytes)) as Map,
          );
        }
        throw const HttpException('Too many update redirects');
      })().timeout(const Duration(seconds: 6));
    } finally {
      client.close(force: true);
    }
  }
}

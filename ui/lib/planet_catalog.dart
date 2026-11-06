import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> fetchPlanetCatalog() async {
  const host = 'api.live.prod.thehelldiversgame.com';
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri);

  Future<Map<String, dynamic>> read(String path) async {
    final request = await client.getUrl(Uri.https(host, path));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Planet catalog HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 4 * 1024 * 1024) {
        throw const FormatException('Planet catalog response too large');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  try {
    return await (() async {
      final current = await read('/api/WarSeason/current/WarID');
      final id = current['id'];
      if (id is! int || id <= 0) {
        throw const FormatException('Invalid war ID');
      }
      final info = await read('/api/WarSeason/$id/WarInfo');
      if (info['warId'] != id || info['planetInfos'] is! List) {
        throw const FormatException('Invalid planet catalog');
      }
      return {
        'warId': id,
        'planets': [
          for (final row in info['planetInfos'] as List)
            {'index': row['index'], 'nameHash': row['planetNameId32']},
        ],
      };
    })().timeout(const Duration(seconds: 9));
  } finally {
    client.close(force: true);
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

const videoExtensions = ['mp4', 'm4v', 'wmv', 'mov', 'webm', 'mkv', 'avi'];

bool isWallpaperVideo(String path) => videoExtensions.any(
  (extension) => path.toLowerCase().endsWith('.$extension'),
);

class WallpaperVideo {
  const WallpaperVideo(this.path, this.title, this.preview);
  final String path, title;
  final String? preview;
}

Future<List<String>> wallpaperRoots() async {
  final steam = <String>{};
  if (!Platform.isWindows) return [];
  for (final key in [
    r'HKCU\Software\Valve\Steam',
    r'HKLM\SOFTWARE\WOW6432Node\Valve\Steam',
  ]) {
    final result = await Process.run('reg.exe', [
      'query',
      key,
      '/v',
      key.startsWith('HKCU') ? 'SteamPath' : 'InstallPath',
    ]);
    final match = RegExp(
      r'REG_SZ\s+([^\r\n]+)',
    ).firstMatch(result.stdout.toString());
    if (match != null) steam.add(match.group(1)!.trim());
  }
  final programFiles = Platform.environment['ProgramFiles(x86)'];
  if (programFiles != null) steam.add('$programFiles/Steam');
  final libraries = {...steam};
  for (final root in steam) {
    try {
      final config = File('$root/steamapps/libraryfolders.vdf');
      if (await config.length() > 1024 * 1024) continue;
      final vdf = await config.readAsString();
      libraries.addAll(
        RegExp(r'"(?:path|\d+)"\s+"([^"\r\n]+)"')
            .allMatches(vdf)
            .map((match) => match.group(1)!.replaceAll(r'\\', r'\'))
            .where((path) => RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(path)),
      );
    } on FileSystemException {
      // Steam can be installed without this library index.
    }
  }
  return [
    for (final library in libraries) ...[
      '$library/steamapps/workshop/content/431960',
      '$library/steamapps/common/wallpaper_engine/projects',
      '$library/steamapps/common/wallpaper_engine/projects/myprojects',
      '$library/steamapps/common/wallpaper_engine/projects/431960',
    ],
  ];
}

Future<List<WallpaperVideo>> findWallpaperVideos(Iterable<String> roots) async {
  final videos = <String, WallpaperVideo>{};
  for (final root in roots) {
    try {
      final folder = Directory(root);
      final projects = <Directory>[folder];
      await for (final child in folder.list(followLinks: false)) {
        if (child is Directory) projects.add(child);
      }
      for (final project in projects) {
        try {
          final metadata = File('${project.path}/project.json');
          if (await metadata.length() > 1024 * 1024) continue;
          final document = jsonDecode(await metadata.readAsString());
          if (document is! Map ||
              document['type'].toString().toLowerCase() != 'video') {
            continue;
          }
          final media = document['file'];
          if (media is! String || !isWallpaperVideo(media)) continue;
          final prefix = (await project.resolveSymbolicLinks()).replaceAll(
            '\\',
            '/',
          );
          Future<String?> resolve(Object? name) async {
            if (name is! String ||
                name.trim().isEmpty ||
                name.contains(':') ||
                name.startsWith('/') ||
                name.startsWith('\\')) {
              return null;
            }
            try {
              final path = (await File(
                '${project.path}/$name',
              ).resolveSymbolicLinks()).replaceAll('\\', '/');
              return path.toLowerCase().startsWith('${prefix.toLowerCase()}/')
                  ? path
                  : null;
            } on FileSystemException {
              return null;
            }
          }

          final path = await resolve(media);
          if (path == null) continue;
          final title = document['title'];
          videos[path.toLowerCase()] = WallpaperVideo(
            path,
            title is String && title.trim().isNotEmpty ? title : media,
            await resolve(document['preview']),
          );
        } on FileSystemException {
          continue;
        } on FormatException {
          continue;
        }
      }
    } on FileSystemException {
      continue;
    }
  }
  return videos.values.toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
}

class WallpaperLibrary extends StatefulWidget {
  const WallpaperLibrary({super.key, required this.english});
  final bool english;

  @override
  State<WallpaperLibrary> createState() => _WallpaperLibraryState();
}

class _WallpaperLibraryState extends State<WallpaperLibrary> {
  late Future<List<WallpaperVideo>> results = wallpaperRoots().then(
    findWallpaperVideos,
  );
  String search = '';
  String t(String zh, String en) => widget.english ? en : zh;

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 600,
      height: 510,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('Wallpaper Engine 视频壁纸', 'Wallpaper Engine videos'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t('搜索壁纸标题', 'Search titles'),
              ),
              onChanged: (value) =>
                  setState(() => search = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder(
                future: results,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final rows = snapshot.data ?? [];
                  final matches = rows
                      .where(
                        (entry) => entry.title.toLowerCase().contains(search),
                      )
                      .toList();
                  if (matches.isEmpty) {
                    return Center(
                      child: Text(
                        rows.isEmpty
                            ? t(
                                '未找到视频壁纸。可以手动选择创意工坊或项目目录。',
                                'No video wallpapers found. Choose a Workshop or project folder.',
                              )
                            : t('没有匹配的壁纸', 'No matching wallpapers'),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final entry = matches[index];
                      const placeholder = Icon(Icons.movie_outlined);
                      return ListTile(
                        leading: entry.preview == null
                            ? placeholder
                            : SizedBox(
                                width: 58,
                                height: 40,
                                child: Image.file(
                                  File(entry.preview!),
                                  cacheWidth: 116,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => placeholder,
                                ),
                              ),
                        title: Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, entry),
                      );
                    },
                  );
                },
              ),
            ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () async {
                    final folder = await getDirectoryPath();
                    if (mounted && folder != null) {
                      setState(() => results = findWallpaperVideos([folder]));
                    }
                  },
                  child: Text(t('选择目录', 'Choose folder')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t('关闭', 'Close')),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

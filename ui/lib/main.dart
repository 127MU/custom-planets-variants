import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'package:url_launcher/url_launcher.dart';
import 'updates.dart';
import 'core.dart';
import 'diagnostics.dart';
import 'planet_catalog.dart';
import 'version.dart';
import 'morrow/liquid_glass.dart';

typedef Json = Map<String, dynamic>;
String recordName(Json row, bool english) =>
    (english
            ? row['englishName'] ?? row['native'] ?? row['name']
            : row['name'] ?? row['englishName'])
        ?.toString() ??
    '#${row['id']}';
bool matches(Json row, String query) =>
    query.trim().isEmpty ||
    ['id', 'name', 'englishName', 'native', 'aliases', 'reference_note']
        .map((k) => row[k] ?? '')
        .join(' ')
        .toLowerCase()
        .contains(query.trim().toLowerCase());

String stateFingerprint(Json value) {
  final health = {...(value['health'] as Map? ?? {})}..remove('updated');
  return jsonEncode({...value, 'health': health});
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Diagnostics.initialize(
    detailed:
        arguments.contains('--diagnostic') ||
        Platform.environment['CPV_DIAGNOSTICS'] == '1',
  );
  FlutterError.onError = (details) {
    Diagnostics.record('flutter_error', {
      'error': details.exceptionAsString(),
      'stack': details.stack?.toString(),
    }, force: true);
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    Diagnostics.record('unhandled_error', {
      'error': error.toString(),
      'stack': stack.toString(),
    }, force: true);
    return false;
  };
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1280, 800),
        minimumSize: Size(900, 620),
        center: true,
        title: '自定义星球和变种',
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  try {
    final core = await CpvCore.start();
    final data = Map<String, dynamic>.from(await core.call('bootstrap'));
    runApp(CpvApp(core: core, initial: data));
  } catch (e) {
    Diagnostics.record('startup_failed', {'error': e.toString()}, force: true);
    await Diagnostics.flush();
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    '启动失败 / Unable to start\n\n${Diagnostics.safe(e.toString())}',
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('导出诊断日志 / Export diagnostic log'),
                    onPressed: () async {
                      final file = await getSaveLocation(
                        suggestedName: 'CPV-startup-diagnostics.json',
                      );
                      if (file != null) {
                        await Diagnostics.exportStartup(
                          file.path,
                          e.toString(),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CpvApp extends StatefulWidget {
  const CpvApp({
    super.key,
    required this.core,
    required this.initial,
    this.nativeWindow = true,
    this.updates,
    this.version,
  });
  final CpvApi core;
  final Json initial;
  final bool nativeWindow;
  final UpdateClient? updates;

  /// 发行包清单里的版本；缺省时从可执行文件同级的 `manifest.json` 读取。
  /// 测试可以显式注入。
  final String? version;
  @override
  State<CpvApp> createState() => _CpvAppState();
}

class _CpvAppState extends State<CpvApp>
    with WidgetsBindingObserver, WindowListener {
  late Json settings, state;
  late List<Json> targets, effects;
  late final ValueNotifier<List<Json>> planetCatalog;
  List<Json> get planets => planetCatalog.value;
  late final String currentVersion;
  int page = 0;
  int settingsRevision = 0;
  bool working = false, polling = false;
  bool checkingUpdates = false;
  UpdateInfo? latestUpdate;
  bool updateFailed = false;
  String query = '';
  Timer? timer, saveTimer;
  Future<void>? closing;
  bool destroyingWindow = false;
  ui.Image? backgroundImage;
  int backgroundRevision = 0;
  bool loadingBackground = false;
  final messenger = GlobalKey<ScaffoldMessengerState>();
  final navigator = GlobalKey<NavigatorState>();
  bool get en => settings['language'] == 'en';
  String t(String zh, String english) => en ? english : zh;
  String get title => t('自定义星球和变种', 'Custom Planets & Variants');
  bool get dark =>
      settings['theme'] == 'dark' ||
      settings['theme'] == 'system' &&
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark;
  Color get accent => [
    const Color(0xff8270b2),
    const Color(0xff6d9a8b),
    const Color(0xffb28e73),
    const Color(0xff7897c1),
  ][(settings['accent'] as num? ?? 0).toInt()];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    currentVersion = widget.version ?? readReleaseVersion();
    if (widget.nativeWindow && Platform.isWindows) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
    settings = Json.from(widget.initial['settings']);
    if (settings['backgroundImage'] case final String path) {
      loadBackground(path);
    }
    Diagnostics.enabled = settings['diagnostics'] == true;
    state = Json.from(widget.initial['state']);
    targets = rows(widget.initial['targets']);
    effects = rows(widget.initial['catalog']['effects']);
    planetCatalog = ValueNotifier(rows(widget.initial['catalog']['planets']));
    timer = Timer.periodic(const Duration(seconds: 1), (_) => poll());
    if (widget.nativeWindow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        checkForUpdates(automatic: true);
        refreshPlanets();
      });
    }
  }

  static List<Json> rows(dynamic v) =>
      (v as List).map((e) => Json.from(e)).toList();
  @override
  void didChangePlatformBrightness() {
    if (settings['theme'] == 'system') setState(() {});
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (widget.nativeWindow && Platform.isWindows) {
      await finishWindowClose();
      // The window manager has already posted WM_QUIT. Do not request a
      // second engine exit while native plugins are being torn down.
      return AppExitResponse.cancel;
    }
    await closeOnce();
    return AppExitResponse.exit;
  }

  Future<void> closeOnce() => closing ??= () async {
    timer?.cancel();
    saveTimer?.cancel();
    try {
      await widget.core.call('settings', {...settings}..remove('installedCa'));
    } catch (_) {}
    await widget.core.close();
    await Diagnostics.flush();
  }();

  @override
  void onWindowClose() {
    finishWindowClose();
  }

  Future<void> finishWindowClose() async {
    if (destroyingWindow) return;
    destroyingWindow = true;
    try {
      await closeOnce();
    } finally {
      await windowManager.destroy();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    saveTimer?.cancel();
    backgroundImage?.dispose();
    planetCatalog.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (widget.nativeWindow && Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> poll() async {
    if (polling || working || closing != null) return;
    polling = true;
    try {
      final next = Json.from(await widget.core.call('state'));
      if (next['catalogUpdated'] != state['catalogUpdated'] ||
          next['planetsUpdated'] != state['planetsUpdated']) {
        final catalog = await widget.core.call('catalog');
        if (mounted) {
          setState(() {
            effects = rows(catalog['effects']);
            planetCatalog.value = rows(catalog['planets']);
          });
        }
      }
      if (mounted && stateFingerprint(state) != stateFingerprint(next)) {
        setState(() => state = next);
      }
    } catch (e) {
      if (mounted) {
        setState(() => state = {'status': e.toString(), 'active': false});
      }
    } finally {
      polling = false;
    }
  }

  Future<void> refreshPlanets() async {
    try {
      final catalog = await fetchPlanetCatalog();
      if (!mounted || closing != null) return;
      final updated = await widget.core.call('save_planet_catalog', catalog);
      if (mounted && closing == null) {
        setState(() => planetCatalog.value = rows(updated));
      }
    } catch (error) {
      Diagnostics.record('planet_catalog_unavailable', {
        'error': error.toString(),
      });
    }
  }

  void note(Object value) {
    messenger.currentState?.showSnackBar(
      SnackBar(
        content: Text(value.toString()),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<dynamic> action(String method, [Json args = const {}]) async {
    if (working) return null;
    setState(() => working = true);
    try {
      final result = await widget.core.call(method, args);
      if (mounted) await pollAfterAction();
      return result;
    } catch (e) {
      note(e);
      return null;
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> pollAfterAction() async {
    final next = Json.from(await widget.core.call('state'));
    if (mounted) setState(() => state = next);
  }

  Future<void> setting(Json change) async {
    final previous = {...settings};
    final revision = ++settingsRevision;
    setState(() => settings = {...settings, ...change});
    Diagnostics.enabled = settings['diagnostics'] == true;
    final snapshot = {...settings}..remove('installedCa');
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 250), () async {
      try {
        final next = Json.from(await widget.core.call('settings', snapshot));
        if (mounted && revision == settingsRevision) {
          setState(() => settings = next);
        }
      } catch (e) {
        if (mounted && revision == settingsRevision) {
          setState(() => settings = previous);
          Diagnostics.enabled = settings['diagnostics'] == true;
        }
        note(e);
      }
    });
  }

  Future<void> loadBackground(String? path, {bool save = false}) async {
    final revision = ++backgroundRevision;
    ui.Image? image;
    try {
      if (path != null) {
        final file = File(path);
        if (await file.length() > 24 * 1024 * 1024) {
          throw const FormatException('Image too large');
        }
        final buffer = await ui.ImmutableBuffer.fromFilePath(path);
        final codec = await ui.instantiateImageCodecWithSize(
          buffer,
          getTargetSize: (width, height) {
            final scale = math.min(1.0, 2560 / math.max(width, height));
            return ui.TargetImageSize(
              width: math.max(1, (width * scale).round()),
              height: math.max(1, (height * scale).round()),
            );
          },
        );
        try {
          image = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      }
      if (!mounted || revision != backgroundRevision) {
        image?.dispose();
        return;
      }
      final old = backgroundImage;
      setState(() => backgroundImage = image);
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
      if (save) await setting({'backgroundImage': path});
    } catch (_) {
      if (mounted && save) {
        note(
          t(
            '无法读取这张图片。请选择 24 MB 以内的图片。',
            'Could not open this image. Choose an image under 24 MB.',
          ),
        );
      }
    }
  }

  Future<void> chooseBackground() async {
    setState(() => loadingBackground = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Images',
            extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
          ),
        ],
      );
      if (file != null && mounted) await loadBackground(file.path, save: true);
    } catch (_) {
      if (mounted) note(t('无法打开图片选择器', 'Could not open the image picker'));
    } finally {
      if (mounted) setState(() => loadingBackground = false);
    }
  }

  double get backgroundImageOpacity => dark ? .28 : .46;

  Future<void> importPlans() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (file == null) return;
    final result = await action('import', {'path': file.path});
    if (result is List && mounted) setState(() => targets = rows(result));
  }

  Future<void> exportPlans() async {
    final file = await getSaveLocation(
      suggestedName: 'cpv-plan.json',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (file != null && await action('export', {'path': file.path}) == true) {
      note(t('方案已导出', 'Plan exported'));
    }
  }

  String planetName(int id) {
    final p = planets.where((p) => p['id'] == id);
    return p.isEmpty ? '#$id' : recordName(p.first, en);
  }

  Future<void> addPlanet() async {
    final p = await showDialog<Json>(
      context: navigator.currentState!.overlay!.context,
      builder: (context) =>
          PlanetPicker(planets: planets, live: planetCatalog, en: en),
    );
    if (p != null) {
      final existing = targets.where((e) => e['planet'] == p['id']);
      await edit(
        existing.isNotEmpty
            ? existing.first
            : {
                'planet': p['id'],
                'effects': <int>[],
                'enabled': true,
                'owner': 0,
                'campaign': false,
                'force_open': false,
                'campaign_type': 0,
                'campaign_race': 0,
                'open_regions': false,
                'initialize_regions': false,
                'defense_source': -1,
                'defense_level': 20,
                'defense_hours': 48,
                'defense_count': 38,
                'campaign_count': 20,
              },
      );
    }
  }

  Future<void> edit(Json target) async {
    final result = await showGeneralDialog<Json>(
      context: navigator.currentState!.overlay!.context,
      barrierDismissible: false,
      barrierLabel: 'Editor',
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, a, b) => Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: SizedBox(
            width: math.min(MediaQuery.sizeOf(context).width - 28, 780),
            child: PlanetEditor(
              target: target,
              effects: effects,
              planets: planets,
              en: en,
              onSave: (draft) async {
                final data = await widget.core.call('save_target', {
                  'target': draft,
                });
                if (mounted) setState(() => targets = rows(data));
              },
            ),
          ),
        ),
      ),
      transitionBuilder: (context, a, b, child) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(.12, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
    if (result != null) {
      if (mounted) {
        note(
          t('方案已保存；游戏刷新战况后应用', 'Saved; applies when the game refreshes status'),
        );
      }
    }
  }

  Gradient get backgroundGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: dark
        ? [
            const Color(0xff171523),
            const Color(0xff232032),
            const Color(0xff18252a),
          ]
        : [
            const Color(0xfff6f4fb),
            const Color(0xffe9e3f3),
            const Color(0xffeef3ef),
          ],
  );

  Widget glass(Widget child, {EdgeInsets padding = const EdgeInsets.all(24)}) {
    final opacity = (settings['opacity'] as num? ?? .76).toDouble();
    final liquid = settings['material'] == 'liquid';
    final solid = settings['material'] == 'solid';
    final tint = dark ? const Color(0xff22232d) : Colors.white;
    final radius = BorderRadius.circular(24);
    return LiquidGlassSurface(
      backgroundGradient: backgroundGradient,
      backgroundImage: backgroundImage,
      backgroundImageOpacity: backgroundImageOpacity,
      tint: tint,
      dark: dark,
      borderRadius: radius,
      transparentCanvas: false,
      material: liquid
          ? GlassMaterial.liquid(
              tint: tint,
              dark: dark,
              readable: false,
              borderRadius: radius,
            )
          : GlassMaterial(
              blur: solid ? 0 : 14,
              liquid: 0,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: solid ? 1 : opacity),
                borderRadius: radius,
                border: Border.all(
                  color: (dark ? Colors.white : Colors.white).withValues(
                    alpha: .30,
                  ),
                ),
              ),
            ),
      child: Padding(padding: padding, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: dark ? Brightness.dark : Brightness.light,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messenger,
      navigatorKey: navigator,
      title: title,
      locale: Locale(en ? 'en' : 'zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: 'Microsoft YaHei UI',
        textTheme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
        ).textTheme.apply(fontFamily: 'Microsoft YaHei UI'),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colorScheme.surface.withValues(alpha: .72),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
          ),
        ),
        dividerColor: colorScheme.outlineVariant.withValues(alpha: .3),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: DecoratedBox(
            decoration: BoxDecoration(gradient: backgroundGradient),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (backgroundImage != null)
                  IgnorePointer(
                    child: RawImage(
                      image: backgroundImage,
                      fit: BoxFit.cover,
                      opacity: AlwaysStoppedAnimation(backgroundImageOpacity),
                    ),
                  ),
                SafeArea(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final wide = box.maxWidth >= 960;
                      return Padding(
                        padding: EdgeInsets.all(wide ? 22 : 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: wide ? 216 : 78,
                              child: sidebar(wide),
                            ),
                            SizedBox(width: wide ? 24 : 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  topbar(),
                                  const SizedBox(height: 22),
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      child: KeyedSubtree(
                                        key: ValueKey(page),
                                        child: switch (page) {
                                          0 => plansPage(),
                                          1 => catalogPage(),
                                          2 => connectionPage(),
                                          4 => inventoryPage(),
                                          _ => settingsPage(),
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                if (widget.nativeWindow && Platform.isWindows)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: MediaQuery.sizeOf(context).width >= 960 ? 22 : 12,
                    child: windowDrag(
                      const SizedBox.expand(),
                      key: const ValueKey('window-top-drag-zone'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget sidebar(bool wide) {
    final labels = [
      t('星球方案', 'Planet plans'),
      t('效果列表', 'Effect library'),
      t('连接游戏', 'Connect game'),
      t('软件设置', 'App settings'),
      t('军械库', 'Armory'),
    ];
    final hints = [
      t(
        '选择星球，设置敌人、作战和附加效果。',
        'Choose a planet, its enemies, operations and effects.',
      ),
      t(
        '查找变种、天气、临时战备等效果，点击条目查看说明。',
        'Browse variants, weather and temporary stratagems. Open an entry for details.',
      ),
      t(
        '完成首次连接设置，启动代理并从 Steam 进入游戏。',
        'Set up the connection, start the proxy and launch the game through Steam.',
      ),
      t(
        '调整外观和语言，检查更新或导出问题日志。',
        'Change appearance and language, check updates or export troubleshooting logs.',
      ),
      t(
        '选择要在游戏中预览的武器和投掷物，设置配件替换。',
        'Choose weapons and throwables to preview, or replace attachments.',
      ),
    ];
    final icons = [
      Icons.dashboard_outlined,
      Icons.auto_awesome_mosaic_outlined,
      Icons.cable_rounded,
      Icons.tune_rounded,
      Icons.inventory_2_outlined,
    ];
    return glass(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          windowDrag(
            Row(
              children: [
                Image.asset(
                  'assets/cpv.png',
                  width: wide ? 42 : 36,
                  height: 42,
                ),
                if (wide) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            height: 42,
            key: const ValueKey('window-logo-drag-zone'),
          ),
          if (wide) ...[
            const SizedBox(height: 12),

            const SizedBox(height: 6),
            Text(
              currentVersion.isEmpty ? '—' : currentVersion,
              style: const TextStyle(fontSize: 10, letterSpacing: 1.8),
            ),
          ],
          const SizedBox(height: 34),
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Tooltip(
                message: '${labels[i]}\n${hints[i]}',
                child: Material(
                  color: page == i
                      ? accent.withValues(alpha: .17)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() {
                      page = i;
                      query = '';
                    }),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: wide ? 14 : 8,
                        vertical: 17,
                      ),
                      child: Row(
                        mainAxisAlignment: wide
                            ? MainAxisAlignment.start
                            : MainAxisAlignment.center,
                        children: [
                          Icon(
                            icons[i],
                            size: 22,
                            color: page == i ? accent : null,
                          ),
                          if (wide) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                labels[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: page == i
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
          if (wide)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                t(
                  '选择星球，组合效果。\n保留自己的游玩方案。',
                  'Choose a planet.\nMake it your own.',
                ),
                style: const TextStyle(fontSize: 12, height: 1.8),
              ),
            ),
          const SizedBox(height: 16),
          Tooltip(
            message: t('切换语言', 'Switch language'),
            child: TextButton(
              onPressed: () => setting({'language': en ? 'zh' : 'en'}),
              child: Text(en ? '中' : 'EN'),
            ),
          ),
        ],
      ),
      padding: EdgeInsets.all(wide ? 18 : 10),
    );
  }

  Widget topbar() => Row(
    children: [
      Expanded(
        child: windowDrag(
          Text(
            '${t('工作台', 'Workspace')}  /  ${[t('星球方案', 'Planet plans'), t('效果列表', 'Effect library'), t('连接游戏', 'Connect game'), t('软件设置', 'App settings'), t('军械库', 'Armory')][page]}',
            style: const TextStyle(fontSize: 13),
          ),
          key: const ValueKey('window-header-drag-zone'),
        ),
      ),
      windowDrag(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: (state['ready'] == true ? Colors.green : accent).withValues(
              alpha: .12,
            ),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            children: [
              if (working || state['preparing'] == true)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.circle,
                  size: 8,
                  color: state['ready'] == true ? Colors.green : accent,
                ),
              const SizedBox(width: 8),
              Text(
                state['ready'] == true
                    ? t('代理就绪', 'Proxy ready')
                    : state['active'] == true
                    ? t('连接中', 'Connecting')
                    : t('未开启代理', 'Proxy off'),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        key: const ValueKey('window-status-drag-zone'),
      ),
      if (widget.nativeWindow && Platform.isWindows) ...[
        const SizedBox(width: 12),
        WindowCaptionButton.minimize(
          brightness: dark ? Brightness.dark : Brightness.light,
          onPressed: () => windowManager.minimize(),
        ),
        WindowCaptionButton.maximize(
          brightness: dark ? Brightness.dark : Brightness.light,
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        WindowCaptionButton.close(
          brightness: dark ? Brightness.dark : Brightness.light,
          onPressed: () => windowManager.close(),
        ),
      ],
    ],
  );
  Widget windowDrag(Widget child, {Key? key, double height = 36}) =>
      widget.nativeWindow && Platform.isWindows
      ? DragToMoveArea(
          key: key,
          child: SizedBox(
            height: height,
            child: Align(alignment: Alignment.centerLeft, child: child),
          ),
        )
      : child;
  Widget heading(String title, String subtitle, List<Widget> actions) =>
      LayoutBuilder(
        builder: (context, c) => Wrap(
          spacing: 18,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: math.max(180, c.maxWidth - 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: dark ? Colors.white60 : Colors.black54,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            ...actions,
          ],
        ),
      );
  Widget plansPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      heading(
        t('让每次出发，都不一样。', 'A different world. Every drop.'),
        t(
          '保存星球、作战与效果的组合。',
          'Your planets, operations and effects — in one place.',
        ),
        [
          OutlinedButton.icon(
            onPressed: working ? null : importPlans,
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: Text(t('导入', 'Import')),
          ),
          FilledButton.icon(
            onPressed: working ? null : addPlanet,
            icon: const Icon(Icons.add, size: 18),
            label: Text(t('添加星球', 'Add planet')),
          ),
        ],
      ),
      const SizedBox(height: 22),
      Row(
        children: [
          Text(
            t('我的方案', 'My plans'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Text('${targets.length}', style: TextStyle(color: accent)),
          const Spacer(),
          TextButton.icon(
            onPressed: targets.isEmpty ? null : exportPlans,
            icon: const Icon(Icons.ios_share, size: 17),
            label: Text(t('导出方案', 'Export')),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Expanded(
        child: targets.isEmpty
            ? emptyPlans()
            : LayoutBuilder(
                builder: (context, c) => GridView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: c.maxWidth >= 900
                        ? 4
                        : c.maxWidth >= 660
                        ? 3
                        : c.maxWidth >= 420
                        ? 2
                        : 1,
                    mainAxisExtent: 224,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: targets.length,
                  itemBuilder: (context, i) => planetCard(targets[i]),
                ),
              ),
      ),
    ],
  );
  Widget emptyPlans() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 700),
      child: glass(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_outlined, size: 56, color: accent),
            const SizedBox(height: 22),
            Text(
              t('从一颗星球开始', 'Start with a planet'),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              t(
                '添加星球后，为它组合变种、天气与作战规则。',
                'Add a planet, then shape its variants, weather and operations.',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: addPlanet,
              icon: const Icon(Icons.add),
              label: Text(t('创建第一个方案', 'Create your first plan')),
            ),
          ],
        ),
        padding: const EdgeInsets.all(42),
      ),
    ),
  );
  Widget planetCard(Json target) {
    final ids = List<int>.from(target['effects']);
    final summary = ids.isEmpty
        ? t('尚未选择效果', 'No effects selected')
        : ids
              .take(2)
              .map((id) {
                final found = effects.where((e) => e['id'] == id);
                return found.isEmpty ? '#$id' : recordName(found.first, en);
              })
              .join(' · ');
    final operation = target['campaign'] == true || target['force_open'] == true
        ? switch (target['campaign_type'] ?? 0) {
            0 => t('普通作战', 'Standard operations'),
            3 => t('城市作战', 'City operations'),
            4 => t('防守作战', 'Defense operations'),
            _ => t('自定义作战', 'Custom operations'),
          }
        : t('沿用游戏作战', 'Current game operations');
    return glass(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.public_rounded, color: accent, size: 18),
              ),
              const Spacer(),
              Switch(
                value: target['enabled'] == true,
                onChanged: working
                    ? null
                    : (value) async {
                        final data = await action('save_target', {
                          'target': {...target, 'enabled': value},
                        });
                        if (data is List && mounted) {
                          setState(() => targets = rows(data));
                        }
                      },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Tooltip(
            message: planetName(target['planet']),
            child: Text(
              planetName(target['planet']),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '#${target['planet']} · ${ids.length} ${t('个效果', 'effects')}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 6),
          Tooltip(
            message: summary,
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: dark ? Colors.white60 : Colors.black54,
              ),
            ),
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: operation,
                  child: Text(
                    operation,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              IconButton(
                tooltip: t('删除方案', 'Remove plan'),
                visualDensity: VisualDensity.compact,
                onPressed: working
                    ? null
                    : () async {
                        if (!await confirm(
                          t('删除此星球方案？', 'Remove this planet plan?'),
                          t(
                            '只移除本地方案。',
                            'Only this local plan will be removed.',
                          ),
                        )) {
                          return;
                        }
                        final data = await action('remove_target', {
                          'planet': target['planet'],
                        });
                        if (data is List && mounted) {
                          setState(() => targets = rows(data));
                        }
                      },
                icon: const Icon(Icons.delete_outline, size: 17),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: () => edit(target),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  minimumSize: const Size(60, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(t('编辑', 'Edit')),
              ),
            ],
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
    );
  }

  Widget catalogPage() => EffectLibrary(
    effects: effects,
    en: en,
    selected: const {},
    onToggle: null,
    header: heading(
      t('效果列表', 'Effect library'),
      t(
        '按类型查找；中英文名称和 ID 都能搜索。',
        'Search by type, Chinese or English name, or ID.',
      ),
      [],
    ),
  );
  Future<void> installCertificateWithAuthorization() async {
    final progress = showDialog<void>(
      context: navigator.currentState!.overlay!.context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(t('安装本机证书', 'Install local certificate')),
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Text(
                  t(
                    '请在 Windows UAC 窗口中授权。授权后自动安装并检查当前用户的信任状态。',
                    'Authorize the Windows UAC dialog. Installation and current-user trust verification then run automatically.',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      await action('install_certificate');
    } finally {
      if (mounted) {
        navigator.currentState!.pop();
        await progress;
      }
    }
  }

  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
        context: navigator.currentState!.overlay!.context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('确认', 'Confirm')),
            ),
          ],
        ),
      ) ??
      false;
  Widget connectionPage() => ListView(
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      heading(
        t('保持连接，轻松出发。', 'Ready when you are.'),
        t(
          '仅处理必要的游戏 API，登录与反作弊连接不解密。',
          'Only the required game API is intercepted. Login and anti-cheat remain outside decryption.',
        ),
        [],
      ),
      const SizedBox(height: 24),
      glass(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.power_settings_new, color: accent),
                const SizedBox(width: 12),
                Text(
                  t('变种代理', 'Variant proxy'),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Switch(
                  value: state['active'] == true,
                  onChanged: working
                      ? null
                      : (value) => action(value ? 'start' : 'stop'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SelectableText(state['status']?.toString() ?? ''),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                metric(t('战况', 'Status'), state['health']?['statuses'] ?? 0),
                metric(t('改写', 'Rewrites'), state['health']?['rewrites'] ?? 0),
                metric(
                  t('上游错误', 'Upstream errors'),
                  state['health']?['failures']?['connect'] ?? 0,
                ),
              ],
            ),
            const Divider(height: 34),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('使用电脑已有的代理', 'Use the computer’s existing proxy')),
              subtitle: Text(
                t(
                  '通过系统中已配置的 HTTP 代理连接游戏接口。先停止本程序代理再切换。',
                  'Routes game API requests through the HTTP proxy configured in Windows. Stop this app’s proxy before switching.',
                ),
              ),
              value: settings['useSystemProxy'] == true,
              onChanged: working || state['active'] == true
                  ? null
                  : (v) => setting({'useSystemProxy': v}),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      glass(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('01  本机证书', '01  Local certificate'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              state['trusted'] == true
                  ? t('当前用户已信任本机证书', 'Trusted by the current user')
                  : state['certificateExists'] == true
                  ? t('证书已生成，尚未信任', 'Generated, not yet trusted')
                  : t(
                      '首次使用需生成并信任本机证书。',
                      'Generate and trust a local certificate before first use.',
                    ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: working || state['active'] == true
                      ? null
                      : () => action('prepare_certificate'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(132, 48),
                  ),
                  child: Text(t('生成证书', 'Generate')),
                ),
                FilledButton.tonal(
                  onPressed: working || state['certificateExists'] != true
                      ? null
                      : () async {
                          if (await confirm(
                            t('信任本机证书？', 'Trust the local certificate?'),
                            t(
                              '同意后将请求 Windows UAC 授权，仅将此代理的 CA 加入当前用户信任库，用于必要游戏 API 的 HTTPS 解密。',
                              'After confirmation, Windows UAC authorization is requested to add this proxy CA to the current-user trust store for the required game API.',
                            ),
                          )) {
                            await installCertificateWithAuthorization();
                          }
                        },
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(132, 48),
                  ),
                  child: Text(t('安装信任', 'Trust certificate')),
                ),
                TextButton(
                  onPressed: working
                      ? null
                      : () async {
                          if (await confirm(
                            t('移除本程序安装的证书？', 'Remove the owned certificate?'),
                            t(
                              '只移除本程序记录的证书。',
                              'Only the certificate recorded by this app will be removed.',
                            ),
                          )) {
                            await action('remove_certificate');
                          }
                        },
                  style: TextButton.styleFrom(
                    minimumSize: const Size(132, 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 17,
                    ),
                  ),
                  child: Text(t('移除信任', 'Remove trust')),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      glass(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('02  配置 Steam', '02  Connect Steam'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              t(
                '复制启动选项并粘贴到游戏属性 → 通用 → 启动选项。先退出游戏，再重新启动。',
                'Copy launch options into game Properties → General → Launch Options. Fully exit the game before restarting.',
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: working
                      ? null
                      : () async {
                          final result = await action('steam_options');
                          if (result is String) {
                            await Clipboard.setData(
                              ClipboardData(text: result),
                            );
                            note(
                              t('Steam 启动选项已复制', 'Steam launch options copied'),
                            );
                          }
                        },
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(t('复制启动选项', 'Copy launch options')),
                ),
                FilledButton.icon(
                  onPressed: working || state['ready'] != true
                      ? null
                      : () => action('launch_game'),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(t('通过 Steam 启动', 'Launch via Steam')),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      glass(
        Row(
          children: [
            const Icon(Icons.folder_open_outlined),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                t(
                  '若代理核心未找到，可手动选择配套运行时的 python.exe。',
                  'If the proxy core is missing, select python.exe from the bundled runtime.',
                ),
              ),
            ),
            TextButton(
              onPressed: working
                  ? null
                  : () async {
                      final file = await openFile(
                        acceptedTypeGroups: [
                          const XTypeGroup(label: 'EXE', extensions: ['exe']),
                        ],
                      );
                      if (file != null) await setting({'runtime': file.path});
                    },
              child: Text(t('选择运行时', 'Locate runtime')),
            ),
          ],
        ),
      ),
    ],
  );
  Widget metric(String label, dynamic n) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: accent.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text('$label  $n'),
  );
  Future<void> openBrowser(Uri uri) async {
    if (uri.scheme != 'https' ||
        !['github.com', 'gh-proxy.com', 'ghfast.top'].contains(uri.host)) {
      return;
    }
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        note(
          t(
            '无法打开浏览器，可复制仓库地址手动访问',
            'Could not open the browser; copy the repository address to open it manually',
          ),
        );
      }
    } catch (e) {
      note(t('打开浏览器失败', 'Could not open the browser'));
    }
  }

  Future<void> checkForUpdates({bool automatic = false}) async {
    if (checkingUpdates || !mounted) return;
    setState(() {
      checkingUpdates = true;
      updateFailed = false;
    });
    try {
      final result = await (widget.updates ?? UpdateClient()).check();
      if (!mounted) return;
      setState(() => latestUpdate = result);
      // 开发环境读不到发行包清单时按 0.0.0 比较，仍能提示新版本。
      if (result.newerThan(currentVersion.isEmpty ? '0.0.0' : currentVersion)) {
        while (mounted &&
            closing == null &&
            (working || navigator.currentState?.canPop() == true)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        if (!mounted || closing != null) return;
        await showDialog<void>(
          context: navigator.currentState!.overlay!.context,
          builder: (context) => AlertDialog(
            title: Text('${t('发现新版本', 'New version')} ${result.version}'),
            content: SizedBox(
              width: 650,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${t('当前版本', 'Current version')}: '
                      '${currentVersion.isEmpty ? '—' : currentVersion}',
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      result.notes.isEmpty
                          ? t('此发行版未提供更新日志', 'No release notes were supplied')
                          : result.notes,
                    ),
                    if (result.sha256.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      SelectableText(
                        'SHA-256: ${result.sha256}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      t(
                        '下载会在默认浏览器打开；镜像为第三方下载线路。',
                        'Downloads open in your default browser. Mirrors are third-party download routes.',
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => openBrowser(result.releaseUri),
                    child: Text(t('查看发行版', 'Release page')),
                  ),
                  OutlinedButton(
                    onPressed: () => openBrowser(result.downloadUri(0)),
                    child: Text(t('GitHub 下载', 'GitHub download')),
                  ),
                  FilledButton(
                    onPressed: () => openBrowser(result.downloadUri(1)),
                    child: Text(t('镜像 1 下载', 'Mirror 1 download')),
                  ),
                  OutlinedButton(
                    onPressed: () => openBrowser(result.downloadUri(2)),
                    child: Text(t('镜像 2 下载', 'Mirror 2 download')),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(t('稍后再说', 'Later')),
                  ),
                ],
              ),
            ],
          ),
        );
      } else if (!automatic) {
        note(t('当前已是最新正式版', 'You are running the latest stable release'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => updateFailed = true);
        if (!automatic) {
          note(
            t(
              '更新检查失败，已尝试 GitHub 和两条镜像线路，请稍后重试',
              'GitHub and both mirror update sources failed; please try again later',
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => checkingUpdates = false);
    }
  }

  Future<void> runDiagnostics() async {
    final report = await action('diagnose');
    if (report is! Map || !mounted) return;
    await showDialog<void>(
      context: navigator.currentContext!,
      builder: (context) => AlertDialog(
        title: Text(t('诊断结果', 'Diagnostic results')),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final check in report['checks'] as List)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          check['status'] == 'error'
                              ? Icons.error_outline
                              : check['status'] == 'ok'
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                          color: check['status'] == 'error'
                              ? Colors.red
                              : accent,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(check['detail'].toString())),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('关闭', 'Close')),
          ),
        ],
      ),
    );
  }

  Future<void> exportDiagnostics() async {
    final file = await getSaveLocation(
      suggestedName:
          'CPV-diagnostics-${DateTime.now().millisecondsSinceEpoch}.json',
    );
    if (file == null) return;
    await Diagnostics.flush();
    if (await action('export_diagnostics', {
          'path': file.path,
          'client': {
            'operating_system': Platform.operatingSystemVersion,
            'language': en ? 'en' : 'zh',
            'theme': settings['theme'],
            'material': settings['material'],
          },
        }) ==
        true) {
      note(t('诊断日志已导出', 'Diagnostic log exported'));
    }
  }

  Widget inventoryPage() => _InventoryPage(
    core: widget.core,
    english: en,
    proxyState: state,
    surface: (child) => glass(child),
  );

  Widget settingsPage() => ListView(
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      heading(
        t('你的空间，你的风格。', 'A space that feels like you.'),
        t(
          '调整立即生效，并在下次启动时保留。',
          'Changes apply immediately and persist across launches.',
        ),
        [],
      ),
      const SizedBox(height: 24),
      glass(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('外观', 'Appearance'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 18),
            settingRow(
              t('颜色模式', 'Color mode'),
              t('浅色、深色或跟随系统', 'Light, dark or follow the system'),
              DropdownButton<String>(
                value: settings['theme'] ?? 'light',
                items: [
                  for (final v in ['light', 'dark', 'system'])
                    DropdownMenuItem(
                      value: v,
                      child: Text(
                        v == 'light'
                            ? t('浅色', 'Light')
                            : v == 'dark'
                            ? t('深色', 'Dark')
                            : t('跟随系统', 'System'),
                      ),
                    ),
                ],
                onChanged: (v) => setting({'theme': v}),
              ),
            ),
            const Divider(height: 32),
            settingRow(
              t('主题颜色', 'Theme color'),
              t('改变按钮和选中项的颜色', 'Changes the color of buttons and selections'),
              Wrap(
                spacing: 10,
                children: [
                  for (int i = 0; i < 4; i++)
                    InkWell(
                      onTap: () => setting({'accent': i}),
                      borderRadius: BorderRadius.circular(30),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: [
                            const Color(0xff8270b2),
                            const Color(0xff6d9a8b),
                            const Color(0xffb28e73),
                            const Color(0xff7897c1),
                          ][i],
                        ),
                        child: settings['accent'] == i
                            ? const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 18,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 32),
            settingRow(
              t('自定义背景', 'Custom background'),
              t(
                '使用本地图片作为背景，玻璃卡片也会使用这张图。',
                'Use a local image for the workspace and glass cards.',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: loadingBackground ? null : chooseBackground,
                    icon: const Icon(Icons.image_outlined),
                    label: Text(t('选择图片', 'Choose image')),
                  ),
                  TextButton(
                    onPressed:
                        loadingBackground || settings['backgroundImage'] == null
                        ? null
                        : () => loadBackground(null, save: true),
                    child: Text(t('恢复默认', 'Restore default')),
                  ),
                ],
              ),
            ),
            const Divider(height: 32),
            settingRow(
              t('语言', 'Language'),
              t('同时支持中英文名称搜索', 'Search names in either language'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'zh', label: Text('中文')),
                  ButtonSegment(value: 'en', label: Text('English')),
                ],
                selected: {en ? 'en' : 'zh'},
                onSelectionChanged: (v) => setting({'language': v.first}),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      glass(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('卡片样式', 'Card style'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              t(
                '选择卡片的背景效果。磨砂会模糊背景，液态玻璃带有折射，实色更清晰。',
                'Frosted cards blur the background, liquid glass adds refraction, and solid cards improve contrast.',
              ),
            ),
            const SizedBox(height: 20),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'frosted',
                  icon: const Icon(Icons.blur_on),
                  label: Text(t('磨砂', 'Frosted')),
                ),
                ButtonSegment(
                  value: 'liquid',
                  icon: const Icon(Icons.water_drop_outlined),
                  label: Text(t('液态玻璃', 'Liquid')),
                ),
                ButtonSegment(
                  value: 'solid',
                  icon: const Icon(Icons.rectangle_outlined),
                  label: Text(t('实色', 'Solid')),
                ),
              ],
              selected: {settings['material'] ?? 'frosted'},
              onSelectionChanged: (v) => setting({'material': v.first}),
            ),
            const SizedBox(height: 24),
            Text(t('磨砂卡片遮挡背景的程度', 'Frosted background coverage')),
            Slider(
              value: (settings['opacity'] as num? ?? .76).toDouble(),
              min: .2,
              max: 1,
              divisions: 80,
              label: '${((settings['opacity'] as num? ?? .76) * 100).round()}%',
              onChanged: (settings['material'] ?? 'frosted') == 'frosted'
                  ? (v) => setting({'opacity': v})
                  : null,
            ),
            Text(
              t(
                '向左可看见更多背景，向右文字更清楚。这个滑条用于磨砂样式。',
                'Move left to reveal the background or right to improve text contrast. Applies to frosted cards.',
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      glass(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('诊断与日志', 'Diagnostics & logs'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            settingRow(
              t('详细记录问题', 'Record troubleshooting details'),
              t(
                '记录启动、操作耗时与异常，便于排查卡顿或无法启动。',
                'Records startup, operation timing and errors for troubleshooting.',
              ),
              Switch(
                value: settings['diagnostics'] == true,
                onChanged: (v) => setting({'diagnostics': v}),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              t(
                '检查配置目录、程序文件完整性、证书与代理状态；不会自动启动代理或修改系统设置。日志不含账号、认证信息、请求正文、证书私钥或截图。',
                'Checks profile access, application files, certificate and proxy status without starting the proxy or changing system settings. Logs exclude account data, credentials, request bodies, private keys and screenshots.',
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: working ? null : runDiagnostics,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text(t('运行诊断', 'Run diagnostics')),
                ),
                OutlinedButton.icon(
                  onPressed: working ? null : exportDiagnostics,
                  icon: const Icon(Icons.download),
                  label: Text(t('导出诊断日志', 'Export diagnostic log')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              t(
                '窗口无法打开时，可使用 --diagnostic 启动；启动错误始终记录。',
                'If the window fails to open, launch with --diagnostic. Startup errors are always recorded.',
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      glass(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('关于', 'About'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              '$title${currentVersion.isEmpty ? '' : ' · $currentVersion'}\n'
              'Rust + Flutter · Morrow glass components\nAGPL-3.0-only',
            ),
            const SizedBox(height: 14),
            Text('${t('作者', 'Author')}: 127MU'),
            const SizedBox(height: 8),
            SelectableText(projectUri.toString()),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                OutlinedButton(
                  onPressed: () => openBrowser(projectUri),
                  child: Text(t('打开项目仓库', 'Open repository')),
                ),
                FilledButton.icon(
                  onPressed: checkingUpdates ? null : () => checkForUpdates(),
                  icon: const Icon(Icons.download),
                  label: Text(
                    checkingUpdates
                        ? t('正在检查更新…', 'Checking…')
                        : t('检查更新', 'Check for updates'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              t(
                '每次启动自动检查；GitHub 无法访问时自动尝试两条镜像线路。',
                'Checks at every launch and tries two mirror routes when GitHub cannot be reached.',
              ),
              style: const TextStyle(fontSize: 12),
            ),
            if (updateFailed)
              Text(
                t(
                  '本次更新检查未成功，可点击重试。',
                  'The last update check failed; you can retry.',
                ),
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
      ),
    ],
  );
  Widget settingRow(String title, String subtitle, Widget control) =>
      LayoutBuilder(
        builder: (context, c) => Wrap(
          spacing: 24,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: math.max(160, c.maxWidth - 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 5),
                  Text(subtitle, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            control,
          ],
        ),
      );
}

class _InventoryPage extends StatefulWidget {
  const _InventoryPage({
    required this.core,
    required this.english,
    required this.proxyState,
    required this.surface,
  });

  final CpvApi core;
  final bool english;
  final Json proxyState;
  final Widget Function(Widget) surface;

  @override
  State<_InventoryPage> createState() => _InventoryPageState();
}

enum _ArmoryCatalogKind { weapon, attachment, stratagem }

class _InventoryPageState extends State<_InventoryPage> {
  final add = TextEditingController();
  final customization = TextEditingController();
  List<Json> weapons = [], attachments = [], attachmentChanges = [];
  List<Json> stratagems = [];
  Set<int> previewCategories = {};
  Set<int> attachmentUnlockWeapons = {};
  Set<int> weaponsWithAttachmentLicenses = {};
  bool enabled = false, busy = true, loaded = false;
  bool unlockAllWeapons = false;
  bool unlockAllStratagems = false;
  String? message;
  String t(String zh, String en) => widget.english ? en : zh;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final results = await Future.wait([
        widget.core.call('inventory_preview'),
        rootBundle.loadString('assets/armory_catalog.json'),
      ]);
      final plan = Json.from(results[0]);
      final catalog = Json.from(jsonDecode(results[1] as String));
      if (!mounted) return;
      add.text = (plan['items'] as List).map((row) => row['mixId']).join(', ');
      final overrides = plan['customization'] as List;
      customization.text = overrides.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(overrides);
      setState(() {
        weapons = _CpvAppState.rows(catalog['weapons']);
        attachments = _CpvAppState.rows(catalog['attachments']);
        stratagems = _CpvAppState.rows(catalog['stratagems']);
        previewCategories = (plan['previewCategories'] as List? ?? [])
            .cast<int>()
            .toSet();
        attachmentUnlockWeapons =
            (plan['attachmentUnlockWeapons'] as List? ?? [])
                .cast<int>()
                .toSet();
        weaponsWithAttachmentLicenses =
            (catalog['attachmentUnlockIds'] as Map<String, dynamic>).keys
                .map(int.parse)
                .toSet();
        attachmentChanges = _CpvAppState.rows(plan['attachmentChanges'] ?? []);
        enabled = plan['enabled'] == true;
        unlockAllWeapons = plan['unlockAllWeapons'] == true;
        unlockAllStratagems = plan['unlockAllStratagems'] == true;
        loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => message = t('无法读取军械库方案', 'Could not load the armory plan'),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String hexId(int value) =>
      '0x${value.toRadixString(16).toUpperCase().padLeft(8, '0')}';

  String weaponName(Json weapon) {
    final name =
        (widget.english ? weapon['name'] : weapon['zh'] ?? weapon['name'])
            as String;
    final code = weapon['code'] as String;
    final includesCode =
        code.isNotEmpty &&
        name.toLowerCase().startsWith(code.toLowerCase()) &&
        (name.length == code.length ||
            !RegExp(r'[a-zA-Z0-9]').hasMatch(name[code.length]));
    final label = [
      if (!includesCode) code,
      name,
    ].where((s) => s.isNotEmpty).join(' ');
    return label.isEmpty ? t('未命名武器', 'Unnamed weapon') : label;
  }

  String weaponKind(Json weapon) => switch (weapon['kind']) {
    'primary' => t('主武器', 'Primary'),
    'secondary' => t('副武器', 'Secondary'),
    'throwable' => t('投掷物', 'Throwable'),
    _ => t('支援武器', 'Support weapon'),
  };

  bool hasInventoryId(Json weapon) =>
      weapon['id'] != 0 && weapon['kind'] != 'support';

  String attachmentName(Json attachment) {
    if (attachment['id'] == 0) return t('空配件（占位）', 'Empty slot marker');
    final localized = attachment['zh'] as String?;
    if (!widget.english && localized != null && localized.isNotEmpty) {
      return localized;
    }
    final names = (attachment['names'] as List).cast<String>();
    return names.isEmpty ? t('未命名配件', 'Unnamed attachment') : names.join(' / ');
  }

  String slotName(int slot) => switch (slot) {
    1 => t('下挂', 'Underbarrel'),
    2 => t('瞄具', 'Optics'),
    3 => t('涂装', 'Paint'),
    4 => t('枪口', 'Muzzle'),
    5 => t('弹匣或散热器', 'Magazine or heatsink'),
    6 => t('弹种', 'Ammo type'),
    7 => t('备用弹种', 'Alternate ammo'),
    8 => t('内部组件', 'Internals'),
    9 => t('扳机', 'Trigger'),
    _ => t('未知槽位', 'Unknown slot'),
  };

  Future<List<Json>?> pickCatalog(
    String title,
    List<Json> rows, {
    required _ArmoryCatalogKind kind,
    Set<int>? checked,
  }) async {
    var query = '';
    return showDialog<List<Json>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          final filtered = <({Json item, String name, String detail})>[];
          for (final item in rows) {
            final name = switch (kind) {
              _ArmoryCatalogKind.weapon => weaponName(item),
              _ArmoryCatalogKind.attachment => attachmentName(item),
              _ArmoryCatalogKind.stratagem =>
                (widget.english ? item['name'] : item['zh'] ?? item['name'])
                    as String,
            };
            final id = item['id'] as int;
            final detail = switch (kind) {
              _ArmoryCatalogKind.weapon => [
                weaponKind(item),
                if (id != 0) hexId(id) else item['entity'],
                if (item['kind'] == 'support')
                  t('仅查看，需通过战略配备使用', 'Browse only. Use as a stratagem.')
                else if (!hasInventoryId(item))
                  t('仅查看，缺少库存 ID', 'Browse only. No inventory ID.'),
              ].join(' · '),
              _ArmoryCatalogKind.attachment => [
                hexId(id),
                ...(item['slots'] as List).cast<int>().map(slotName),
              ].join(' · '),
              _ArmoryCatalogKind.stratagem => t(
                '战备数据 ID ${hexId(id)}',
                'Stratagem data ID ${hexId(id)}',
              ),
            };
            final aliases = (item['names'] as List?)?.join(' ') ?? '';
            final searchable =
                '$name $detail $id ${item['name'] ?? ''} ${item['zh'] ?? ''} $aliases'
                    .toLowerCase();
            final compact = searchable.replaceAll(RegExp(r'\s+'), '');
            if (query
                .trim()
                .toLowerCase()
                .split(RegExp(r'\s+'))
                .every(
                  (word) => searchable.contains(word) || compact.contains(word),
                )) {
              filtered.add((item: item, name: name, detail: detail));
            }
          }
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 580,
              height: math.min(450.0, MediaQuery.sizeOf(context).height * .58),
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: t(
                        '搜索名称、型号、槽位或 ID',
                        'Search name, model, slot or ID',
                      ),
                    ),
                    onChanged: (value) => refresh(() => query = value),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(t('没有匹配条目', 'No matching entries')),
                          )
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final row = filtered[index];
                              if (checked != null) {
                                final id = row.item['id'] as int;
                                return CheckboxListTile(
                                  title: Text(row.name),
                                  subtitle: Text(row.detail),
                                  value: checked.contains(id),
                                  onChanged: !hasInventoryId(row.item)
                                      ? null
                                      : (value) => refresh(() {
                                          if (value == true) {
                                            checked.add(id);
                                          } else {
                                            checked.remove(id);
                                          }
                                        }),
                                );
                              }
                              return ListTile(
                                title: Text(row.name),
                                subtitle: Text(row.detail),
                                onTap: kind == _ArmoryCatalogKind.stratagem
                                    ? null
                                    : () => Navigator.pop(context, [row.item]),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  kind == _ArmoryCatalogKind.stratagem
                      ? t('关闭', 'Close')
                      : t('取消', 'Cancel'),
                ),
              ),
              if (checked != null)
                FilledButton(
                  onPressed: () => Navigator.pop(context, [
                    for (final id in checked) <String, dynamic>{'id': id},
                  ]),
                  child: Text(
                    t('确认选择（${checked.length}）', 'Apply (${checked.length})'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<Json?> pickOne(
    String title,
    List<Json> rows, {
    required _ArmoryCatalogKind kind,
  }) async => (await pickCatalog(title, rows, kind: kind))?.single;

  Future<void> chooseWeapon() async {
    try {
      final selection = await pickCatalog(
        t('选择武器或投掷物', 'Choose weapons or throwables'),
        weapons,
        kind: _ArmoryCatalogKind.weapon,
        checked: parseIds(add.text).toSet(),
      );
      if (!mounted || selection == null) return;
      setState(() {
        add.text = selection.map((row) => row['id']).join(', ');
        message = null;
      });
    } on FormatException catch (error) {
      setState(() => message = error.message);
    }
  }

  Future<void> browseAttachments() async {
    final attachment = await pickOne(
      t('配件目录', 'Attachment catalog'),
      attachments,
      kind: _ArmoryCatalogKind.attachment,
    );
    if (attachment == null || !mounted) return;
    final id = hexId(attachment['id'] as int);
    await Clipboard.setData(ClipboardData(text: id));
    if (mounted) {
      setState(
        () => message =
            '${attachmentName(attachment)} · $id · ${t('已复制 ID', 'ID copied')}',
      );
    }
  }

  Future<void> chooseAttachmentWeapons() async {
    final selection = await pickCatalog(
      t('选择要解锁配件的武器', 'Choose weapons to unlock attachments for'),
      weapons
          .where((item) => weaponsWithAttachmentLicenses.contains(item['id']))
          .toList(),
      kind: _ArmoryCatalogKind.weapon,
      checked: attachmentUnlockWeapons.toSet(),
    );
    if (!mounted || selection == null) return;
    setState(() {
      attachmentUnlockWeapons = selection
          .map((row) => row['id'] as int)
          .toSet();
      if (attachmentUnlockWeapons.isNotEmpty) enabled = true;
      message = null;
    });
  }

  Future<void> addAttachmentChange() async {
    final weapon = await pickOne(
      t('选择要改配件的武器', 'Choose weapon to customize'),
      weapons.where(hasInventoryId).toList(),
      kind: _ArmoryCatalogKind.weapon,
    );
    if (weapon == null || !mounted) return;
    final from = await pickOne(
      t('选择原有配件', 'Choose existing attachment'),
      attachments.where((item) => (item['slots'] as List).isNotEmpty).toList(),
      kind: _ArmoryCatalogKind.attachment,
    );
    if (from == null || !mounted) return;
    final slots = (from['slots'] as List).toSet();
    final candidates = attachments
        .where(
          (item) =>
              item['id'] != from['id'] &&
              (item['slots'] as List).any(slots.contains),
        )
        .toList();
    final to = await pickOne(
      t('选择同槽位的替换配件', 'Choose replacement in the same slot'),
      candidates,
      kind: _ArmoryCatalogKind.attachment,
    );
    if (to == null || !mounted) return;
    setState(() {
      attachmentChanges.removeWhere(
        (rule) => rule['weapon'] == weapon['id'] && rule['from'] == from['id'],
      );
      attachmentChanges.add({
        'weapon': weapon['id'],
        'from': from['id'],
        'to': to['id'],
      });
      message = null;
    });
  }

  String catalogLabel(List<Json> rows, int id, String Function(Json) name) {
    for (final row in rows) {
      if (row['id'] == id) return name(row);
    }
    return hexId(id);
  }

  String selectedWeapons(String text) {
    try {
      return parseIds(
        text,
      ).map((id) => catalogLabel(weapons, id, weaponName)).join(t('、', ', '));
    } on FormatException {
      return '';
    }
  }

  List<int> parseIds(String input) {
    final ids = <int>{};
    for (final value
        in input.split(RegExp(r'[\s,，]+')).where((v) => v.isNotEmpty)) {
      final id = int.tryParse(value);
      if (id == null || id < 1 || id > 0xffffffff) {
        throw FormatException(t('无效的物品 ID', 'Invalid item ID'));
      }
      ids.add(id);
    }
    return ids.toList();
  }

  String inventoryStatus() {
    if (widget.proxyState['ready'] != true) {
      return t(
        '代理尚未就绪，请先在连接页启动代理。',
        'Start the proxy on the Connection page first.',
      );
    }
    final report = (widget.proxyState['health'] as Map?)?['inventory'] as Map?;
    final added = report?['added'] ?? 0;
    return switch (report?['status']) {
      'applied' => t(
        '最近一次库存响应已改写，新增 $added 项。',
        'Latest inventory response: $added added.',
      ),
      'unchanged' => t(
        '游戏已读取库存，这次响应没有变化。',
        'The game fetched inventory. This response was unchanged.',
      ),
      'unsupported_response' => t(
        '游戏返回的库存格式不兼容，响应保持原样。',
        'The inventory response format was unsupported.',
      ),
      'http_error' => t(
        '最近一次库存请求返回 HTTP ${report?['http_status']}。',
        'Latest inventory request returned HTTP ${report?['http_status']}.',
      ),
      'missing_plan' || 'invalid_plan' || 'disabled' => t(
        '上次读取时没有可用的已启用方案。',
        'No enabled, valid plan was available on the last request.',
      ),
      _ => t(
        '本次连接还未收到库存响应。保存方案后，请完全退出游戏，再通过 Steam 启动。',
        'No inventory response yet. Save the plan, exit the game completely, then start it via Steam.',
      ),
    };
  }

  String itemCatalogStatus() {
    final report =
        (widget.proxyState['health'] as Map?)?['item_catalog'] as Map?;
    final added = report?['added'] ?? 0;
    final missing = report?['missing_templates'] ?? 0;
    return switch (report?['status']) {
      'applied' =>
        missing == 0
            ? t('物品目录已补入 $added 项。', 'Added $added items to the item catalog.')
            : t(
                '物品目录已补入 $added 项，另有 $missing 项缺少模板。',
                'Added $added items to the item catalog. No template for $missing items.',
              ),
      'missing_template' => t(
        '物品目录中找不到 $missing 项所需的同类模板。',
        'No matching item catalog template for $missing items.',
      ),
      'unsupported_response' => t(
        '游戏返回的物品目录格式不兼容。',
        'The item catalog response format was unsupported.',
      ),
      'http_error' => t(
        '物品目录请求返回 HTTP ${report?['http_status']}。',
        'Item catalog request returned HTTP ${report?['http_status']}.',
      ),
      'waiting' || null => t(
        '等待游戏读取物品目录。',
        'Waiting for the game to fetch the item catalog.',
      ),
      _ => t(
        '最近一次物品目录响应保持原样。',
        'The latest item catalog response was unchanged.',
      ),
    };
  }

  Future<void> save({bool disable = false}) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final plan = disable
          ? Json.from(await widget.core.call('inventory_preview'))
          : <String, dynamic>{
              'enabled': enabled,
              'unlockAllWeapons': unlockAllWeapons,
              if (unlockAllStratagems) 'unlockAllStratagems': true,
              if (previewCategories.isNotEmpty)
                'previewCategories': previewCategories.toList()..sort(),
              if (attachmentUnlockWeapons.isNotEmpty)
                'attachmentUnlockWeapons': attachmentUnlockWeapons.toList()
                  ..sort(),
              'items': [
                for (final id in parseIds(add.text))
                  {'mixId': id, 'amount': 1, 'isDiscovered': false},
              ],
              'customization': customization.text.trim().isEmpty
                  ? []
                  : jsonDecode(customization.text),
              if (attachmentChanges.isNotEmpty)
                'attachmentChanges': attachmentChanges,
            };
      if (disable) plan['enabled'] = false;
      await widget.core.call('inventory_preview', plan);
      if (!mounted) return;
      setState(() {
        if (disable) enabled = false;
        message = t(
          '已保存。游戏下次读取库存时生效。',
          'Saved. Applies the next time the game requests inventory.',
        );
      });
    } catch (error) {
      if (mounted) setState(() => message = Diagnostics.safe(error.toString()));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    add.dispose();
    customization.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.only(bottom: 20),
    children: [
      Text(
        t('军械库', 'Armory'),
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 14),
      widget.surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                t('本地库存预览（实验性）', 'Local inventory preview (experimental)'),
              ),
              subtitle: Text(
                t(
                  '需要开启连接页的代理。保存后在游戏下次读取库存时应用。',
                  'Start the proxy on the Connection page. Changes apply on the next inventory request.',
                ),
              ),
              value: enabled,
              onChanged: busy || !loaded
                  ? null
                  : (value) => setState(() => enabled = value),
            ),
            Text(
              t(
                '预览只影响本机军械库，物品可见性和装备结果取决于游戏。',
                'Preview changes the local armory view. Visibility and equipping depend on the game.',
              ),
            ),
            const SizedBox(height: 8),
            Text(inventoryStatus()),
            if (enabled && widget.proxyState['ready'] == true)
              Text(itemCatalogStatus()),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                t('解锁所有武器（本地预览）', 'Unlock all weapons (local preview)'),
              ),
              subtitle: Text(
                t(
                  '批量预览主武器、副武器和投掷物。未发布和未命名条目属于实验性预览。支援武器需通过战略配备使用。',
                  'Preview primary weapons, secondary weapons and throwables. Unreleased and unnamed entries are experimental. Support weapons are used as stratagems.',
                ),
              ),
              value: unlockAllWeapons,
              onChanged: busy || !loaded
                  ? null
                  : (value) => setState(() {
                      unlockAllWeapons = value;
                      if (value) enabled = true;
                    }),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                t('解锁所有战备（本地预览）', 'Unlock all stratagems (local preview)'),
              ),
              subtitle: Text(
                t(
                  '保存后，游戏重新读取库存时会补齐物品目录中的战备许可。战备能否装备由游戏决定。',
                  'After saving, the next inventory refresh previews licenses from the item catalog. The game determines which stratagems can be equipped.',
                ),
              ),
              value: unlockAllStratagems,
              onChanged: busy || !loaded
                  ? null
                  : (value) => setState(() {
                      unlockAllStratagems = value;
                      if (value) enabled = true;
                    }),
              secondary: OutlinedButton(
                onPressed: !loaded || busy
                    ? null
                    : () => pickCatalog(
                        t('战备目录', 'Stratagem catalog'),
                        stratagems,
                        kind: _ArmoryCatalogKind.stratagem,
                      ),
                child: Text(t('浏览战备', 'Browse stratagems')),
              ),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(t('更多解锁选项', 'More unlock options')),
              children: [
                for (final (category, zh, en) in const [
                  (2, '全部武器配件', 'All weapon attachments'),
                  (3, '商店外观（护甲、头盔和披风）', 'Store armor, helmets and capes'),
                  (4, '载具涂装', 'Vehicle patterns'),
                  (5, '强化增益', 'Boosters'),
                  (7, '动作与表情', 'Emotes'),
                  (8, '胜利姿势', 'Victory poses'),
                  (
                    0,
                    '战团入口（内容仍需奖章购买）',
                    'Warbond access (contents still cost medals)',
                  ),
                  (9, '横幅（实验性）', 'Banners (experimental)'),
                  (23, '称号（实验性）', 'Titles (experimental)'),
                ])
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t(zh, en)),
                    value: previewCategories.contains(category),
                    onChanged: busy || !loaded
                        ? null
                        : (value) => setState(() {
                            if (value) {
                              previewCategories.add(category);
                              enabled = true;
                            } else {
                              previewCategories.remove(category);
                            }
                          }),
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('按武器解锁配件', 'Unlock attachments by weapon')),
                  subtitle: Text(
                    previewCategories.contains(2)
                        ? t('已开启全部武器配件。', 'All weapon attachments are enabled.')
                        : t(
                            '已选 ${attachmentUnlockWeapons.length} 件武器。仅预览物品目录里已有的配件。',
                            '${attachmentUnlockWeapons.length} weapons selected. Uses attachments from the item catalog.',
                          ),
                  ),
                  trailing: OutlinedButton(
                    onPressed: busy || !loaded || previewCategories.contains(2)
                        ? null
                        : chooseAttachmentWeapons,
                    child: Text(t('选择武器', 'Choose weapons')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: add,
              enabled: loaded && !busy,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t('预览拥有的物品 ID', 'Preview item IDs'),
                hintText: t(
                  '逗号或空格分隔，可输入 0x 十六进制',
                  'Comma or space separated. 0x hex accepted.',
                ),
                suffixIcon: TextButton(
                  onPressed: loaded && !busy ? chooseWeapon : null,
                  child: Text(t('选武器', 'Pick weapon')),
                ),
              ),
            ),
            if (selectedWeapons(add.text).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(selectedWeapons(add.text)),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: loaded && !busy ? browseAttachments : null,
                  child: Text(t('浏览配件', 'Browse attachments')),
                ),
                OutlinedButton(
                  onPressed: loaded && !busy ? addAttachmentChange : null,
                  child: Text(t('添加配件替换', 'Add attachment replacement')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              t(
                '替换仅在该武器已有的配件方案中找到原配件时生效。同槽位的配件也可能不兼容。',
                'A replacement applies only to presets containing the selected attachment. Items in the same slot may still be incompatible.',
              ),
            ),
            for (final (index, rule) in attachmentChanges.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(catalogLabel(weapons, rule['weapon'], weaponName)),
                subtitle: Text(
                  '${catalogLabel(attachments, rule['from'], attachmentName)} → '
                  '${catalogLabel(attachments, rule['to'], attachmentName)}',
                ),
                trailing: IconButton(
                  tooltip: t('移除这项替换', 'Remove this replacement'),
                  onPressed: busy
                      ? null
                      : () => setState(() => attachmentChanges.removeAt(index)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(t('配件预览（高级）', 'Customization preview (advanced)')),
              children: [
                TextField(
                  controller: customization,
                  enabled: loaded && !busy,
                  minLines: 3,
                  maxLines: 8,
                  decoration: InputDecoration(
                    labelText: t('配件 JSON 数组', 'Customization JSON array'),
                    helperText:
                        'mixId32, index, activeIndex, slots[8], modes[4]',
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: busy || !loaded ? null : () => save(),
                  child: Text(t('保存方案', 'Save plan')),
                ),
                OutlinedButton(
                  onPressed: busy || !loaded ? null : () => save(disable: true),
                  child: Text(t('关闭预览', 'Disable preview')),
                ),
              ],
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(message!),
              ),
          ],
        ),
      ),
    ],
  );
}

class PlanetPicker extends StatefulWidget {
  const PlanetPicker({
    super.key,
    required this.planets,
    required this.en,
    this.live,
  });
  final List<Json> planets;
  final ValueListenable<List<Json>>? live;
  final bool en;
  @override
  State<PlanetPicker> createState() => _PlanetPickerState();
}

class _PlanetPickerState extends State<PlanetPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) => widget.live == null
      ? picker(widget.planets)
      : ValueListenableBuilder(
          valueListenable: widget.live!,
          builder: (_, planets, _) => picker(planets),
        );

  Widget picker(List<Json> planets) {
    final rows = planets.where((p) => matches(p, query)).toList();
    return Dialog(
      child: SizedBox(
        width: 580,
        height: 620,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.en ? 'Choose a planet' : '选择星球',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                autofocus: true,
                onChanged: (v) => setState(() => query = v),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: widget.en ? 'Name / ID' : '名称 / ID',
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) => ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    title: Text(recordName(rows[i], widget.en)),
                    subtitle: Text('#${rows[i]['id']}'),
                    onTap: () => Navigator.pop(context, rows[i]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const groups = {
  'events': ['特殊作战', 'Special operations'],
  'enemies': ['敌人变种', 'Enemy variants'],
  'world': ['环境与路线', 'Environment & routes'],
  'facilities': ['星球设施', 'Planet facilities'],
  'tactical': ['空间站支援', 'Space station support'],
  'tags': ['地图标记', 'Map markers'],
  'stratagems': ['临时战备', 'Temporary stratagems'],
  'equipment': ['临时装备', 'Temporary equipment'],
  'variants': ['特殊战备（实验性）', 'Special stratagems (experimental)'],
  'combat': ['战斗加成与限制', 'Combat bonuses & limits'],
  'supplies': ['弹药与补给', 'Ammo & supplies'],
  'intel': ['情报与侦察', 'Intel'],
  'unknown': ['作用待确认', 'Unconfirmed effects'],
};

const groupHelp = {
  'events': [
    '特殊事件和事件作战相关的效果。',
    'Effects related to special events and operations.',
  ],
  'enemies': [
    '选择酸液、燃烧等敌人变种。',
    'Choose enemy variants such as acid and incendiary strains.',
  ],
  'world': [
    '星球环境和通行路线相关的效果。',
    'Effects related to the planet environment and routes.',
  ],
  'facilities': [
    '星球设施和它们在地图上的显示。',
    'Planet facilities and how they appear on the map.',
  ],
  'tactical': [
    '空间站支援和相关战术行动。',
    'Space station support and related tactical actions.',
  ],
  'tags': ['用于显示或配合敌人变种的地图标记。', 'Map markers displayed with enemy variants.'],
  'stratagems': [
    '在星球上临时提供指定战备，游戏内有数量限制。',
    'Temporarily grants stratagems on the planet. The game limits their number.',
  ],
  'equipment': [
    '在星球上临时提供装备的效果。',
    'Effects that temporarily provide equipment on the planet.',
  ],
  'variants': [
    '特殊战备的候选效果，游戏内表现需要验证。',
    'Candidate special stratagem effects that need in-game verification.',
  ],
  'combat': ['改变战斗中的加成、限制或惩罚。', 'Changes combat bonuses, limits or penalties.'],
  'supplies': ['影响弹药和补给的效果。', 'Effects that affect ammunition and supplies.'],
  'intel': ['影响情报显示和侦察的效果。', 'Effects that affect intelligence and scouting.'],
  'unknown': [
    '已发现条目，具体作用还需要确认。',
    'Discovered entries whose effects need confirmation.',
  ],
};

class EffectLibrary extends StatefulWidget {
  const EffectLibrary({
    super.key,
    required this.effects,
    required this.en,
    required this.selected,
    required this.onToggle,
    this.header,
  });
  final List<Json> effects;
  final bool en;
  final Set<int> selected;
  final void Function(int)? onToggle;
  final Widget? header;
  @override
  State<EffectLibrary> createState() => _EffectLibraryState();
}

class _EffectLibraryState extends State<EffectLibrary> {
  String query = '', group = 'all';
  bool onlySelected = false;
  @override
  Widget build(BuildContext context) {
    final rows = widget.effects
        .where(
          (e) =>
              matches(e, query) &&
              (group == 'all' || e['groupKey'] == group) &&
              (!onlySelected || widget.selected.contains(e['id'])),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.header != null) ...[
          widget.header!,
          const SizedBox(height: 20),
        ],
        TextField(
          onChanged: (v) => setState(() => query = v),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: widget.en
                ? 'Search effect, Chinese name or ID'
                : '搜索效果名称、英文名或 ID',
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 54,
          child: HorizontalCategoryBar(
            children: [
              for (final key in ['all', ...groups.keys])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Tooltip(
                    message: key == 'all'
                        ? (widget.en ? 'Browse all effects.' : '显示全部类别的效果。')
                        : groupHelp[key]![widget.en ? 1 : 0],
                    child: ChoiceChip(
                      label: Text(
                        key == 'all'
                            ? (widget.en ? 'All' : '全部')
                            : groups[key]![widget.en ? 1 : 0],
                      ),
                      selected: group == key,
                      onSelected: (_) => setState(() => group = key),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Row(
          children: [
            Text(
              '${rows.length} ${widget.en ? 'effects' : '项效果'}',
              style: const TextStyle(fontSize: 12),
            ),
            const Spacer(),
            if (widget.onToggle != null)
              FilterChip(
                label: Text(widget.en ? 'Selected only' : '仅显示已选'),
                selected: onlySelected,
                onSelected: (v) => setState(() => onlySelected = v),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final row = rows[i];
              final id = row['id'] as int;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: .76),
                  borderRadius: BorderRadius.circular(16),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 7,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    leading: widget.onToggle == null
                        ? const Icon(Icons.auto_awesome_outlined)
                        : Checkbox(
                            value: widget.selected.contains(id),
                            onChanged: (_) => widget.onToggle!(id),
                          ),
                    title: Text(
                      recordName(row, widget.en),
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      '#$id  ·  ${groups[row['groupKey']]?[widget.en ? 1 : 0] ?? row['groupKey']}${row['experimental'] == true ? '  ·  ${widget.en ? 'Experimental' : '实验性'}' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: widget.onToggle == null
                        ? () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(recordName(row, widget.en)),
                              content: SelectableText(
                                '#$id\n${row['description'] ?? row['reference_note'] ?? ''}\n\n${widget.en ? 'A catalog entry does not guarantee in-game compatibility.' : '目录候选不等于已验证可用。'}',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: Text(widget.en ? 'Close' : '关闭'),
                                ),
                              ],
                            ),
                          )
                        : () => widget.onToggle!(id),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class PlanetEditor extends StatefulWidget {
  const PlanetEditor({
    super.key,
    required this.target,
    required this.effects,
    required this.planets,
    required this.en,
    this.onSave,
  });
  final Json target;
  final List<Json> effects, planets;
  final bool en;
  final Future<void> Function(Json)? onSave;
  @override
  State<PlanetEditor> createState() => _PlanetEditorState();
}

class _PlanetEditorState extends State<PlanetEditor> {
  late Json draft;
  late Set<int> selected;
  int tab = 0;
  bool saving = false;
  String? saveError;
  String t(String zh, String en) => widget.en ? en : zh;
  @override
  void initState() {
    super.initState();
    draft = {...widget.target};
    selected = Set<int>.from(widget.target['effects']);
  }

  void toggle(int id) {
    if (!selected.contains(id) && selected.length >= 32) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('最多选择 32 个效果', 'Maximum 32 effects'))),
      );
      return;
    }
    setState(
      () => selected.contains(id) ? selected.remove(id) : selected.add(id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.planets.where((p) => p['id'] == draft['planet']);
    return Material(
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('星球方案', 'Planet plan'),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        p.isEmpty
                            ? '#${draft['planet']}'
                            : recordName(p.first, widget.en),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: t('放弃本次修改', 'Discard changes'),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text(t('效果', 'Effects'))),
                ButtonSegment(
                  value: 1,
                  label: Text(t('星球设置', 'Planet settings')),
                ),
                ButtonSegment(value: 2, label: Text(t('天气', 'Weather'))),
              ],
              selected: {tab},
              onSelectionChanged: (v) => setState(() => tab = v.first),
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: switch (tab) {
                0 => EffectLibrary(
                  effects: widget.effects,
                  en: widget.en,
                  selected: selected,
                  onToggle: toggle,
                ),
                1 => operations(),
                _ => weather(),
              },
            ),
          ),
          const Divider(height: 1),
          if (widget.effects
                  .where(
                    (e) => e['effectType'] == 32 && selected.contains(e['id']),
                  )
                  .length >
              1)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Text(
                t(
                  '游戏内的临时配发战备有数量限制，超出时可能无法正常使用。',
                  'The game limits temporary stratagems. Extra selections may not work in-game.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (saveError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                saveError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${selected.length} / 32  ${t('个效果', 'effects')}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: Text(t('取消', 'Cancel')),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: saving
                      ? null
                      : () async {
                          if (operationMode == 4 &&
                              (draft['defense_source'] as num? ?? -1) < 0) {
                            setState(
                              () => saveError = t(
                                '请选择发起进攻的星球。',
                                'Choose the planet launching the attack.',
                              ),
                            );
                            return;
                          }
                          draft['effects'] = selected.toList();
                          setState(() {
                            saving = true;
                            saveError = null;
                          });
                          try {
                            await widget.onSave?.call(draft);
                            if (context.mounted) Navigator.pop(context, draft);
                          } catch (e) {
                            if (mounted) {
                              setState(() {
                                saving = false;
                                saveError = e.toString();
                              });
                            }
                          }
                        },
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(t('保存方案', 'Save plan')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int get operationMode {
    final type = (draft['campaign_type'] as num? ?? 0).toInt();
    if (draft['campaign'] == true || draft['force_open'] == true || type == 4) {
      return [0, 3, 4].contains(type) ? type : -2;
    }
    return draft['initialize_regions'] == true ||
            draft['open_regions'] == true ||
            (draft['owner'] as num? ?? 0) != 0 ||
            (draft['campaign_race'] as num? ?? 0) != 0
        ? -2
        : -1;
  }

  void selectOperationMode(int value) {
    setState(() {
      draft['campaign'] = value != -1;
      draft['force_open'] = value != -1;
      draft['campaign_type'] = value == -1 ? 0 : value;
      draft['initialize_regions'] = false;
      draft['open_regions'] = value == 3;
      draft['campaign_count'] ??= 20;
      final race = (draft['campaign_race'] as num? ?? 0).toInt();
      draft['campaign_race'] = value == -1 || race < 2 ? 0 : race;
      draft['owner'] = draft['campaign_race'];
      if (value == 4) {
        draft['owner'] = 1;
        final enemies = widget.planets.where(
          (p) => p['id'] != draft['planet'] && [2, 3, 4].contains(p['owner']),
        );
        draft['campaign_race'] = race >= 2
            ? race
            : enemies.isEmpty
            ? 2
            : enemies.first['owner'];
        selectDefenseSource();
      }
    });
  }

  void selectDefenseSource() {
    final candidates = widget.planets.where(
      (p) => p['id'] != draft['planet'] && p['owner'] == draft['campaign_race'],
    );
    if (!candidates.any((p) => p['id'] == draft['defense_source'])) {
      draft['defense_source'] = candidates.isEmpty
          ? -1
          : candidates.first['id'];
    }
  }

  Widget operations() {
    final mode = operationMode;
    final race = (draft['campaign_race'] as num? ?? 0).toInt();
    final source = widget.planets.where(
      (p) => p['id'] == draft['defense_source'],
    );
    final sourceName = source.isNotEmpty
        ? recordName(source.first, widget.en)
        : (draft['defense_source'] as num? ?? -1) >= 0
        ? '#${draft['defense_source']}'
        : t('选择星球', 'Choose a planet');
    return ListView(
      key: const PageStorageKey('planet-operations'),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('启用方案', 'Enable plan')),
          subtitle: Text(
            t(
              '开启后应用这颗星球的作战和效果设置。关闭后暂停应用，已保存的设置会保留。',
              'Applies this planet’s operations and effects. Turn off to pause the plan while keeping its saved settings.',
            ),
          ),
          value: draft['enabled'] == true,
          onChanged: (v) => setState(() => draft['enabled'] = v),
        ),
        const SizedBox(height: 20),
        Text(
          t('作战类型', 'Operation type'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in [
              (-1, t('保持原样', 'Keep as is')),
              (0, t('普通作战', 'Standard operations')),
              (3, t('城市作战', 'City operations')),
              (4, t('防守作战（实验性）', 'Defense operations (experimental)')),
              if (mode == -2) (-2, t('保留已有设置', 'Keep saved settings')),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: mode == item.$1,
                onSelected: (selected) {
                  if (selected && item.$1 != -2) selectOperationMode(item.$1);
                },
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 20),
          child: Text(switch (mode) {
            -1 => t(
              '不改变游戏原本的作战安排。',
              'Leaves the game’s original operations unchanged.',
            ),
            3 => t(
              '尝试添加城市作战，并自动准备所需区域。没有可用城市区域时改用普通作战。',
              'Tries to add city operations and prepares the required areas. Uses standard operations if no city areas are available.',
            ),
            4 => t(
              '守卫这颗星球。选择敌人及其出发星球，其余选项通常不用改。此功能仍在验证中。',
              'Defend this planet. Choose the enemy and its source planet; other options usually need no changes. This feature is still being verified.',
            ),
            -2 => t(
              '保留原方案的设置。需要调整时展开“更多设置”。',
              'Keeps your saved settings. Open More settings to adjust them.',
            ),
            _ => t(
              '尝试让这颗星球可以游玩，自动添加作战并准备可用区域。一般选择这一项即可。',
              'Tries to make the planet playable by adding operations and preparing available areas. This is the usual choice.',
            ),
          }, style: Theme.of(context).textTheme.bodySmall),
        ),
        if (mode != -1) ...[
          Text(t('敌人', 'Enemy'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in [
                if (mode != 4 || race == 0) (0, t('自动选择', 'Automatic')),
                if (race == 1) (1, t('沿用旧设置', 'Keep legacy setting')),
                (2, t('终结族', 'Terminids')),
                (3, t('机器人', 'Automatons')),
                (4, t('光能族', 'Illuminate')),
              ])
                ChoiceChip(
                  label: Text(item.$2),
                  selected: race == item.$1,
                  onSelected: (selected) {
                    if (!selected) return;
                    setState(() {
                      draft['campaign_race'] = item.$1;
                      if (item.$1 < 2) draft['initialize_regions'] = false;
                      if (mode == 4) {
                        draft['owner'] = 1;
                        selectDefenseSource();
                      } else if (draft['force_open'] == true) {
                        draft['owner'] = item.$1;
                      }
                    });
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              race == 0
                  ? t(
                      '自动选择会沿用星球上的敌人；无法识别时使用终结族。',
                      'Automatic keeps the planet’s enemy, using Terminids if it cannot be identified.',
                    )
                  : t(
                      '设置这颗星球的作战中出现哪一方敌人。',
                      'Chooses the enemy faction for this planet’s operations.',
                    ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        if (mode == 4) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              final chosen = await showDialog<Json>(
                context: context,
                builder: (context) => PlanetPicker(
                  planets: widget.planets
                      .where((p) => p['id'] != draft['planet'])
                      .toList(),
                  en: widget.en,
                ),
              );
              if (chosen != null && mounted) {
                setState(() => draft['defense_source'] = chosen['id']);
              }
            },
            icon: const Icon(Icons.public),
            label: Text('${t('敌人从哪来', 'Enemy source planet')} · $sourceName'),
          ),
          Text(
            t(
              '敌人从这颗星球发起进攻。请选择由上方所选敌人控制的星球。',
              'The enemy attacks from this planet. Choose a planet controlled by the enemy selected above.',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 20),
        advancedOperations(),
        const SizedBox(height: 24),
        Text(
          t(
            '点击“保存方案”后生效。如果地图没有变化，请退出星图再打开，等待战况刷新。',
            'Save the plan to apply it. If the map does not change, close and reopen it and wait for war status to refresh.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget advancedOperations() => ExpansionTile(
    key: const PageStorageKey('planet-advanced-settings'),
    title: Text(t('更多设置', 'More settings')),
    subtitle: Text(
      t(
        '一般不用改；没有作战时可在这里调整',
        'Usually unchanged; adjust here if operations are missing',
      ),
    ),
    tilePadding: EdgeInsets.zero,
    children: [
      SwitchListTile(
        title: Text(t('开放星球', 'Open planet')),
        subtitle: Text(
          t(
            '开启后，尝试让没有作战的星球可以游玩，并自动添加作战。选择普通或城市作战时已自动开启。',
            'Tries to make a planet with no operations playable and adds operations automatically. Already enabled for standard and city operations.',
          ),
        ),
        value: draft['force_open'] == true,
        onChanged: (v) => setState(() => draft['force_open'] = v),
      ),
      select(
        'owner',
        t('谁控制星球', 'Who controls the planet'),
        [
          t('保留原样', 'Unchanged'),
          t('超级地球', 'Super Earth'),
          t('终结族', 'Terminids'),
          t('机器人', 'Automatons'),
          t('光能族', 'Illuminate'),
        ],
        hint: t(
          '选择超级地球或敌人控制这颗星球。“保留原样”不修改控制方。',
          'Choose Super Earth or an enemy to control the planet. Unchanged keeps its current owner.',
        ),
      ),
      const SizedBox(height: 16),
      SwitchListTile(
        title: Text(t('添加作战', 'Add operations')),
        subtitle: Text(
          draft['force_open'] == true
              ? t(
                  '已随“开放星球”开启。要单独关闭，请先关闭“开放星球”。',
                  'Enabled by Open planet. Turn that off first to disable this separately.',
                )
              : draft['campaign_type'] == 4
              ? t('防守作战需要开启此项。', 'Required for defense operations.')
              : t(
                  '开启后，星球没有作战时尝试添加作战入口。关闭后不再添加。',
                  'Adds an operation entry if the planet has none. Turn off to stop adding it.',
                ),
        ),
        value: draft['campaign'] == true || draft['force_open'] == true,
        onChanged: draft['force_open'] == true || draft['campaign_type'] == 4
            ? null
            : (v) => setState(() {
                draft['campaign'] = v;
                if (!v) draft['initialize_regions'] = false;
              }),
      ),
      select(
        'campaign_type',
        t('特殊作战', 'Special operations'),
        [
          t('普通解放', 'Standard liberation'),
          t('侦察战役', 'Recon campaign'),
          t('高优先级战役', 'High-priority campaign'),
          t('城市作战', 'City operations'),
          t('防守（实验性）', 'Defense (experimental)'),
        ],
        hint: t(
          '需要侦察或高优先级作战时再改。不确定时选普通解放。',
          'Change only if you want recon or high-priority operations. Otherwise use standard liberation.',
        ),
      ),
      if (draft['campaign'] == true || draft['force_open'] == true)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: TextFormField(
            // Text fields have an internal scroll position. Keep it separate
            // from the ExpansionTile's boolean state in PageStorage.
            key: const PageStorageKey('planet-operation-count'),
            initialValue: '${draft['campaign_count'] ?? 20}',
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t('可选作战数', 'Operation count'),
              helperText: t(
                '默认 20。决定地图上预留多少个作战位置。',
                'Default 20. Sets how many operation slots are reserved on the map.',
              ),
              helperMaxLines: 3,
            ),
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null) draft['campaign_count'] = n;
            },
          ),
        ),
      const SizedBox(height: 16),
      SwitchListTile(
        title: Text(t('开放区域', 'Open areas')),
        subtitle: Text(
          t(
            '开启后，让地图上已有、且未被摧毁的区域可以选择。不会添加新区域。',
            'Makes existing, undestroyed areas selectable. Does not add new areas.',
          ),
        ),
        value: draft['open_regions'] == true,
        onChanged: (v) => setState(() => draft['open_regions'] = v),
      ),
      SwitchListTile(
        title: Text(t('补齐区域', 'Add missing areas')),
        subtitle: Text(
          t(
            '开启后，按游戏资料补回地图缺少的区域。需先开启“添加作战”，并手动选择一种敌人。',
            'Restores missing map areas from game data. Enable Add operations and choose a specific enemy first.',
          ),
        ),
        value: draft['initialize_regions'] == true,
        onChanged:
            (draft['campaign_race'] as num? ?? 0) >= 2 &&
                (draft['campaign'] == true || draft['force_open'] == true)
            ? (v) => setState(() => draft['initialize_regions'] = v)
            : null,
      ),
      if (draft['campaign_type'] == 4) ...[
        const Divider(height: 28),
        Text(
          t('防守设置', 'Defense settings'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        for (final field in [
          (
            'defense_level',
            t('防守强度', 'Defense strength'),
            20,
            t(
              '通过调整星球总生命值，改变完成防守所需的总进度。数值越大，需要的进度越多。',
              'Changes the planet’s total defense health. Higher values require more overall progress to finish the defense.',
            ),
          ),
          (
            'defense_hours',
            t('防守时长（小时）', 'Defense time (hours)'),
            48,
            t('这场星球防守持续多长时间。', 'How long the planet defense lasts.'),
          ),
          (
            'defense_count',
            t('防守作战数', 'Defense operation count'),
            38,
            t(
              '这场防守可提供的作战数量。',
              'Number of operations available during the defense.',
            ),
          ),
        ])
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TextFormField(
              key: PageStorageKey('planet-${field.$1}'),
              initialValue: '${draft[field.$1] ?? field.$3}',
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: field.$2,
                helperText: field.$4,
                helperMaxLines: 3,
              ),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null) draft[field.$1] = n;
              },
            ),
          ),
      ],
      const SizedBox(height: 24),
    ],
  );
  Widget select(
    String key,
    String label,
    List<String> labels, {
    String? hint,
  }) => DropdownButtonFormField<int>(
    key: ValueKey('$key-${draft[key]}'),
    initialValue: (draft[key] as num? ?? 0).toInt(),
    decoration: InputDecoration(
      labelText: label,
      helperText: hint,
      helperMaxLines: 3,
    ),
    isExpanded: true,
    menuMaxHeight: 320,
    items: [
      for (int i = 0; i < labels.length; i++)
        DropdownMenuItem(
          value: i,
          child: Text(labels[i], overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) {
      if (v == null) return;
      if (key == 'campaign_type') {
        selectOperationMode(v);
      } else {
        setState(() => draft[key] = v);
      }
    },
  );
  Widget weather() {
    final current = selected.intersection({1373, 1374, 1375});
    final value = current.isEmpty ? 0 : current.first;
    return ListView(
      children: [
        Text(
          t('异界风暴', 'Exostorm'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text(
          t(
            '预设同时影响天气与事件作战；II、III 仍为实验性。',
            'These presets affect weather and event operations. II and III remain experimental.',
          ),
        ),
        const SizedBox(height: 22),
        for (final item in [
          (0, t('不指定', 'Unspecified')),
          (1373, t('一级异界风暴', 'Exostorm I')),
          (1374, t('二级异界风暴 · 实验性', 'Exostorm II · Experimental')),
          (1375, t('三级异界风暴 · 实验性', 'Exostorm III · Experimental')),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              tileColor: value == item.$1
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              leading: Icon(
                value == item.$1
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(item.$2),
              onTap: () {
                final next = {...selected}..removeAll({1373, 1374, 1375});
                if (item.$1 != 0) next.add(item.$1);
                if (next.length <= 32) setState(() => selected = next);
              },
            ),
          ),
        const SizedBox(height: 20),
        Text(
          t(
            '白天、傍晚、夜晚：控制字段待实机确认，暂未开放无效开关。',
            'Day, dusk and night: control fields await in-game verification.',
          ),
        ),
      ],
    );
  }
}

/// Desktop-friendly category strip: drag anywhere, wheel, or drag the thumb.
class HorizontalCategoryBar extends StatefulWidget {
  const HorizontalCategoryBar({super.key, required this.children});
  final List<Widget> children;
  @override
  State<HorizontalCategoryBar> createState() => _HorizontalCategoryBarState();
}

class _HorizontalCategoryBarState extends State<HorizontalCategoryBar> {
  final controller = ScrollController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !controller.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final next = (controller.offset + delta)
        .clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        )
        .toDouble();
    if (next == controller.offset) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => controller.jumpTo(next),
    );
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: wheel,
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        scrollbars: false,
        dragDevices: {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      ),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        interactive: true,
        notificationPredicate: (event) => event.depth == 0,
        child: ListView(
          controller: controller,
          primary: false,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 10),
          children: widget.children,
        ),
      ),
    ),
  );
}

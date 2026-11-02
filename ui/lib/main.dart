import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'core.dart';
import 'diagnostics.dart';
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
  });
  final CpvApi core;
  final Json initial;
  final bool nativeWindow;
  @override
  State<CpvApp> createState() => _CpvAppState();
}

class _CpvAppState extends State<CpvApp>
    with WidgetsBindingObserver, WindowListener {
  late Json settings, state;
  late List<Json> targets, effects, planets;
  int page = 0;
  int settingsRevision = 0;
  bool working = false, polling = false;
  String query = '';
  Timer? timer, saveTimer;
  Future<void>? closing;
  bool destroyingWindow = false;
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
    if (widget.nativeWindow && Platform.isWindows) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
    settings = Json.from(widget.initial['settings']);
    Diagnostics.enabled = settings['diagnostics'] == true;
    state = Json.from(widget.initial['state']);
    targets = rows(widget.initial['targets']);
    effects = rows(widget.initial['catalog']['effects']);
    planets = rows(widget.initial['catalog']['planets']);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => poll());
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
            planets = rows(catalog['planets']);
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
      builder: (context) => PlanetPicker(planets: planets, en: en),
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
                'campaign_type': 0,
                'campaign_race': 0,
                'open_regions': false,
                'initialize_regions': false,
                'defense_source': -1,
                'defense_level': 20,
                'defense_hours': 48,
                'defense_count': 38,
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
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 960;
                  return Padding(
                    padding: EdgeInsets.all(wide ? 22 : 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: wide ? 216 : 78, child: sidebar(wide)),
                        SizedBox(width: wide ? 24 : 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              topbar(),
                              const SizedBox(height: 22),
                              Expanded(
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 220),
                                  child: KeyedSubtree(
                                    key: ValueKey(page),
                                    child: switch (page) {
                                      0 => plansPage(),
                                      1 => catalogPage(),
                                      2 => connectionPage(),
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
          ),
        ),
      ),
    );
  }

  Widget sidebar(bool wide) {
    final labels = [
      t('星球方案', 'Planet plans'),
      t('效果目录', 'Effect library'),
      t('连接', 'Connection'),
      t('设置', 'Settings'),
    ];
    final icons = [
      Icons.dashboard_outlined,
      Icons.auto_awesome_mosaic_outlined,
      Icons.cable_rounded,
      Icons.tune_rounded,
    ];
    return glass(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Image.asset('assets/cpv.png', width: wide ? 42 : 36, height: 42),
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
          if (wide) ...[
            const SizedBox(height: 12),

            const SizedBox(height: 6),
            const Text(
              '2.0.0-preview.3',
              style: TextStyle(fontSize: 10, letterSpacing: 1.8),
            ),
          ],
          const SizedBox(height: 34),
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Tooltip(
                message: labels[i],
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
            '${t('工作台', 'Workspace')}  /  ${[t('星球方案', 'Planet plans'), t('效果目录', 'Effect library'), t('连接', 'Connection'), t('设置', 'Settings')][page]}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
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
  Widget windowDrag(Widget child) => widget.nativeWindow && Platform.isWindows
      ? DragToMoveArea(
          child: SizedBox(
            height: 36,
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
    final operation = target['campaign'] == true
        ? t('自定义作战', 'Custom operations')
        : t('原始作战', 'Original operations');
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
      t('效果目录', 'Effect library'),
      t(
        '按类型查找；中英文名称和 ID 都能搜索。',
        'Search by type, Chinese or English name, or ID.',
      ),
      [],
    ),
  );
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
              title: Text(
                t(
                  '游戏 API 经现有 HTTP 代理转发',
                  'Forward game API through the existing HTTP proxy',
                ),
              ),
              subtitle: Text(
                t(
                  '仅在停止代理时切换；不会修改系统代理。',
                  'Change while stopped. System proxy settings remain untouched.',
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
                              '将此代理的 CA 加入当前用户信任库，用于必要游戏 API 的 HTTPS 解密。',
                              'Adds this proxy CA to the current user trust store for the required game API.',
                            ),
                          )) {
                            await action('install_certificate');
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
              t('强调色', 'Accent color'),
              t('按钮、选中项与焦点颜色', 'Buttons, selections and focus'),
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
              t('玻璃材质', 'Glass material'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              t(
                '使用 Morrow 的原生玻璃表面与光学效果。',
                'Uses Morrow’s glass surface and optical effects.',
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
            Text(t('磨砂不透明度', 'Frosted opacity')),
            Slider(
              value: (settings['opacity'] as num? ?? .76).toDouble(),
              min: .2,
              max: 1,
              divisions: 80,
              label: '${((settings['opacity'] as num? ?? .76) * 100).round()}%',
              onChanged: (v) => setting({'opacity': v}),
            ),
            Text(
              t(
                '低值更通透，高值更容易阅读；液态玻璃使用独立的折射与高光。',
                'Lower values reveal the background; higher values improve readability. Liquid glass uses its own refraction and rim light.',
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
              t('诊断模式', 'Diagnostic mode'),
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
              '$title · 2.0.0-preview.3\nRust + Flutter · Morrow glass components\nAGPL-3.0-only',
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

class PlanetPicker extends StatefulWidget {
  const PlanetPicker({super.key, required this.planets, required this.en});
  final List<Json> planets;
  final bool en;
  @override
  State<PlanetPicker> createState() => _PlanetPickerState();
}

class _PlanetPickerState extends State<PlanetPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final rows = widget.planets.where((p) => matches(p, query)).toList();
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
  'events': ['事件作战', 'Events'],
  'enemies': ['敌情与变种', 'Enemy variants'],
  'world': ['环境与通路', 'World & routes'],
  'facilities': ['设施与星球标记', 'Facilities'],
  'tactical': ['空间站与战术行动', 'Tactical actions'],
  'tags': ['配套星图词条', 'Map tags'],
  'stratagems': ['临时配发战备', 'Temporary stratagems'],
  'equipment': ['临时装备', 'Temporary equipment'],
  'variants': ['实验性战备变体', 'Experimental variants'],
  'combat': ['作战增减益', 'Combat modifiers'],
  'supplies': ['弹药与补给', 'Ammo & supplies'],
  'intel': ['情报与侦察', 'Intel'],
  'unknown': ['未解效果', 'Unresolved'],
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
                ButtonSegment(value: 1, label: Text(t('作战与分区', 'Operations'))),
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

  Widget operations() => ListView(
    children: [
      SwitchListTile(
        title: Text(t('启用此方案', 'Enable this plan')),
        value: draft['enabled'] == true,
        onChanged: (v) => setState(() => draft['enabled'] = v),
      ),
      select('owner', t('星球归属', 'Planet owner'), [
        t('保留原样', 'Unchanged'),
        t('超级地球', 'Super Earth'),
        t('终结族', 'Terminids'),
        t('机器人', 'Automatons'),
        t('光能族', 'Illuminate'),
      ]),
      const SizedBox(height: 16),
      SwitchListTile(
        title: Text(t('补齐可选作战', 'Populate operations')),
        subtitle: Text(
          t(
            '修改后需让游戏重新获取战况。',
            'The game must refresh war status after changes.',
          ),
        ),
        value: draft['campaign'] == true,
        onChanged: (v) => setState(() => draft['campaign'] = v),
      ),
      select('campaign_type', t('战役类型', 'Campaign type'), [
        t('常规解放', 'Standard liberation'),
        t('侦察战役', 'Recon campaign'),
        t('高优先级战役', 'High-priority campaign'),
        t('超级地球保卫战形态', 'Super Earth defense form'),
        t('防守（实验性）', 'Defense (experimental)'),
      ]),
      const SizedBox(height: 16),
      select('campaign_race', t('作战敌人', 'Enemy faction'), [
        t('保留原样', 'Unchanged'),
        t('超级地球（不可用于初始化）', 'Super Earth (not for initialization)'),
        t('终结族', 'Terminids'),
        t('机器人', 'Automatons'),
        t('光能族', 'Illuminate'),
      ]),
      const SizedBox(height: 16),
      SwitchListTile(
        title: Text(t('开放分区', 'Open regions')),
        value: draft['open_regions'] == true,
        onChanged: (v) => setState(() => draft['open_regions'] = v),
      ),
      SwitchListTile(
        title: Text(t('初始化缺失分区', 'Initialize missing regions')),
        subtitle: Text(
          t(
            '需要启用作战，并明确选择敌人阵营。',
            'Requires operations and an explicit enemy faction.',
          ),
        ),
        value: draft['initialize_regions'] == true,
        onChanged: (v) => setState(() => draft['initialize_regions'] = v),
      ),
      if (draft['campaign_type'] == 4) ...[
        const Divider(height: 28),
        Text(
          t('防守参数', 'Defense settings'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () async {
            final source = await showDialog<Json>(
              context: context,
              builder: (context) =>
                  PlanetPicker(planets: widget.planets, en: widget.en),
            );
            if (source != null) {
              setState(() => draft['defense_source'] = source['id']);
            }
          },
          child: Text(
            '${t('进攻来源', 'Source planet')}: ${draft['defense_source']}',
          ),
        ),
        for (final field in [
          ('defense_level', t('战役等级', 'Campaign level')),
          ('defense_hours', t('持续小时数', 'Duration (hours)')),
          ('defense_count', t('作战数量', 'Operation count')),
        ])
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TextFormField(
              initialValue: '${draft[field.$1]}',
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: field.$2),
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
  Widget select(String key, String label, List<String> labels) =>
      DropdownButtonFormField<int>(
        initialValue: (draft[key] as num? ?? 0).toInt(),
        decoration: InputDecoration(labelText: label),
        isExpanded: true,
        menuMaxHeight: 320,
        items: [
          for (int i = 0; i < labels.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(labels[i], overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() => draft[key] = v),
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

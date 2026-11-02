import 'package:cpv/main.dart';
import 'package:cpv/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide matches;
import 'dart:io';
import 'package:flutter/services.dart';

class FakeCore implements CpvApi {
  List<dynamic> targets = [];
  final Json settings = {
    'language': 'zh',
    'theme': 'light',
    'material': 'frosted',
    'opacity': .76,
    'accent': 0,
    'useSystemProxy': false,
  };
  final Json state = {'active': false, 'ready': false, 'status': 'Ready'};
  final Json catalog = {
    'planets': [
      {'id': 64, 'name': '生化斯坦', 'englishName': 'CYBERSTAN'},
    ],
    'effects': [
      {
        'id': 1431,
        'name': '强酸变种',
        'englishName': 'CAUSTIC STRAIN',
        'groupKey': 'enemies',
        'experimental': true,
      },
      {
        'id': 1346,
        'name': '燃烧加特林',
        'englishName': 'INCENDIARY GATLING',
        'groupKey': 'variants',
        'experimental': false,
      },
    ],
  };
  Json get initial => {
    'settings': settings,
    'state': state,
    'catalog': catalog,
    'targets': targets,
  };
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    switch (method) {
      case 'state':
        return state;
      case 'catalog':
        return catalog;
      case 'settings':
        settings.addAll(args);
        return settings;
      case 'save_target':
        targets = [args['target']];
        return targets;
      default:
        return true;
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  setUpAll(() async {
    final sdk = Platform.environment['FLUTTER_ROOT'];
    if (sdk != null) {
      final icons = File(
        '$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      );
      if (icons.existsSync()) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(ByteData.sublistView(icons.readAsBytesSync())),
            ))
            .load();
      }
    }
    final path = File('C:/Windows/Fonts/msyh.ttc');
    if (path.existsSync()) {
      final font = FontLoader('Microsoft YaHei UI')
        ..addFont(Future.value(ByteData.sublistView(path.readAsBytesSync())));
      await font.load();
    }
  });
  test('bilingual name and ID search', () {
    final row = {
      'id': 1431,
      'name': '强酸变种',
      'englishName': 'CAUSTIC STRAIN',
      'aliases': ['bugs_acid'],
    };
    expect(matches(row, '强酸'), isTrue);
    expect(matches(row, 'caustic'), isTrue);
    expect(matches(row, '1431'), isTrue);
    expect(matches(row, 'bugs_acid'), isTrue);
    expect(matches(row, 'other'), isFalse);
  });
  test('heartbeat alone does not rebuild the workspace', () {
    expect(
      stateFingerprint({
        'active': true,
        'health': {'updated': 1, 'rewrites': 0},
      }),
      stateFingerprint({
        'active': true,
        'health': {'updated': 2, 'rewrites': 0},
      }),
    );
    expect(
      stateFingerprint({
        'active': true,
        'health': {'updated': 1, 'rewrites': 0},
      }),
      isNot(
        stateFingerprint({
          'active': true,
          'health': {'updated': 2, 'rewrites': 1},
        }),
      ),
    );
  });
  testWidgets(
    'planet creation, filtered effect selection and language switch',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = FakeCore();
      await tester.pumpWidget(
        CpvApp(core: core, initial: core.initial, nativeWindow: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加星球'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'cyberstan');
      await tester.pumpAndSettle();
      await tester.tap(find.text('生化斯坦'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '强酸');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isTrue);
      await tester.tap(find.text('保存方案'));
      await tester.pumpAndSettle();
      expect(core.targets.single['effects'], [1431]);
      expect(find.text('生化斯坦'), findsOneWidget);
      await tester.tap(find.text('EN'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Planet plans'), findsOneWidget);
      expect(core.settings['language'], 'en');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('weather preserves unrelated effects and only one storm', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanetEditor(
            target: {
              'planet': 1,
              'effects': [1346],
              'enabled': true,
            },
            effects: const [],
            planets: const [],
            en: true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Weather'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exostorm I'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 32  effects'), findsOneWidget);
    await tester.tap(find.text('Exostorm II · Experimental'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 32  effects'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('certificate actions align and diagnostics retain icon widgets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeCore();
    await tester.pumpWidget(
      CpvApp(core: core, initial: core.initial, nativeWindow: false),
    );
    await tester.tap(find.byIcon(Icons.cable_rounded));
    await tester.pumpAndSettle();
    final y = tester.getCenter(find.text('生成证书')).dy;
    expect((tester.getCenter(find.text('安装信任')).dy - y).abs(), lessThan(1));
    expect((tester.getCenter(find.text('移除信任')).dy - y).abs(), lessThan(1));
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('运行诊断'),
      500,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byIcon(Icons.fact_check_outlined), findsOneWidget);
    expect(find.byIcon(Icons.download), findsOneWidget);
    expect(find.textContaining('昼夜、傍晚'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('responsive pages and Morrow appearance previews', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeCore();
    core.targets = [
      {
        'planet': 64,
        'effects': [1431, 1346],
        'enabled': true,
        'campaign': true,
      },
    ];
    await tester.pumpWidget(
      CpvApp(core: core, initial: core.initial, nativeWindow: false),
    );
    await tester.pumpAndSettle();
    expect(
      (tester.widget<GridView>(find.byType(GridView)).gridDelegate
              as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      4,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('previews/01-plans-light.png'),
    );
    for (final icon in [
      Icons.auto_awesome_mosaic_outlined,
      Icons.cable_rounded,
      Icons.tune_rounded,
    ]) {
      await tester.tap(find.byIcon(icon));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('液态玻璃'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('previews/02-appearance-dark.png'),
    );
    tester.view.physicalSize = const Size(900, 650);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.dashboard_outlined));
    await tester.pumpAndSettle();
    expect(
      (tester.widget<GridView>(find.byType(GridView)).gridDelegate
              as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      3,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

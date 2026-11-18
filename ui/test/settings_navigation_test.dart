import 'package:cpv/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeCore;

void main() {
  test('window resize keeps layouts stable near width thresholds', () {
    expect(stablePlanColumns(900, null), 4);
    expect(stablePlanColumns(895, 4), 4);
    expect(stablePlanColumns(879, 4), 3);
    expect(stablePlanColumns(905, 3), 3);
    expect(stablePlanColumns(920, 3), 4);
    expect(stablePlanColumns(300, 4), 1);
    expect(stableWideLayout(955, true), isTrue);
    expect(stableWideLayout(955, false), isFalse);
    expect(stableWideLayout(939, true), isFalse);
    expect(stableWideLayout(980, false), isTrue);
  });
  testWidgets('planet editor uses translucent frost when requested', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanetEditor(
            target: const {'planet': 64, 'effects': <int>[], 'enabled': true},
            effects: const [],
            planets: const [],
            en: false,
            frosted: true,
            frostOpacity: .76,
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    final materials = tester.widgetList<Material>(
      find.descendant(
        of: find.byType(BackdropFilter),
        matching: find.byType(Material),
      ),
    );
    expect(
      materials.any((m) => m.color != null && (m.color!.a - .76).abs() < .01),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('settings categories keep their controls accessible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeCore();
    await tester.pumpWidget(
      CpvApp(core: core, initial: core.initial, nativeWindow: false),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('切换深色模式'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byKey(const ValueKey('appearance-reveal')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('appearance-reveal')), findsNothing);
    await tester.tap(find.text('软件设置').first);
    await tester.pumpAndSettle();
    expect(find.text('颜色模式'), findsOneWidget);
    expect(find.text('配色风格'), findsNothing);
    await tester.tap(find.text('更多配色设置'));
    await tester.pumpAndSettle();
    expect(find.text('配色风格'), findsOneWidget);
    await tester.tap(find.text('背景与视频').first);
    await tester.pumpAndSettle();
    expect(find.text('自定义背景'), findsOneWidget);
    await tester.ensureVisible(find.text('调整背景画面'));
    await tester.tap(find.text('调整背景画面'));
    await tester.pumpAndSettle();
    expect(find.textContaining('背景亮度'), findsOneWidget);
    await tester.tap(find.text('界面与动画').first);
    await tester.pumpAndSettle();
    expect(find.text('界面动画'), findsOneWidget);
    await tester.tap(find.text('诊断与日志').first);
    await tester.pumpAndSettle();
    expect(find.text('运行诊断'), findsOneWidget);
    await tester.tap(find.byTooltip('收起侧边栏'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byTooltip('展开侧边栏'), findsOneWidget);
    expect(core.settings['sidebarCollapsed'], isTrue);
    await tester.tap(find.byTooltip('展开侧边栏'));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.byTooltip('收起侧边栏'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

import 'package:cpv/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> openEditor(
    WidgetTester tester,
    Json target,
    Future<void> Function(Json) save, {
    List<Json> planets = const [],
  }) async {
    tester.view.physicalSize = const Size(1050, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanetEditor(
            target: target,
            effects: const [],
            planets: planets,
            en: false,
            onSave: save,
          ),
        ),
      ),
    );
    await tester.tap(find.text('星球设置'));
    await tester.pumpAndSettle();
  }

  Future<void> selectMode(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(ChoiceChip, label));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'expanded settings keep text fields and page scroll state separate',
    (tester) async {
      Json? saved;
      await openEditor(
        tester,
        {
          'planet': 260,
          'effects': <int>[],
          'enabled': true,
          'campaign': true,
          'campaign_type': 0,
          'campaign_count': 20,
        },
        (plan) async => saved = {...plan},
        planets: [
          {'id': 260, 'owner': 3, 'name': '目标星球'},
          {'id': 5, 'owner': 3, 'name': '来源星球'},
        ],
      );
      await tester.tap(find.text('更多设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final count = find.widgetWithText(TextFormField, '可选作战数');
      await tester.ensureVisible(count);
      await tester.enterText(count, '27');
      await tester.tap(find.text('天气'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('星球设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(count, findsOneWidget);
      await tester.ensureVisible(count);
      expect(tester.widget<TextFormField>(count).initialValue, '27');
      final scrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey('planet-operations')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('启用方案'),
        -500,
        scrollable: scrollable,
      );
      await selectMode(tester, '防守作战（实验性）');
      for (final label in ['防守强度', '防守时长（小时）', '防守作战数']) {
        final field = find.widgetWithText(TextFormField, label);
        await tester.ensureVisible(field);
        await tester.enterText(field, label == '防守时长（小时）' ? '36' : '24');
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('保存方案'));
      await tester.pumpAndSettle();
      expect(saved?['campaign_count'], 27);
      expect(saved?['defense_hours'], 36);
      expect(saved?['defense_level'], 24);
      expect(saved?['defense_count'], 24);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('saved manual operations are retained until a preset is chosen', (
    tester,
  ) async {
    final original = <String, dynamic>{
      'planet': 260,
      'effects': <int>[],
      'enabled': true,
      'owner': 3,
      'campaign': true,
      'force_open': false,
      'campaign_type': 2,
      'campaign_race': 3,
      'campaign_count': 41,
      'open_regions': true,
      'initialize_regions': true,
      'defense_level': 32,
    };
    Json? saved;
    await openEditor(tester, original, (plan) async {
      saved = {...plan};
    });
    expect(find.text('保留已有设置'), findsOneWidget);
    expect(find.text('更多设置'), findsOneWidget);
    expect(find.text('谁控制星球').hitTestable(), findsNothing);
    await tester.tap(find.text('保存方案'));
    await tester.pumpAndSettle();
    expect(saved, original);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'city mode and current operations save a consistent set of options',
    (tester) async {
      for (final keepCurrent in [false, true]) {
        Json? saved;
        await openEditor(
          tester,
          {'planet': 0, 'effects': <int>[], 'enabled': true},
          (plan) async {
            saved = {...plan};
          },
        );
        await selectMode(tester, '城市作战');
        expect(find.text('自动选择'), findsOneWidget);
        expect(find.textContaining('没有可用城市区域时改用普通作战'), findsOneWidget);
        await tester.tap(find.widgetWithText(ChoiceChip, '机器人'));
        await tester.pumpAndSettle();
        if (keepCurrent) await selectMode(tester, '保持原样');
        await tester.tap(find.text('保存方案'));
        await tester.pumpAndSettle();
        expect(saved?['campaign'], !keepCurrent);
        expect(saved?['force_open'], !keepCurrent);
        expect(saved?['campaign_type'], keepCurrent ? 0 : 3);
        expect(saved?['open_regions'], !keepCurrent);
        expect(saved?['initialize_regions'], false);
        expect(saved?['campaign_count'], 20);
        expect(saved?['campaign_race'], keepCurrent ? 0 : 3);
        expect(saved?['owner'], keepCurrent ? 0 : 3);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'defense selects a matching source and explains a missing source',
    (tester) async {
      for (final hasSource in [true, false]) {
        Json? saved;
        await openEditor(
          tester,
          {'planet': 260, 'effects': <int>[], 'enabled': true},
          (plan) async {
            saved = {...plan};
          },
          planets: hasSource
              ? [
                  {'id': 260, 'owner': 3, 'name': '目标星球'},
                  {'id': 5, 'owner': 3, 'name': '来源星球'},
                ]
              : [],
        );
        await selectMode(tester, '防守作战（实验性）');
        await tester.tap(find.text('保存方案'));
        await tester.pumpAndSettle();
        if (hasSource) {
          expect(saved?['campaign_type'], 4);
          expect(saved?['campaign_race'], 3);
          expect(saved?['owner'], 1);
          expect(saved?['defense_source'], 5);
        } else {
          expect(saved, isNull);
          expect(find.text('请选择发起进攻的星球。'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}

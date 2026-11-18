import 'package:cpv/interaction_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'brand title types repeatedly and reduced motion shows it immediately',
    (tester) async {
      Widget app(bool reduced) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: const Scaffold(body: BrandTitle(text: 'CPV')),
        ),
      );
      await tester.pumpWidget(app(false));
      await tester.pump(const Duration(milliseconds: 130));
      expect(find.text('C'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 130));
      expect(find.text('CP'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 130));
      expect(find.text('CPV'), findsNWidgets(2));
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('CPV'), findsOneWidget);
      await tester.pumpWidget(app(true));
      expect(find.text('CPV'), findsOneWidget);
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    },
  );
  testWidgets(
    'card feedback preserves child actions and respects reduced motion',
    (tester) async {
      var taps = 0;
      Widget app(bool reduced) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: Center(
              child: MotionCard(
                child: ElevatedButton(
                  onPressed: () => taps++,
                  child: const Text('Action'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(false));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Action')),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        .985,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      await tester.pumpWidget(app(true));
      final reducedGesture = await tester.startGesture(
        tester.getCenter(find.text('Action')),
      );
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      await reducedGesture.up();
      await tester.pumpAndSettle();
      expect(taps, 2);
    },
  );
  test(
    'radial reveal clears the old layer from the origin to every corner',
    () {
      const size = Size(400, 300);
      const origin = Offset(25, 50);
      final start = const ThemeRevealClipper(origin, 0).getClip(size);
      final middle = const ThemeRevealClipper(origin, .5).getClip(size);
      final end = const ThemeRevealClipper(origin, 1).getClip(size);
      expect(start.contains(const Offset(399, 299)), isTrue);
      expect(middle.contains(origin), isFalse);
      expect(middle.contains(const Offset(399, 299)), isTrue);
      expect(end.contains(const Offset(399, 299)), isFalse);
    },
  );
  for (final reducedMotion in [false, true]) {
    testWidgets(
      'tab indicator follows the latest choice (reduced: $reducedMotion)',
      (tester) async {
        int selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reducedMotion),
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 500,
                    child: StatefulBuilder(
                      builder: (context, setState) => LiquidTabs(
                        labels: const ['Effects', 'Planet settings', 'Weather'],
                        selected: selected,
                        onSelected: (value) => setState(() => selected = value),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final indicator = find.byKey(const ValueKey('liquid-tab-indicator'));
        final effects = find.text('Effects');
        final settings = find.text('Planet settings');
        final weather = find.text('Weather');
        final original = tester.getRect(indicator);
        final weatherCenter = tester.getCenter(weather);
        await tester.tap(weather);
        await tester.pump();
        expect(selected, 2);
        await tester.pump(const Duration(milliseconds: 80));
        final moving = tester.getRect(indicator);
        if (reducedMotion) {
          expect(moving.center.dx, closeTo(weatherCenter.dx, .01));
        } else {
          expect(moving.width, greaterThan(original.width));
        }
        await tester.tap(effects);
        await tester.pump();
        if (!reducedMotion) expect(tester.getRect(indicator), moving);
        await tester.tap(settings);
        await tester.pumpAndSettle();
        expect(selected, 1);
        expect(
          tester.getCenter(indicator).dx,
          closeTo(tester.getCenter(settings).dx, .01),
        );
        expect(tester.getCenter(weather), weatherCenter);
      },
    );
  }

  testWidgets('short and cancelled drags settle, long drag dismisses once', (
    tester,
  ) async {
    final header = find.text('Editor header');
    var closes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await showDialog<void>(
                  context: context,
                  builder: (_) => Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: 400,
                      height: 200,
                      child: EditorDismissMotion(
                        enabled: true,
                        builder: (_, handle) => Material(
                          child: Column(
                            children: [
                              handle(
                                const SizedBox(
                                  width: double.infinity,
                                  height: 64,
                                  child: Center(child: Text('Editor header')),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                closes++;
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    final start = tester.getCenter(header);
    var drag = await tester.startGesture(start);
    await drag.moveBy(
      const Offset(35, 0),
      timeStamp: const Duration(milliseconds: 120),
    );
    await drag.moveBy(
      const Offset(25, 0),
      timeStamp: const Duration(milliseconds: 240),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getCenter(header).dx, greaterThan(start.dx));
    await drag.up(timeStamp: const Duration(milliseconds: 440));
    await tester.pumpAndSettle();
    expect(tester.getCenter(header), start);

    drag = await tester.startGesture(start);
    await drag.moveBy(const Offset(150, 0));
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(tester.getCenter(header), start);

    await tester.drag(header, const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(header, findsNothing);
    expect(closes, 1);
  });
}

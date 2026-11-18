import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cpv/main.dart' show isNightHour;
import 'package:cpv/theme_preferences.dart';

void main() {
  test('scheduled theme handles normal and overnight intervals', () {
    expect(isNightHour(6, 7, 19), isTrue);
    expect(isNightHour(7, 7, 19), isFalse);
    expect(isNightHour(19, 7, 19), isTrue);
    expect(isNightHour(12, 19, 7), isTrue);
    expect(isNightHour(20, 19, 7), isFalse);
    expect(isNightHour(7, 7, 7), isFalse);
  });

  testWidgets('appearance controls update settings immediately', (
    tester,
  ) async {
    final settings = <String, dynamic>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              children: [
                ThemePreferences(
                  settings: settings,
                  english: false,
                  change: (value) => setState(() => settings.addAll(value)),
                  savePreset: () {},
                  applyPreset: (_) {},
                  renamePreset: (_) {},
                  removePreset: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('完整显示'));
    await tester.pump();
    expect(settings['backgroundFit'], 'contain');
    await tester.ensureVisible(find.text('自动切换深浅主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动切换深浅主题'));
    await tester.pumpAndSettle();
    expect(settings['scheduledTheme'], isTrue);
    expect(find.text('白天开始'), findsOneWidget);
  });
}

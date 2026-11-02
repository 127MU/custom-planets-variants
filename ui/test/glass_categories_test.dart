import 'dart:ui' as ui;
import 'package:cpv/main.dart';
import 'package:cpv/morrow/liquid_glass.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'category strip supports mouse drag and vertical mouse wheel without selecting a chip',
    (tester) async {
      var selected = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 54,
                child: HorizontalCategoryBar(
                  children: [
                    for (var i = 0; i < 12; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('Category $i'),
                          selected: false,
                          onSelected: (_) => selected = i,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final list = find.descendant(
        of: find.byType(HorizontalCategoryBar),
        matching: find.byType(ListView),
      );
      final controller = tester.widget<ListView>(list).controller!;
      final point = tester.getCenter(list);
      final mouse = await tester.startGesture(
        point,
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(-40, 0));
      await mouse.moveBy(const Offset(-120, 0));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(50));
      expect(selected, -1);
      final before = controller.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 120)),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'glass filters only its isolated background, not sibling foreground text',
    (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Colors.red)),
                Center(
                  child: SizedBox(
                    width: 240,
                    height: 160,
                    child: RepaintBoundary(
                      key: key,
                      child: LiquidGlassSurface(
                        tint: Colors.white,
                        dark: false,
                        borderRadius: BorderRadius.circular(24),
                        backgroundGradient: const LinearGradient(
                          colors: [Colors.blue, Colors.blue],
                        ),
                        child: const SizedBox(width: 240, height: 160),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final center = (80 * image.width + 120) * 4;
        expect(
          data!.getUint8(center + 2),
          greaterThan(data.getUint8(center) + 80),
        );
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}

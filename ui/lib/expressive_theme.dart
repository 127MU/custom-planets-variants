import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class ExpressiveTheme {
  static const panelRadius = 28.0;
  static const controlRadius = 16.0;
  static final panelSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 340,
    ratio: .84,
  );

  static const seeds = [
    Color(0xff8270b2),
    Color(0xff6d9a8b),
    Color(0xffb28e73),
    Color(0xff7897c1),
  ];

  static const palettes = <String, DynamicSchemeVariant>{
    'expressive': DynamicSchemeVariant.expressive,
    'tonalSpot': DynamicSchemeVariant.tonalSpot,
    'vibrant': DynamicSchemeVariant.vibrant,
    'fidelity': DynamicSchemeVariant.fidelity,
    'monochrome': DynamicSchemeVariant.monochrome,
  };

  static Color? parseColor(String input) {
    final hex = input.trim().replaceFirst(RegExp(r'^#'), '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
    return Color(0xff000000 | int.parse(hex, radix: 16));
  }

  static String hex(Color color) =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static Future<Color?> imageSeed(ui.Image image) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      const Rect.fromLTWH(0, 0, 32, 32),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      final sample = await picture.toImage(32, 32);
      try {
        final data = await sample.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (data == null) return null;
        final buckets = <int, List<double>>{};
        for (var i = 0; i < data.lengthInBytes; i += 4) {
          if (data.getUint8(i + 3) < 128) continue;
          final r = data.getUint8(i),
              g = data.getUint8(i + 1),
              b = data.getUint8(i + 2);
          final color = Color.fromARGB(255, r, g, b);
          final hsl = HSLColor.fromColor(color);
          if (hsl.lightness < .07 || hsl.lightness > .94) continue;
          final key = hsl.saturation < .12 ? -1 : (hsl.hue / 24).round() % 15;
          final weight = hsl.saturation < .12 ? .08 : .2 + hsl.saturation;
          final bucket = buckets.putIfAbsent(key, () => [0, 0, 0, 0]);
          bucket[0] += weight;
          bucket[1] += r * weight;
          bucket[2] += g * weight;
          bucket[3] += b * weight;
        }
        if (buckets.isEmpty) return null;
        final winner = buckets.values.reduce((a, b) => a[0] >= b[0] ? a : b);
        return Color.fromARGB(
          255,
          (winner[1] / winner[0]).round(),
          (winner[2] / winner[0]).round(),
          (winner[3] / winner[0]).round(),
        );
      } finally {
        sample.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  static ThemeData build(Color seed, Brightness brightness, String palette) {
    final colors = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant:
          palettes[palette] ?? DynamicSchemeVariant.expressive,
    );
    final base = ThemeData(
      colorScheme: colors,
      useMaterial3: true,
      fontFamily: 'Microsoft YaHei UI',
    );
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(controlRadius),
    );
    return base.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      dividerColor: colors.outlineVariant,
      textTheme: base.textTheme.copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -.55,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(controlRadius)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(controlRadius)),
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: const StadiumBorder(),
        side: BorderSide(color: colors.outlineVariant),
        selectedColor: colors.secondaryContainer,
        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(panelRadius)),
        ),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        shape: controlShape,
        collapsedShape: controlShape,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class CustomThemeColorDialog extends StatefulWidget {
  const CustomThemeColorDialog({
    super.key,
    required this.initial,
    required this.english,
  });

  final Color initial;
  final bool english;

  @override
  State<CustomThemeColorDialog> createState() => _CustomThemeColorDialogState();
}

class _CustomThemeColorDialogState extends State<CustomThemeColorDialog> {
  late HSVColor color = HSVColor.fromColor(widget.initial);
  late final hex = TextEditingController(
    text: ExpressiveTheme.hex(widget.initial),
  );
  late final rgb = List.generate(3, (index) {
    final shift = (2 - index) * 8;
    return TextEditingController(
      text: '${(widget.initial.toARGB32() >> shift) & 255}',
    );
  });
  String t(String zh, String en) => widget.english ? en : zh;

  void update(HSVColor next, {TextEditingController? editing}) {
    setState(() => color = next);
    final value = color.toColor();
    if (editing != hex) hex.text = ExpressiveTheme.hex(value);
    for (var i = 0; i < rgb.length; i++) {
      if (rgb[i] != editing) {
        rgb[i].text = '${(value.toARGB32() >> ((2 - i) * 8)) & 255}';
      }
    }
  }

  void apply() {
    final selected = ExpressiveTheme.parseColor(hex.text);
    if (selected != null &&
        rgb.every((field) {
          final value = int.tryParse(field.text);
          return value != null && value >= 0 && value <= 255;
        })) {
      Navigator.pop(context, selected.withValues(alpha: color.alpha));
    }
  }

  @override
  void dispose() {
    hex.dispose();
    for (final controller in rgb) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textValid =
        ExpressiveTheme.parseColor(hex.text) != null &&
        rgb.every((field) {
          final value = int.tryParse(field.text);
          return value != null && value >= 0 && value <= 255;
        });
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 398,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t('自定义主题色', 'Custom theme color'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 188,
                child: colorTrack(
                  label: t('饱和度和明度', 'Saturation and brightness'),
                  position: Offset(color.saturation, 1 - color.value),
                  onChange: (point) => update(
                    color.withSaturation(point.dx).withValue(1 - point.dy),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white,
                          HSVColor.fromAHSV(1, color.hue, 1, 1).toColor(),
                        ],
                      ),
                    ),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 24,
                child: colorTrack(
                  label: t('色相', 'Hue'),
                  position: Offset(color.hue / 360, .5),
                  onChange: (point) => update(color.withHue(point.dx * 360)),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          for (var degrees = 0; degrees <= 360; degrees += 60)
                            HSVColor.fromAHSV(
                              1,
                              degrees.toDouble(),
                              1,
                              1,
                            ).toColor(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 20,
                      child: colorTrack(
                        label: t('颜色不透明度', 'Color opacity'),
                        position: Offset(color.alpha, .5),
                        onChange: (point) => update(color.withAlpha(point.dx)),
                        child: CustomPaint(
                          painter: _OpacityTrack(
                            color.toColor(),
                            colors.surfaceContainerHighest,
                            colors.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(color.alpha * 100).round()}%',
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color.toColor(),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outline),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: hex,
                      maxLength: 7,
                      onChanged: (input) {
                        final next = ExpressiveTheme.parseColor(input);
                        if (next == null) {
                          setState(() {});
                        } else {
                          final hsv = HSVColor.fromColor(
                            next,
                          ).withAlpha(color.alpha);
                          update(
                            hsv.saturation == 0 ? hsv.withHue(color.hue) : hsv,
                            editing: hex,
                          );
                        }
                      },
                      onSubmitted: (_) => apply(),
                      decoration: const InputDecoration(
                        labelText: 'HEX',
                        counterText: '',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 0; i < rgb.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: rgb[i],
                        maxLength: 3,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) {
                          final channels = rgb
                              .map((field) => int.tryParse(field.text))
                              .toList();
                          if (channels.any(
                            (value) => value == null || value > 255,
                          )) {
                            setState(() {});
                            return;
                          }
                          final hsv = HSVColor.fromColor(
                            Color.fromARGB(
                              255,
                              channels[0]!,
                              channels[1]!,
                              channels[2]!,
                            ),
                          ).withAlpha(color.alpha);
                          update(
                            hsv.saturation == 0 ? hsv.withHue(color.hue) : hsv,
                            editing: rgb[i],
                          );
                        },
                        onSubmitted: (_) => apply(),
                        decoration: InputDecoration(
                          labelText: ['R', 'G', 'B'][i],
                          counterText: '',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(t('取消', 'Cancel')),
                  ),
                  FilledButton(
                    onPressed: textValid ? apply : null,
                    child: Text(t('应用', 'Apply')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget colorTrack({
    required String label,
    required Offset position,
    required ValueChanged<Offset> onChange,
    required Widget child,
  }) => Semantics(
    label: label,
    child: LayoutBuilder(
      builder: (context, bounds) {
        void move(Offset point) => onChange(
          Offset(
            (point.dx / bounds.maxWidth).clamp(0.0, 1.0),
            (point.dy / bounds.maxHeight).clamp(0.0, 1.0),
          ),
        );
        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (event) => move(event.localPosition),
            onPanStart: (event) => move(event.localPosition),
            onPanUpdate: (event) => move(event.localPosition),
            child: Stack(
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: child,
                ),
                Positioned(
                  left: position.dx * bounds.maxWidth - 8,
                  top: position.dy * bounds.maxHeight - 8,
                  child: IgnorePointer(
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: color.toColor(),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black54, blurRadius: 3),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _OpacityTrack extends CustomPainter {
  const _OpacityTrack(this.color, this.light, this.dark);
  final Color color, light, dark;

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 5.0;
    final brush = Paint();
    for (var y = 0; y < (size.height / cell).ceil(); y++) {
      for (var x = 0; x < (size.width / cell).ceil(); x++) {
        brush.color = (x + y).isEven ? light : dark;
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), brush);
      }
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 1)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_OpacityTrack old) =>
      old.color != color || old.light != light || old.dark != dark;
}

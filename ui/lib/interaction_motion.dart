import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'expressive_theme.dart';

/// Motion.Lab text-fade-up, limited to the small brand label.
class BrandTitle extends StatefulWidget {
  const BrandTitle({super.key, required this.text, this.style});
  final String text;
  final TextStyle? style;

  @override
  State<BrandTitle> createState() => _BrandTitleState();
}

class _BrandTitleState extends State<BrandTitle> {
  Timer? timer;
  int count = 0;
  bool? reducedMotion;

  void schedule(Duration delay) {
    timer?.cancel();
    timer = Timer(delay, () {
      if (!mounted || reducedMotion != false) return;
      final length = widget.text.runes.length;
      setState(() => count = count >= length ? 0 : count + 1);
      schedule(
        count >= length
            ? const Duration(seconds: 4)
            : const Duration(milliseconds: 125),
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion == reduced) return;
    reducedMotion = reduced;
    timer?.cancel();
    count = reduced ? widget.text.runes.length : 0;
    if (!reduced) schedule(const Duration(milliseconds: 125));
  }

  @override
  void didUpdateWidget(covariant BrandTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      count = reducedMotion == true ? widget.text.runes.length : 0;
      if (reducedMotion == false) schedule(const Duration(milliseconds: 125));
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget label(String text) => Text(
      text,
      style: widget.style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (MediaQuery.disableAnimationsOf(context)) return label(widget.text);
    final shown = String.fromCharCodes(widget.text.runes.take(count));
    final colors = Theme.of(context).colorScheme;
    final textColor = widget.style?.color ?? colors.onSurface;
    final progress = widget.text.runes.isEmpty
        ? 1.0
        : count / widget.text.runes.length;
    final painted = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment(-2 + progress * 2, 0),
        end: Alignment(-1 + progress * 2, 0),
        colors: [textColor, colors.primary, textColor],
      ).createShader(bounds),
      child: label(shown),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      child: Semantics(
        label: widget.text,
        child: ExcludeSemantics(
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Opacity(opacity: 0, child: label(widget.text)),
              painted,
            ],
          ),
        ),
      ),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}

/// Motion.Lab hover-lift / button-press adapted to native Flutter cards.
/// Pointer feedback never owns the gesture, so child controls stay operable.
class MotionCard extends StatefulWidget {
  const MotionCard({super.key, required this.child});
  final Widget child;

  @override
  State<MotionCard> createState() => _MotionCardState();
}

class _MotionCardState extends State<MotionCard> {
  bool hovered = false;
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() {
        hovered = false;
        pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => pressed = true),
        onPointerUp: (_) => setState(() => pressed = false),
        onPointerCancel: (_) => setState(() => pressed = false),
        child: AnimatedSlide(
          duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          offset: !reduced && hovered && !pressed
              ? const Offset(0, -.012)
              : Offset.zero,
          child: AnimatedScale(
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            scale: !reduced && pressed ? .985 : 1,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Motion.Lab fade-in-up for newly selected settings sections.
class MotionEntrance extends StatelessWidget {
  const MotionEntrance({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Transform.translate(
        offset: Offset(0, 10 * (1 - value)),
        child: child,
      ),
    );
  }
}

class ThemeRevealClipper extends CustomClipper<Path> {
  const ThemeRevealClipper(this.origin, this.progress);

  final Offset origin;
  final double progress;

  @override
  Path getClip(Size size) {
    final x = math.max(origin.dx.abs(), (size.width - origin.dx).abs());
    final y = math.max(origin.dy.abs(), (size.height - origin.dy).abs());
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(
        Rect.fromCircle(
          center: origin,
          radius: math.sqrt(x * x + y * y) * progress,
        ),
      );
  }

  @override
  bool shouldReclip(ThemeRevealClipper oldClipper) =>
      origin != oldClipper.origin || progress != oldClipper.progress;
}

class LiquidTabs extends StatefulWidget {
  const LiquidTabs({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  State<LiquidTabs> createState() => _LiquidTabsState();
}

class _LiquidTabsState extends State<LiquidTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion;
  late double startLeft, startRight;

  double edge(double start, double target, bool isLeft) {
    final movingRight = target >= start;
    final leading = isLeft != movingRight;
    final curve = leading ? Curves.easeOutCubic : Curves.easeInOutCubic;
    return start + (target - start) * curve.transform(motion.value);
  }

  double left(int index) => edge(startLeft, index.toDouble(), true);
  double right(int index) => edge(startRight, index + 1.0, false);

  @override
  void initState() {
    super.initState();
    startLeft = widget.selected.toDouble();
    startRight = startLeft + 1;
    motion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant LiquidTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      final currentLeft = left(oldWidget.selected);
      startRight = right(oldWidget.selected);
      startLeft = currentLeft;
      if (MediaQuery.disableAnimationsOf(context)) {
        motion.value = 1;
      } else {
        motion.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduced = MediaQuery.disableAnimationsOf(context);
    const shape = StadiumBorder();
    return Material(
      shape: shape.copyWith(side: BorderSide(color: colors.outlineVariant)),
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: LayoutBuilder(
          builder: (context, bounds) {
            final unit = bounds.maxWidth / widget.labels.length;
            return Stack(
              children: [
                AnimatedBuilder(
                  animation: motion,
                  builder: (context, child) => Positioned(
                    left:
                        unit *
                        (reduced ? widget.selected : left(widget.selected)),
                    right:
                        unit *
                        (widget.labels.length -
                            (reduced
                                ? widget.selected + 1
                                : right(widget.selected))),
                    top: 0,
                    bottom: 0,
                    child: child!,
                  ),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: const ValueKey('liquid-tab-indicator'),
                      decoration: ShapeDecoration(
                        shape: shape,
                        color: colors.secondaryContainer,
                      ),
                    ),
                  ),
                ),
                Row(
                  children: List.generate(widget.labels.length, (index) {
                    final selected = index == widget.selected;
                    return Expanded(
                      child: Semantics(
                        selected: selected,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: selected
                                ? colors.onSecondaryContainer
                                : colors.onSurface,
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            shape: shape,
                          ),
                          onPressed: () => widget.onSelected(index),
                          child: Text(
                            widget.labels[index],
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Keeps the draft open when the user releases short of the dismissal threshold.
class EditorDismissMotion extends StatefulWidget {
  const EditorDismissMotion({
    super.key,
    required this.enabled,
    required this.builder,
  });

  final bool enabled;
  final Widget Function(BuildContext, Widget Function(Widget)) builder;

  @override
  State<EditorDismissMotion> createState() => _EditorDismissMotionState();
}

class _EditorDismissMotionState extends State<EditorDismissMotion>
    with SingleTickerProviderStateMixin {
  late final motion = AnimationController(vsync: this);
  bool closing = false;
  bool pointerCancelled = false;

  Future<void> release(double velocity, double width) async {
    if (closing) return;
    closing =
        widget.enabled &&
        !pointerCancelled &&
        (motion.value >= .28 && velocity > -500 ||
            motion.value * width >= 24 && velocity >= 700);
    if (closing) setState(() {});
    final destination = closing ? 1.0 : 0.0;
    final releaseVelocity = pointerCancelled
        ? 0.0
        : (velocity / width).clamp(-4.0, 4.0);
    try {
      await motion
          .animateWith(
            SpringSimulation(
              ExpressiveTheme.panelSpring,
              motion.value,
              destination,
              releaseVelocity,
              snapToEnd: true,
              tolerance: const Tolerance(distance: .001, velocity: .015),
            ),
          )
          .orCancel;
      if (closing && mounted && ModalRoute.isCurrentOf(context) == true) {
        Navigator.pop(context);
      }
    } on TickerCanceled {
      // A new drag or disposal interrupted the settling animation.
    }
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context) && !closing) {
      return widget.builder(context, (header) => header);
    }
    return LayoutBuilder(
      builder: (context, bounds) => AnimatedBuilder(
        animation: motion,
        builder: (context, child) => FractionalTranslation(
          translation: Offset(motion.value, 0),
          child: child,
        ),
        child: AbsorbPointer(
          absorbing: closing,
          child: widget.builder(context, (header) {
            if (!widget.enabled || bounds.maxWidth <= 0) return header;
            return Listener(
              onPointerDown: (_) => pointerCancelled = false,
              onPointerCancel: (_) => pointerCancelled = true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => motion.stop(),
                onHorizontalDragUpdate: (details) {
                  motion.value =
                      (motion.value + details.delta.dx / bounds.maxWidth).clamp(
                        0.0,
                        1.0,
                      );
                },
                onHorizontalDragEnd: (details) =>
                    release(details.primaryVelocity ?? 0, bounds.maxWidth),
                onHorizontalDragCancel: () {
                  pointerCancelled = true;
                  release(0, bounds.maxWidth);
                },
                child: header,
              ),
            );
          }),
        ),
      ),
    );
  }
}

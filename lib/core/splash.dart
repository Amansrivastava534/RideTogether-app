import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Brand colour of the launch screens. Keep in sync with
/// android/app/src/main/res/values/colors.xml and LaunchScreen.storyboard.
const splashColor = Color(0xFFE8590C);

const _intro = Duration(milliseconds: 1700);
const _fadeOut = Duration(milliseconds: 350);

/// Animated splash drawn over the app on cold start. It starts from the
/// native launch icon (white ring + dot) so the hand-off is seamless, plays
/// a location ping → bike ride-in → title, and fades out once the intro has
/// played AND [ready] is true (auth/profile resolved), so there is no
/// spinner flash behind it.
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({super.key, required this.ready, required this.child});
  final bool ready;
  final Widget child;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: _intro)..addStatusListener((_) => setState(() {}));
  bool _gone = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.status != AnimationStatus.dismissed) return;
    // Respect "remove animations" accessibility setting.
    MediaQuery.disableAnimationsOf(context) ? _c.value = 1 : _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final show = !(widget.ready && _c.isCompleted);
    return Stack(
      children: [
        widget.child,
        if (!_gone)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !show,
              child: AnimatedOpacity(
                opacity: show ? 1 : 0,
                duration: _fadeOut,
                onEnd: () {
                  if (!show) setState(() => _gone = true);
                },
                child: _SplashArt(controller: _c, waiting: _c.isCompleted && !widget.ready),
              ),
            ),
          ),
      ],
    );
  }
}

class _SplashArt extends StatelessWidget {
  const _SplashArt({required this.controller, required this.waiting});
  final Animation<double> controller;
  final bool waiting;

  /// Maps the controller to a 0→1 sub-interval with a curve.
  double _seg(double begin, double end, [Curve curve = Curves.easeOut]) =>
      curve.transform(((controller.value - begin) / (end - begin)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Material(
        color: splashColor,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final ping = _seg(0, 0.4);
            final pinFade = 1 - _seg(0.3, 0.5);
            final ride = _seg(0.3, 0.65, Curves.easeOutBack);
            final lines = _seg(0.35, 0.55) * (1 - _seg(0.6, 0.8));
            final title = _seg(0.55, 0.8);
            final tagline = _seg(0.7, 1);
            return Stack(
              alignment: Alignment.center,
              children: [
                // Ripples expanding out of the launch icon.
                for (final delay in const [0.0, 0.35]) _Ripple(t: ((ping - delay) / (1 - delay)).clamp(0.0, 1.0)),
                // The launch icon itself (88 dp ring, 36 dp dot = native vector).
                Opacity(
                  opacity: pinFade,
                  child: Transform.scale(scale: 1 - 0.4 * (1 - pinFade), child: const _Pin()),
                ),
                // Bike rides in from the left with speed lines behind it.
                Transform.translate(
                  offset: Offset(-(width / 2 + 60) * (1 - ride), 0),
                  child: Opacity(
                    opacity: ride.clamp(0.0, 1.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Opacity(opacity: lines, child: const _SpeedLines()),
                        const SizedBox(width: 6),
                        const Icon(Icons.two_wheeler, size: 96, color: Colors.white),
                        const SizedBox(width: 34), // keeps the bike optically centred
                      ],
                    ),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, 96),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: title,
                        child: Transform.translate(
                          offset: Offset(0, 16 * (1 - title)),
                          child: const Text(
                            'RideTogether',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Opacity(
                        opacity: tagline,
                        child: const Text(
                          'Ride together. Arrive together.',
                          style: TextStyle(color: Color(0xE6FFFFFF), fontSize: 16),
                        ),
                      ),
                      const SizedBox(height: 28),
                      // Only if startup is slow (e.g. offline cold start).
                      SizedBox(
                        height: 24,
                        child: waiting
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin();
  @override
  Widget build(BuildContext context) => Container(
    width: 88,
    height: 88,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 8),
    ),
    child: Container(
      width: 36,
      height: 36,
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
    ),
  );
}

class _Ripple extends StatelessWidget {
  const _Ripple({required this.t});
  final double t;
  @override
  Widget build(BuildContext context) {
    if (t <= 0 || t >= 1) return const SizedBox.shrink();
    final d = 88 + 200 * t;
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: math.max(0, 0.6 * (1 - t))), width: 3),
      ),
    );
  }
}

class _SpeedLines extends StatelessWidget {
  const _SpeedLines();
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      for (final w in const [34.0, 48.0, 26.0])
        Container(
          width: w,
          height: 5,
          margin: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3)),
        ),
    ],
  );
}

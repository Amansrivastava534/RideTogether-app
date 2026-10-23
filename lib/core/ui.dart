import 'package:flutter/material.dart';

import '../domain/ride_logic.dart';

/// Distinct, high-contrast colours for riders, stable per uid.
const riderPalette = <Color>[
  Color(0xFFE53935),
  Color(0xFF1E88E5),
  Color(0xFF43A047),
  Color(0xFFFB8C00),
  Color(0xFF8E24AA),
  Color(0xFF00ACC1),
  Color(0xFFD81B60),
  Color(0xFF6D4C41),
  Color(0xFF3949AB),
  Color(0xFF7CB342),
  Color(0xFFF4511E),
  Color(0xFF00897B),
];

Color riderColor(String uid) => riderPalette[uid.codeUnits.fold(0, (a, c) => a * 31 + c) % riderPalette.length];

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}

Color statusColor(RiderStatus s) => switch (s) {
  RiderStatus.moving => const Color(0xFF2E7D32),
  RiderStatus.stationary => const Color(0xFF1565C0),
  RiderStatus.paused => const Color(0xFFF9A825),
  RiderStatus.stale => const Color(0xFFEF6C00),
  RiderStatus.offline || RiderStatus.noLocation => const Color(0xFF757575),
};

class RiderAvatar extends StatelessWidget {
  const RiderAvatar({super.key, required this.uid, required this.name, this.photoUrl, this.radius = 20, this.status});
  final String uid;
  final String name;
  final String? photoUrl;
  final double radius;
  final RiderStatus? status;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: riderColor(uid),
      foregroundImage: photoUrl == null ? null : NetworkImage(photoUrl!),
      child: Text(
        initials(name),
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: radius * 0.8),
      ),
    );
    if (status == null) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: radius * 0.65,
            height: radius * 0.65,
            decoration: BoxDecoration(
              color: statusColor(status!),
              shape: BoxShape.circle,
              border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

class CenteredMessage extends StatelessWidget {
  const CenteredMessage({super.key, required this.icon, required this.title, this.body, this.action});
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: t.titleLarge, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(body!, style: t.bodyMedium, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: CircularProgressIndicator());
}

String friendlyError(Object e) {
  final s = e.toString();
  if (s.contains('permission-denied')) return 'You don’t have access to this ride.';
  if (s.contains('unavailable') || s.contains('network')) return 'You appear to be offline. Try again when connected.';
  return s.replaceFirst(RegExp(r'^\[.*?\]\s*'), '');
}

void showSnack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '${h}h ${m}m' : '${d.inMinutes}m';
}

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFFF6D00), brightness: b);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
  );
}

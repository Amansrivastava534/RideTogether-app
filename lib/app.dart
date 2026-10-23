import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/splash.dart';
import 'core/ui.dart';
import 'domain/ride_logic.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/home/home_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/ride/join_ride_screen.dart';
import 'providers.dart';

class RideTogetherApp extends ConsumerWidget {
  const RideTogetherApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    return MaterialApp(
      title: 'RideTogether',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      // Invite links (https://<host>/j/CODE or ridetogether://<host>/j/CODE)
      // arrive as route names via Flutter's built-in deep linking.
      onGenerateInitialRoutes: (name) => [_route('/')!, if (_route(name) case final r? when name != '/') r],
      onGenerateRoute: (s) => _route(s.name ?? '/'),
      // Animated splash over whatever route opened (home or an invite link),
      // held until sign-in state (and the profile, if signed in) is known.
      builder: (context, child) => Consumer(
        builder: (context, ref, _) {
          final user = ref.watch(authUserProvider);
          final ready = !user.isLoading && (user.value == null || !ref.watch(profileProvider).isLoading);
          return SplashOverlay(ready: ready, child: child!);
        },
      ),
    );
  }

  static Route<void>? _route(String name) {
    final uri = Uri.tryParse(name);
    final segs = uri?.pathSegments ?? const [];
    if (segs.length == 2 && segs[0] == 'j') {
      return MaterialPageRoute(
        builder: (_) => AuthGate(child: JoinRideScreen(initialCode: normalizeInviteCode(segs[1]))),
      );
    }
    if (segs.isEmpty) return MaterialPageRoute(builder: (_) => const AuthGate(child: HomeScreen()));
    return null;
  }
}

/// Shows sign-in, then first-run profile setup, then [child].
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authUserProvider);
    if (user.isLoading) return const Scaffold(body: Loading());
    if (user.value == null) return const SignInScreen();
    final profile = ref.watch(profileProvider);
    return switch (profile) {
      AsyncData(value: null) => const ProfileScreen(setup: true),
      AsyncData() => child,
      AsyncError(:final error) => Scaffold(
        body: CenteredMessage(
          icon: Icons.cloud_off,
          title: 'Could not load your profile',
          body: friendlyError(error),
          action: OutlinedButton(onPressed: () => ref.invalidate(profileProvider), child: const Text('Retry')),
        ),
      ),
      _ => const Scaffold(body: Loading()),
    };
  }
}

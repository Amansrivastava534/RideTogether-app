import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/ride_repository.dart';
import 'data/user_repository.dart';
import 'domain/models.dart';

/// Overridden in main() after SharedPreferences.getInstance().
final prefsProvider = Provider<SharedPreferences>((_) => throw UnimplementedError());
final firestoreProvider = Provider<FirebaseFirestore>((_) => FirebaseFirestore.instance);
final authProvider = Provider<FirebaseAuth>((_) => FirebaseAuth.instance);

final rideRepoProvider = Provider((ref) => RideRepository(ref.watch(firestoreProvider)));
final userRepoProvider = Provider((ref) => UserRepository(ref.watch(authProvider), ref.watch(firestoreProvider)));

final authUserProvider = StreamProvider<User?>((ref) => ref.watch(userRepoProvider).authChanges());

final profileProvider = StreamProvider<UserProfile?>((ref) {
  final uid = ref.watch(authUserProvider).value?.uid;
  if (uid == null) return Stream.value(null);
  return ref.watch(userRepoProvider).watchProfile(uid);
});

final rideProvider = StreamProvider.autoDispose.family<Ride?, String>(
  (ref, id) => ref.watch(rideRepoProvider).watchRide(id),
);

final myMembershipProvider = StreamProvider.autoDispose.family<RideMember?, String>((ref, rideId) {
  final uid = ref.watch(authUserProvider).value?.uid;
  if (uid == null) return Stream.value(null);
  return ref.watch(rideRepoProvider).watchMyMembership(rideId, uid);
});

/// Members and locations are only readable by active members; don't even
/// subscribe otherwise (the backend would reject it anyway).
final membersProvider = StreamProvider.autoDispose.family<List<RideMember>, String>((ref, rideId) {
  final me = ref.watch(myMembershipProvider(rideId)).value;
  if (me == null || !me.isActive) return Stream.value(const []);
  return ref.watch(rideRepoProvider).watchMembers(rideId);
});

final locationsProvider = StreamProvider.autoDispose
    .family<({Map<String, LiveLocation> locations, bool fromCache}), String>((ref, rideId) {
      final me = ref.watch(myMembershipProvider(rideId)).value;
      if (me == null || !me.isActive) return Stream.value((locations: const {}, fromCache: false));
      return ref.watch(rideRepoProvider).watchLocations(rideId);
    });

final recentRidesProvider = StreamProvider.autoDispose<List<RecentRide>>((ref) {
  final uid = ref.watch(authUserProvider).value?.uid;
  if (uid == null) return Stream.value(const []);
  return ref.watch(rideRepoProvider).watchRecentRides(uid);
});

final historyProvider = StreamProvider.autoDispose<List<RideHistory>>((ref) {
  final uid = ref.watch(authUserProvider).value?.uid;
  if (uid == null) return Stream.value(const []);
  return ref.watch(userRepoProvider).watchHistory(uid);
});

/// Ticks every few seconds so "x s ago" and stale states refresh even when
/// no new data arrives — staleness is exactly the case where nothing arrives.
final clockProvider = StreamProvider.autoDispose<DateTime>(
  (_) => Stream.periodic(const Duration(seconds: 5), (_) => DateTime.now()),
);

DateTime watchNow(WidgetRef ref) => ref.watch(clockProvider).value ?? DateTime.now();

// --- local settings ----------------------------------------------------------

class AppSettings {
  const AppSettings({this.themeMode = ThemeMode.system, this.backgroundSharing = true});
  final ThemeMode themeMode;

  /// Keep sharing while the app is in the background (Android foreground
  /// service / iOS background location mode).
  final bool backgroundSharing;
}

class SettingsController extends Notifier<AppSettings> {
  SharedPreferences get _p => ref.read(prefsProvider);

  @override
  AppSettings build() {
    final p = ref.watch(prefsProvider);
    return AppSettings(
      themeMode: ThemeMode.values.asNameMap()[p.getString('themeMode')] ?? ThemeMode.system,
      backgroundSharing: p.getBool('backgroundSharing') ?? true,
    );
  }

  void setThemeMode(ThemeMode m) {
    _p.setString('themeMode', m.name);
    state = AppSettings(themeMode: m, backgroundSharing: state.backgroundSharing);
  }

  void setBackgroundSharing(bool v) {
    _p.setBool('backgroundSharing', v);
    state = AppSettings(themeMode: state.themeMode, backgroundSharing: v);
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

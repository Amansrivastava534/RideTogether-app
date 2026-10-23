import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/geo.dart';
import '../../core/ui.dart';
import '../../domain/models.dart';
import '../../providers.dart';
import '../history/history_screens.dart';
import '../tracking/tracking_controller.dart';

/// Explains why, then asks for foreground location, then starts sharing.
/// Called only when the user taps "Share my location".
Future<void> startSharingFlow(BuildContext context, WidgetRef ref, String rideId) async {
  final tracking = ref.read(trackingProvider.notifier);
  var access = await tracking.checkAccess();
  if (!context.mounted) return;

  if (access == LocationAccess.serviceDisabled) {
    final open = await _ask(
      context,
      'Turn on location',
      'GPS is off. Turn on location services to share where you are.',
      'Open settings',
    );
    if (open) await Geolocator.openLocationSettings();
    return;
  }
  if (access == LocationAccess.denied) {
    final bg = ref.read(settingsProvider).backgroundSharing;
    final ok = await _ask(
      context,
      'Share your location with this ride',
      'RideTogether uses your precise location so ride members can see you on the map, '
          'including how far apart you are.\n\n'
          '${bg ? 'Sharing continues while your screen is off or you use other apps, until you pause, stop or leave the ride. '
                    'Android shows a notification while this is on; iOS shows a blue location indicator.\n\n' : ''}'
          'Only active members of this ride can see it.',
      'Continue',
    );
    if (!ok) return;
    access = await tracking.requestAccess();
    if (!context.mounted) return;
  }
  if (access == LocationAccess.deniedForever || access == LocationAccess.denied) {
    final open = await _ask(
      context,
      'Location permission needed',
      'Location access is turned off for RideTogether. Enable it in Settings to share your position.',
      'Open settings',
    );
    if (open) await Geolocator.openAppSettings();
    return;
  }
  await tracking.startSharing(rideId);
  // Push notifications (SOS / join requests) are relevant from here on.
  final uid = ref.read(authUserProvider).value?.uid;
  if (uid != null) unawaited(ref.read(userRepoProvider).registerPushToken(uid).catchError((Object _) {}));
}

Future<bool> _ask(BuildContext context, String title, String body, String confirm) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(confirm)),
        ],
      ),
    ) ??
    false;

Future<void> confirmLeave(BuildContext context, WidgetRef ref, Ride ride) async {
  final ok = await _ask(
    context,
    'Leave “${ride.name}”?',
    'Your location sharing stops and others will no longer see you.',
    'Leave ride',
  );
  if (!ok || !context.mounted) return;
  final me = ref.read(profileProvider).value!;
  final members = ref.read(membersProvider(ride.id)).value ?? const [];
  final tracking = ref.read(trackingProvider.notifier);
  // Stop GPS first, then revoke membership.
  final history = ref.read(trackingProvider).rideId == ride.id
      ? await tracking.finishRide(ride: ride, members: members, me: me)
      : null;
  try {
    await ref.read(rideRepoProvider).leaveRide(ride.id, me.uid);
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e));
  }
  if (context.mounted) _toSummary(context, ride, history, 'You left the ride.');
}

Future<void> confirmEnd(BuildContext context, WidgetRef ref, Ride ride) async {
  final ok = await _ask(
    context,
    'End ride for everyone?',
    'Location sharing stops for all members and the ride is closed.',
    'End ride',
  );
  if (!ok || !context.mounted) return;
  try {
    await ref.read(rideRepoProvider).endRide(ride.id);
    // RideScope reacts to the ended status and shows the summary.
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e));
  }
}

void _toSummary(BuildContext context, Ride ride, RideHistory? history, String reason) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(
      builder: (_) => RideSummaryScreen(ride: ride, history: history, reason: reason),
    ),
    (r) => r.isFirst,
  );
}

final _alertsProvider = StreamProvider.autoDispose.family<List<RideAlert>, String>((ref, rideId) {
  final me = ref.watch(myMembershipProvider(rideId)).value;
  if (me == null || !me.isActive) return Stream.value(const []);
  return ref.watch(rideRepoProvider).watchAlerts(rideId, DateTime.now().subtract(const Duration(minutes: 15)));
});

/// Wraps every in-ride screen: reacts to the ride ending, being removed, and
/// incoming SOS alerts — independent of which ride screen is showing.
class RideScope extends ConsumerStatefulWidget {
  const RideScope({super.key, required this.rideId, required this.child, this.onShowRider});
  final String rideId;
  final Widget child;
  final void Function(String uid)? onShowRider;

  @override
  ConsumerState<RideScope> createState() => _RideScopeState();
}

class _RideScopeState extends ConsumerState<RideScope> {
  bool _finished = false;
  final _seenAlerts = <String>{};

  Future<void> _finish(Ride ride, String reason) async {
    if (_finished) return;
    _finished = true;
    final me = ref.read(profileProvider).value;
    final members = ref.read(membersProvider(ride.id)).value ?? const [];
    // Only tear down tracking if this is the ride we track.
    final ours = ref.read(trackingProvider).rideId == ride.id;
    final history = me == null || !ours
        ? null
        : await ref.read(trackingProvider.notifier).finishRide(ride: ride, members: members, me: me);
    if (mounted) _toSummary(context, ride, history, reason);
  }

  void _showSos(RideAlert a) {
    final myLoc = ref.read(trackingProvider).lastFix;
    final dist = (a.point != null && myLoc != null) ? formatDistance(distanceMeters(a.point!, myLoc.point)) : null;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.sos, color: Colors.red, size: 40),
        title: Text('${a.name} sent an SOS'),
        content: Text(
          [
            if (dist != null) 'About $dist away (straight line).',
            if (a.point == null) 'Their location was not available.',
            'Call them or emergency services (112 in India) if you cannot reach them.',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Dismiss')),
          if (widget.onShowRider != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(c);
                widget.onShowRider!(a.uid);
              },
              child: const Text('Show on map'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(authUserProvider).value?.uid;
    ref.listen(rideProvider(widget.rideId), (_, next) {
      final ride = next.value;
      if (ride != null && ride.isEnded) _finish(ride, 'The ride has ended.');
    });
    ref.listen(myMembershipProvider(widget.rideId), (prev, next) {
      final ride = ref.read(rideProvider(widget.rideId)).value;
      final m = next.value;
      if (ride == null || next.isLoading || prev?.value == null) return;
      if (m == null || m.status == MemberStatus.removed) _finish(ride, 'You are no longer a member of this ride.');
    });
    ref.listen(_alertsProvider(widget.rideId), (_, next) {
      for (final a in next.value ?? const <RideAlert>[]) {
        if (_seenAlerts.add(a.id) && a.uid != uid) _showSos(a);
      }
    });
    return widget.child;
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../core/ui.dart';
import '../../domain/models.dart';
import '../../domain/ride_logic.dart';
import '../../providers.dart';
import '../ride/ride_flow.dart';
import '../tracking/tracking_controller.dart';
import 'member_tile.dart';

/// Fraction of screen height the panel covers when first shown. The map's
/// bottom padding uses it so fitted markers never sit under the panel.
const panelInitialSize = 0.3;

/// Bottom sheet over the map: own sharing controls, SOS, selected rider
/// details and the ordered rider list.
class RidePanel extends ConsumerWidget {
  const RidePanel({
    super.key,
    required this.ride,
    required this.members,
    required this.locations,
    required this.now,
    required this.myUid,
    required this.myPoint,
    required this.spread,
    required this.flagged,
    required this.selected,
    required this.onSelect,
    required this.onCloseSelected,
    required this.onNavigate,
  });

  final Ride ride;
  final List<RideMember> members;
  final Map<String, LiveLocation> locations;
  final DateTime now;
  final String? myUid;
  final Coord? myPoint;
  final Map<String, RiderSpread> spread;
  final Set<String> flagged;
  final String? selected;
  final void Function(String uid) onSelect;
  final VoidCallback onCloseSelected;
  final void Function(String uid) onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Front of the group first when a group heading is known.
    final ordered = [...members]
      ..sort((a, b) {
        final sa = spread[a.uid]?.alongTrackM, sb = spread[b.uid]?.alongTrackM;
        if (sa != null && sb != null) return sb.compareTo(sa);
        if (sa != null) return -1;
        if (sb != null) return 1;
        return a.name.compareTo(b.name);
      });
    final ordering = spread.values.any((s) => s.alongTrackM != null);
    final sel = members.where((m) => m.uid == selected).firstOrNull;

    return DraggableScrollableSheet(
      initialChildSize: panelInitialSize,
      minChildSize: 0.2,
      maxChildSize: 0.85,
      builder: (context, scroll) => Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (sel != null)
              _RiderDetail(
                member: sel,
                location: locations[sel.uid],
                myPoint: myPoint,
                now: now,
                isMe: sel.uid == myUid,
                onClose: onCloseSelected,
                onNavigate: () => onNavigate(sel.uid),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _SharingControls(ride: ride),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                ordering ? 'Riders · front of group first' : 'Riders',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final m in ordered)
              MemberTile(
                member: m,
                location: locations[m.uid],
                now: now,
                myPoint: myPoint,
                isMe: m.uid == myUid,
                farFromGroup: flagged.contains(m.uid),
                onTap: () => onSelect(m.uid),
              ),
          ],
        ),
      ),
    );
  }
}

class _RiderDetail extends StatelessWidget {
  const _RiderDetail({
    required this.member,
    required this.location,
    required this.myPoint,
    required this.now,
    required this.isMe,
    required this.onClose,
    required this.onNavigate,
  });
  final RideMember member;
  final LiveLocation? location;
  final Coord? myPoint;
  final DateTime now;
  final bool isMe;
  final VoidCallback onClose;
  final VoidCallback onNavigate;

  @override
  Widget build(BuildContext context) {
    final l = location;
    final status = statusOf(l, now);
    final t = Theme.of(context).textTheme;
    Widget fact(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(value, style: t.titleMedium, textAlign: TextAlign.center),
          Text(label, style: t.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                RiderAvatar(uid: member.uid, name: member.name, photoUrl: member.photoUrl, status: status, radius: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isMe ? '${member.name} (you)' : member.name, style: t.titleLarge),
                      Text([status.label, ?member.bikeName].join(' · ')),
                    ],
                  ),
                ),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close), tooltip: 'Close'),
              ],
            ),
            const SizedBox(height: 12),
            if (l == null)
              const Text('No location shared yet.')
            else ...[
              Row(
                children: [
                  fact('speed', status.isLive && l.speed != null ? '${(l.speed! * 3.6).round()} km/h' : '—'),
                  fact(status.isLive ? 'updated' : 'last seen', ago(l.updatedAt, now)),
                  fact('GPS accuracy', '±${l.accuracy.round()} m'),
                  if (!isMe)
                    fact('away', myPoint == null ? '—' : '≈ ${formatDistance(distanceMeters(myPoint!, l.point))}'),
                ],
              ),
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Distance is approximate straight-line, not road distance.', style: t.bodySmall),
                ),
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: onNavigate,
                      icon: const Icon(Icons.navigation),
                      label: const Text('Navigate in Google Maps'),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SharingControls extends ConsumerWidget {
  const _SharingControls({required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracking = ref.watch(trackingProvider);
    final ctl = ref.read(trackingProvider.notifier);
    final now = watchNow(ref);
    final sos = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.red,
        side: const BorderSide(color: Colors.red, width: 2),
        minimumSize: const Size(96, 56),
      ),
      onPressed: () => _confirmSos(context, ref),
      icon: const Icon(Icons.sos),
      label: const Text('SOS'),
    );

    final main = switch (tracking.phase) {
      SharingPhase.off => FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
        onPressed: () => startSharingFlow(context, ref, ride.id),
        icon: const Icon(Icons.share_location),
        label: const Text('Share my location'),
      ),
      SharingPhase.sharing => OutlinedButton.icon(
        onPressed: ctl.pauseSharing,
        icon: const Icon(Icons.pause),
        label: Text(
          tracking.lastSentAt == null ? 'Getting GPS fix…' : 'Pause · sent ${ago(tracking.lastSentAt!, now)}',
        ),
      ),
      SharingPhase.paused => FilledButton.icon(
        onPressed: () => startSharingFlow(context, ref, ride.id),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Resume sharing'),
      ),
    };

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: main),
            const SizedBox(width: 8),
            sos,
          ],
        ),
        if (tracking.phase != SharingPhase.off)
          TextButton.icon(
            onPressed: ctl.stopSharing,
            icon: const Icon(Icons.location_off),
            label: const Text('Stop sharing (remove me from the map)'),
          ),
      ],
    );
  }

  Future<void> _confirmSos(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.sos, color: Colors.red, size: 40),
        title: const Text('Send SOS to your ride?'),
        content: const Text(
          'This alerts every member of this ride with your latest known location.\n\n'
          '• It does NOT contact emergency services. In an emergency call 112.\n'
          '• Delivery depends on their internet connection and notification settings, '
          'and may be delayed or not arrive.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Send SOS'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final me = ref.read(profileProvider).value!;
    try {
      // Completes on server ack; offline, the SDK keeps it queued and sends later.
      await ref
          .read(rideRepoProvider)
          .sendSos(ride.id, me, ref.read(trackingProvider).lastFix)
          .timeout(const Duration(seconds: 8));
      if (context.mounted) showSnack(context, 'SOS sent to ride members');
    } on TimeoutException {
      if (context.mounted) {
        showSnack(
          context,
          'No connection. SOS will send automatically when you’re back online — call directly if you can.',
        );
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'SOS failed: ${friendlyError(e)}. Call your friends directly.');
    }
  }
}

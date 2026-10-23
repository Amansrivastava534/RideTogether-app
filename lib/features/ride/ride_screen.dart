import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/ui.dart';
import '../../data/ride_repository.dart';
import '../../domain/models.dart';
import '../../providers.dart';
import '../history/history_screens.dart';
import '../map/live_map_screen.dart';
import '../map/member_tile.dart';
import '../tracking/tracking_controller.dart';
import 'ride_flow.dart';
import 'ride_settings_screen.dart';

/// Single entry point for a ride. Picks the view from backend state:
/// pending approval → waiting room → live map → summary.
class RideScreen extends ConsumerWidget {
  const RideScreen({super.key, required this.rideId});
  final String rideId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membership = ref.watch(myMembershipProvider(rideId));
    final ride = ref.watch(rideProvider(rideId));

    Widget message(IconData icon, String title, [String? body]) => Scaffold(
      appBar: AppBar(),
      body: CenteredMessage(icon: icon, title: title, body: body),
    );

    if (membership.hasError || ride.hasError) {
      return message(Icons.lock, 'This ride is not available', friendlyError(membership.error ?? ride.error!));
    }
    if (!membership.hasValue || !ride.hasValue) return const Scaffold(body: Loading());
    final m = membership.value, r = ride.value;
    if (r == null) return message(Icons.search_off, 'Ride not found');
    if (m == null) return message(Icons.person_off, 'You are not in this ride', 'Use the invite code to join again.');
    if (m.status == MemberStatus.removed) return message(Icons.block, 'You were removed from this ride');
    if (m.status == MemberStatus.pending) return _PendingView(ride: r);
    if (r.isEnded) {
      final h = ref.watch(historyProvider).value?.where((h) => h.rideId == r.id).firstOrNull;
      return RideSummaryScreen(ride: r, history: h, reason: 'This ride has ended.');
    }

    // Remember as the active ride for "Resume" after an app restart.
    if (ref.read(trackingProvider).rideId != rideId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(trackingProvider.notifier).setActiveRide(rideId));
    }
    return r.status == RideStatus.waiting ? WaitingRoomScreen(ride: r) : LiveMapScreen(rideId: rideId);
  }
}

class _PendingView extends ConsumerWidget {
  const _PendingView({required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: Text(ride.name)),
    body: CenteredMessage(
      icon: Icons.hourglass_top,
      title: 'Waiting for approval',
      body: 'The ride owner needs to approve you. You can’t see other riders until then.',
      action: OutlinedButton(
        onPressed: () async {
          final uid = ref.read(authUserProvider).value!.uid;
          await ref.read(rideRepoProvider).leaveRide(ride.id, uid).catchError((Object _) {});
          if (context.mounted) Navigator.pop(context);
        },
        child: const Text('Cancel request'),
      ),
    ),
  );
}

Future<void> shareInvite(Ride ride) => SharePlus.instance.share(
  ShareParams(
    text:
        'Join my ride “${ride.name}” on RideTogether 🏍️\n'
        'Code: ${ride.code}\n${inviteLink(ride.code)}',
    subject: 'Join ${ride.name}',
  ),
);

class WaitingRoomScreen extends ConsumerWidget {
  const WaitingRoomScreen({super.key, required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(authUserProvider).value?.uid;
    final isOwner = ride.ownerId == uid;
    final members = ref.watch(membersProvider(ride.id)).value ?? const [];
    final active = members.where((m) => m.isActive).toList();
    final pending = members.where((m) => m.status == MemberStatus.pending).toList();
    final locs = ref.watch(locationsProvider(ride.id)).value?.locations ?? const {};
    final now = watchNow(ref);
    final t = Theme.of(context).textTheme;

    return RideScope(
      rideId: ride.id,
      child: Scaffold(
        appBar: AppBar(
          title: Text(ride.name),
          actions: [
            IconButton(
              tooltip: 'Ride settings',
              icon: const Icon(Icons.settings),
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => RideSettingsScreen(rideId: ride.id))),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text('Ride code', style: t.labelLarge),
                    const SizedBox(height: 4),
                    SelectableText(
                      ride.code,
                      style: t.displaySmall?.copyWith(letterSpacing: 6, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: inviteLink(ride.code)));
                              if (context.mounted) showSnack(context, 'Invite link copied');
                            },
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy link'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => shareInvite(ride),
                            icon: const Icon(Icons.share),
                            label: const Text('Invite'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (isOwner && pending.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Join requests', style: t.titleMedium),
              for (final m in pending) PendingRequestTile(rideId: ride.id, member: m),
            ],
            const SizedBox(height: 16),
            Text('Riders (${active.length})', style: t.titleMedium),
            for (final m in active) MemberTile(member: m, location: locs[m.uid], now: now, isMe: m.uid == uid),
            const SizedBox(height: 24),
            if (isOwner)
              FilledButton.icon(
                onPressed: () => ref
                    .read(rideRepoProvider)
                    .startRide(ride.id)
                    .catchError((Object e) => context.mounted ? showSnack(context, friendlyError(e)) : null),
                icon: const Icon(Icons.flag),
                label: const Text('Start ride'),
              )
            else
              const Text(
                'Waiting for the owner to start the ride. You can open the map already.',
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => LiveMapScreen(rideId: ride.id))),
              icon: const Icon(Icons.map),
              label: const Text('Open map'),
            ),
          ],
        ),
      ),
    );
  }
}

class PendingRequestTile extends ConsumerWidget {
  const PendingRequestTile({super.key, required this.rideId, required this.member});
  final String rideId;
  final RideMember member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(rideRepoProvider);
    void onErr(Object e) {
      if (context.mounted) showSnack(context, friendlyError(e));
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: RiderAvatar(uid: member.uid, name: member.name, photoUrl: member.photoUrl),
      title: Text(member.name),
      subtitle: member.bikeName == null ? null : Text(member.bikeName!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Reject',
            icon: const Icon(Icons.close),
            onPressed: () => repo.removeMember(rideId, member.uid).catchError(onErr),
          ),
          IconButton.filled(
            tooltip: 'Approve',
            icon: const Icon(Icons.check),
            onPressed: () => repo.approve(rideId, member.uid).catchError(onErr),
          ),
        ],
      ),
    );
  }
}

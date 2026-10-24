import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/ui.dart';
import '../../domain/ride_logic.dart';
import '../../providers.dart';
import '../history/history_screens.dart';
import '../map/member_tile.dart';
import '../map/osm_map.dart';
import '../profile/profile_screen.dart';
import '../ride/create_ride_screen.dart';
import '../ride/join_ride_screen.dart';
import '../ride/ride_screen.dart';
import '../tracking/tracking_controller.dart';

void openRide(BuildContext context, String rideId) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => RideScreen(rideId: rideId)));

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final activeId = ref.watch(trackingProvider.select((s) => s.rideId));
    final recent = ref.watch(recentRidesProvider);
    final history = ref.watch(historyProvider).value ?? const [];
    final riders = {for (final h in history) ...h.participants}..remove(profile?.name);

    return Scaffold(
      appBar: AppBar(
        title: const Text('RideTogether'),
        actions: [
          IconButton(
            tooltip: 'Profile & settings',
            iconSize: 32,
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
            icon: RiderAvatar(
              uid: profile?.uid ?? '',
              name: profile?.name ?? '',
              photoUrl: profile?.photoUrl,
              radius: 16,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (activeId != null) ...[_ActiveRideCard(rideId: activeId), const SizedBox(height: 16)],
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateRideScreen())),
                  icon: const Icon(Icons.add_road),
                  label: const Text('Create ride'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const JoinRideScreen())),
                  icon: const Icon(Icons.group_add),
                  label: const Text('Join ride'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Recent rides', style: Theme.of(context).textTheme.titleMedium),
          switch (recent) {
            AsyncData(value: final list) when list.isEmpty => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No rides yet. Create one and share the code with your group.'),
            ),
            AsyncData(value: final list) => Column(
              children: [
                for (final r in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.route),
                    title: Text(r.name),
                    subtitle: r.joinedAt == null
                        ? null
                        : Text(MaterialLocalizations.of(context).formatMediumDate(r.joinedAt!)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openRide(context, r.rideId),
                  ),
              ],
            ),
            AsyncError(:final error) => Text(friendlyError(error)),
            _ => const Padding(padding: EdgeInsets.all(16), child: Loading()),
          },
          if (riders.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Recent riders', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final n in riders.take(12))
                  Chip(
                    avatar: CircleAvatar(child: Text(initials(n))),
                    label: Text(n),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: const Text('Ride history'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen())),
          ),
        ],
      ),
    );
  }
}

class _ActiveRideCard extends ConsumerWidget {
  const _ActiveRideCard({required this.rideId});
  final String rideId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ride = ref.watch(rideProvider(rideId)).value;
    if (ride == null || ride.isEnded) return const SizedBox.shrink();
    final members = (ref.watch(membersProvider(rideId)).value ?? const []).where((m) => m.isActive).toList();
    final locs = ref.watch(locationsProvider(rideId)).value?.locations ?? const {};
    final now = watchNow(ref);
    final sharing = members.where((m) => statusOf(locs[m.uid], now).isLive).length;
    final t = Theme.of(context).textTheme;
    final pts = [for (final l in locs.values) LatLng(l.point.lat, l.point.lng)];
    final started = ride.startedAt;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openRide(context, rideId),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pts.isNotEmpty)
              SizedBox(
                height: 140,
                child: IgnorePointer(
                  child: kIsWeb
                      ? OsmMap(
                          initial: locs.values.first.point,
                          fitTo: [for (final l in locs.values) l.point],
                          interactive: false,
                          riders: [
                            for (final l in locs.values)
                              OsmRider(
                                uid: l.uid,
                                name: members.where((m) => m.uid == l.uid).firstOrNull?.name ?? '',
                                point: l.point,
                                live: statusOf(l, now).isLive,
                              ),
                          ],
                        )
                      : GoogleMap(
                          liteModeEnabled: true,
                          initialCameraPosition: CameraPosition(target: pts.first, zoom: 12),
                          markers: {
                            for (final l in locs.values)
                              Marker(markerId: MarkerId(l.uid), position: LatLng(l.point.lat, l.point.lng)),
                          },
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                        ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(ride.name, style: t.titleLarge)),
                      Chip(label: Text(ride.code)),
                    ],
                  ),
                  Text(
                    '${members.length} riders · $sharing sharing live'
                    '${started == null ? ' · not started' : ' · started ${TimeOfDay.fromDateTime(started).format(context)}'
                              ' (${formatDuration(now.difference(started))})'}',
                  ),
                  const SizedBox(height: 8),
                  for (final m in members.take(4)) MemberTile(member: m, location: locs[m.uid], now: now, dense: true),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => openRide(context, rideId),
                    icon: const Icon(Icons.map),
                    label: const Text('Resume active ride'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

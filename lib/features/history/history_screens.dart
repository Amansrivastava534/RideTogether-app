import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/geo.dart';
import '../../core/ui.dart';
import '../../domain/models.dart';
import '../../domain/ride_logic.dart';
import '../../providers.dart';
import '../map/osm_map.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    final consent = ref.watch(profileProvider).value?.historyConsent ?? false;
    final uid = ref.watch(authUserProvider).value?.uid;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ride history'),
        actions: [
          if (history.value?.isNotEmpty ?? false)
            IconButton(
              tooltip: 'Delete all history',
              icon: const Icon(Icons.delete_sweep),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Delete all ride history?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete all')),
                    ],
                  ),
                );
                if (ok == true && uid != null) await ref.read(userRepoProvider).deleteAllHistory(uid);
              },
            ),
        ],
      ),
      body: switch (history) {
        AsyncData(value: final list) when list.isEmpty => CenteredMessage(
          icon: Icons.route,
          title: 'No saved rides',
          body: consent
              ? 'Routes you ride while sharing will appear here after the ride ends.'
              : 'Route saving is off. Turn on “Save my routes” in Profile & settings to keep your rides.',
        ),
        AsyncData(value: final list) => ListView(
          children: [
            for (final h in list)
              ListTile(
                leading: const Icon(Icons.route),
                title: Text(h.name),
                subtitle: Text(
                  '${MaterialLocalizations.of(context).formatMediumDate(h.startedAt)} · '
                  '${formatDistance(h.distanceMeters)} · ${formatDuration(h.duration)}',
                ),
                onTap: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => HistoryDetailScreen(history: h))),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Saved rides are deleted automatically after ${RideConfig.historyTtl.inDays} days.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        AsyncError(:final error) => CenteredMessage(
          icon: Icons.cloud_off,
          title: 'Could not load history',
          body: friendlyError(error),
        ),
        _ => const Loading(),
      },
    );
  }
}

class HistoryDetailScreen extends ConsumerWidget {
  const HistoryDetailScreen({super.key, required this.history});
  final RideHistory history;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      title: Text(history.name),
      actions: [
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete),
          onPressed: () async {
            final uid = ref.read(authUserProvider).value!.uid;
            await ref.read(userRepoProvider).deleteHistory(uid, history.rideId);
            if (context.mounted) Navigator.pop(context);
          },
        ),
      ],
    ),
    body: ListView(
      children: [
        _RouteMap(route: history.route),
        _Stats(history: history),
      ],
    ),
  );
}

/// Shown when a ride ends or the user leaves it.
class RideSummaryScreen extends StatelessWidget {
  const RideSummaryScreen({super.key, required this.ride, required this.history, required this.reason});
  final Ride ride;
  final RideHistory? history;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final h = history;
    return Scaffold(
      appBar: AppBar(title: const Text('Ride summary')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ride.name, style: Theme.of(context).textTheme.headlineSmall),
                Text(reason),
                const SizedBox(height: 4),
                const Text('Location sharing has stopped.', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (h != null) ...[
            _RouteMap(route: h.route),
            _Stats(history: h),
          ] else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No route was saved for this ride. Turn on “Save my routes” in Profile & settings to keep future rides.',
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              child: const Text('Back to home'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteMap extends StatelessWidget {
  const _RouteMap({required this.route});
  final List<Coord> route;

  @override
  Widget build(BuildContext context) {
    if (route.length < 2) return const SizedBox.shrink();
    if (kIsWeb) {
      return SizedBox(
        height: 320,
        child: OsmMap(
          initial: route.first,
          fitTo: route,
          route: route,
          pins: [(route.first, const Color(0xFF2E7D32)), (route.last, const Color(0xFFC62828))],
        ),
      );
    }
    final pts = [for (final p in route) LatLng(p.lat, p.lng)];
    final bounds = LatLngBounds(
      southwest: LatLng(route.map((p) => p.lat).reduce(math.min), route.map((p) => p.lng).reduce(math.min)),
      northeast: LatLng(route.map((p) => p.lat).reduce(math.max), route.map((p) => p.lng).reduce(math.max)),
    );
    return SizedBox(
      height: 320,
      child: GoogleMap(
        initialCameraPosition: CameraPosition(target: pts.first, zoom: 11),
        onMapCreated: (c) => Future.delayed(
          const Duration(milliseconds: 300),
          () => c.animateCamera(CameraUpdate.newLatLngBounds(bounds, 40)),
        ),
        polylines: {
          Polyline(
            polylineId: const PolylineId('route'),
            points: pts,
            width: 5,
            color: Theme.of(context).colorScheme.primary,
          ),
        },
        markers: {
          Marker(
            markerId: const MarkerId('start'),
            position: pts.first,
            infoWindow: const InfoWindow(title: 'Start'),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          ),
          Marker(
            markerId: const MarkerId('end'),
            position: pts.last,
            infoWindow: const InfoWindow(title: 'End'),
          ),
        },
        zoomControlsEnabled: false,
        mapToolbarEnabled: false,
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.history});
  final RideHistory history;

  @override
  Widget build(BuildContext context) {
    final loc = MaterialLocalizations.of(context);
    return Column(
      children: [
        ListTile(leading: const Icon(Icons.event), title: Text(loc.formatFullDate(history.startedAt))),
        ListTile(
          leading: const Icon(Icons.timer),
          title: Text(formatDuration(history.duration)),
          subtitle: const Text('Duration'),
        ),
        ListTile(
          leading: const Icon(Icons.straighten),
          title: Text('≈ ${formatDistance(history.distanceMeters)}'),
          subtitle: const Text('Approximate distance from your recorded GPS points'),
        ),
        ListTile(
          leading: const Icon(Icons.groups),
          title: Text(history.participants.join(', ')),
          subtitle: const Text('Riders'),
        ),
      ],
    );
  }
}

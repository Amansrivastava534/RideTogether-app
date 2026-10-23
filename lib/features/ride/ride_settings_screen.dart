import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/geo.dart';
import '../../core/ui.dart';
import '../../domain/models.dart';
import '../../providers.dart';
import '../tracking/tracking_controller.dart';
import 'ride_flow.dart';
import 'ride_screen.dart';

/// Ride settings, membership management and permission status.
class RideSettingsScreen extends ConsumerWidget {
  const RideSettingsScreen({super.key, required this.rideId});
  final String rideId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ride = ref.watch(rideProvider(rideId)).value;
    if (ride == null) return const Scaffold(body: Loading());
    final uid = ref.watch(authUserProvider).value?.uid;
    final isOwner = ride.ownerId == uid;
    final repo = ref.read(rideRepoProvider);
    final members = ref.watch(membersProvider(rideId)).value ?? const [];
    final settings = ref.watch(settingsProvider);
    void onErr(Object e) {
      if (context.mounted) showSnack(context, friendlyError(e));
    }

    return RideScope(
      rideId: rideId,
      child: Scaffold(
        appBar: AppBar(title: const Text('Ride settings')),
        body: ListView(
          children: [
            ListTile(
              title: Text(ride.name),
              subtitle: Text('Code ${ride.code}'),
              trailing: IconButton(icon: const Icon(Icons.share), onPressed: () => shareInvite(ride)),
            ),
            if (isOwner) ...[
              SwitchListTile(
                title: const Text('Approve new riders'),
                subtitle: const Text('People with the code must be approved before seeing anyone.'),
                value: ride.requireApproval,
                onChanged: (v) => repo.updateSettings(ride, requireApproval: v).catchError(onErr),
              ),
              ListTile(
                title: const Text('“Far from group” alert distance'),
                subtitle: const Text('Straight-line distance from the middle of the group'),
                trailing: Text(formatDistance(ride.fallBehindMeters)),
                onTap: () async {
                  final v = await showDialog<double>(
                    context: context,
                    builder: (_) => _DistancePicker(initial: ride.fallBehindMeters),
                  );
                  if (v != null) await repo.updateSettings(ride, fallBehindMeters: v).catchError(onErr);
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('New invite code'),
                subtitle: const Text('The old code and link stop working immediately.'),
                onTap: () => repo.regenerateInvite(ride, uid!).catchError(onErr),
              ),
              const Divider(),
              const ListTile(title: Text('Riders')),
              for (final m in members.where((m) => m.status != MemberStatus.removed))
                m.status == MemberStatus.pending
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: PendingRequestTile(rideId: rideId, member: m),
                      )
                    : ListTile(
                        leading: RiderAvatar(uid: m.uid, name: m.name, photoUrl: m.photoUrl),
                        title: Text(m.name),
                        subtitle: Text(m.isOwner ? 'Owner' : 'Member'),
                        trailing: m.isOwner
                            ? null
                            : TextButton(
                                onPressed: () => repo.removeMember(rideId, m.uid).catchError(onErr),
                                child: const Text('Remove'),
                              ),
                      ),
            ],
            const Divider(),
            const ListTile(title: Text('Location')),
            SwitchListTile(
              title: const Text('Keep sharing in the background'),
              subtitle: const Text('Takes effect next time you start sharing.'),
              value: settings.backgroundSharing,
              onChanged: ref.read(settingsProvider.notifier).setBackgroundSharing,
            ),
            FutureBuilder(
              future: ref.read(trackingProvider.notifier).checkAccess(),
              builder: (context, snap) => ListTile(
                leading: const Icon(Icons.my_location),
                title: const Text('Location permission'),
                subtitle: Text(switch (snap.data) {
                  LocationAccess.granted => 'Allowed while using the app',
                  LocationAccess.serviceDisabled => 'Location services are off',
                  LocationAccess.deniedForever => 'Blocked — enable it in system settings',
                  LocationAccess.denied => 'Not granted yet',
                  null => '…',
                }),
                trailing: const Icon(Icons.open_in_new),
                onTap: Geolocator.openAppSettings,
              ),
            ),
            const ListTile(
              leading: Icon(Icons.battery_alert),
              title: Text('Battery optimisation'),
              subtitle: Text(
                'Some phones (Xiaomi, Oppo, Vivo, Samsung…) stop background apps aggressively. If friends see you as '
                '“Location unavailable” while your screen is off, set RideTogether’s battery usage to “Unrestricted” '
                'in system settings. Updates while in the background are best-effort and can be delayed by the OS.',
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: isOwner
                  ? FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                      onPressed: () => confirmEnd(context, ref, ride),
                      child: const Text('End ride for everyone'),
                    )
                  : OutlinedButton(onPressed: () => confirmLeave(context, ref, ride), child: const Text('Leave ride')),
            ),
          ],
        ),
      ),
    );
  }
}

class _DistancePicker extends StatefulWidget {
  const _DistancePicker({required this.initial});
  final double initial;
  @override
  State<_DistancePicker> createState() => _DistancePickerState();
}

class _DistancePickerState extends State<_DistancePicker> {
  late double _v = widget.initial.clamp(500, 10000);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Alert when a rider is this far from the group'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(formatDistance(_v), style: Theme.of(context).textTheme.headlineSmall),
        Slider(min: 500, max: 10000, divisions: 19, value: _v, onChanged: (v) => setState(() => _v = v)),
        const Text(
          'Straight-line distance from the middle of the group. Riders must stay beyond it for a minute '
          'with good GPS before anyone is alerted.',
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, _v), child: const Text('Save')),
    ],
  );
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart' show MapController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/geo.dart';
import '../../core/ui.dart';
import '../../domain/models.dart';
import '../../domain/ride_logic.dart';
import '../../providers.dart';
import '../ride/ride_flow.dart';
import '../ride/ride_settings_screen.dart';
import '../tracking/tracking_controller.dart';
import 'map_camera.dart';
import 'map_panel.dart';
import 'marker_icons.dart';
import 'osm_map.dart';

const _animDuration = Duration(milliseconds: 900);

/// Jumps larger than this are not animated (GPS teleport / reconnect).
const _maxAnimatedJumpM = 2000.0;

class _Anim {
  _Anim(this.from, this.to, this.start);
  final Coord from;
  final Coord to;
  final DateTime start;

  Coord at(DateTime now) {
    final t = (now.difference(start).inMicroseconds / _animDuration.inMicroseconds).clamp(0.0, 1.0);
    final e = Curves.easeInOut.transform(t);
    return Coord(from.lat + (to.lat - from.lat) * e, from.lng + (to.lng - from.lng) * e);
  }

  bool done(DateTime now) => now.difference(start) >= _animDuration;
}

class LiveMapScreen extends ConsumerStatefulWidget {
  const LiveMapScreen({super.key, required this.rideId});
  final String rideId;
  @override
  ConsumerState<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends ConsumerState<LiveMapScreen> with SingleTickerProviderStateMixin {
  // Google Maps on Android/iOS; OpenStreetMap on the web (no key there).
  GoogleMapController? _gmap;
  final _osm = MapController();
  RideCamera? _cam;
  final _icons = MarkerIcons();
  final _detector = FallBehindDetector();
  final _anims = <String, _Anim>{};
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastFrame = Duration.zero;
  String? _selected;
  final _banners = <String>{};
  bool _fitted = false;
  bool _locationGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final tracking = ref.read(trackingProvider.notifier);
    final granted = await tracking.checkAccess() == LocationAccess.granted;
    if (!mounted) return;
    setState(() => _locationGranted = granted);
    // Recovery: the app was restarted while sharing → resume, and say so.
    final st = ref.read(trackingProvider);
    if (granted && tracking.wasSharing && st.phase == SharingPhase.off && st.rideId == widget.rideId) {
      await tracking.startSharing(widget.rideId);
      if (mounted) showSnack(context, 'Location sharing resumed');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _gmap?.dispose();
    _osm.dispose();
    super.dispose();
  }

  // --- smooth marker movement ----------------------------------------------

  Coord? _displayed(String uid, Map<String, LiveLocation> locs, DateTime now) =>
      _anims[uid]?.at(now) ?? locs[uid]?.point;

  void _onLocations(Map<String, LiveLocation>? prev, Map<String, LiveLocation> next) {
    final now = DateTime.now();
    for (final MapEntry(key: uid, value: l) in next.entries) {
      final from = _anims[uid]?.at(now) ?? prev?[uid]?.point;
      if (from == null || from == l.point || distanceMeters(from, l.point) > _maxAnimatedJumpM) {
        _anims.remove(uid);
      } else {
        _anims[uid] = _Anim(from, l.point, now);
      }
    }
    _anims.removeWhere((uid, _) => !next.containsKey(uid));
    if (_anims.isNotEmpty && !_ticker.isActive) _ticker.start();
    _evaluateGroup(next, now);
  }

  void _onTick(Duration elapsed) {
    // ~20 fps is plenty for map markers and keeps platform-channel traffic low.
    if (elapsed - _lastFrame < const Duration(milliseconds: 50)) return;
    _lastFrame = elapsed;
    final now = DateTime.now();
    _anims.removeWhere((_, a) => a.done(now));
    if (_anims.isEmpty) {
      _ticker.stop();
      _lastFrame = Duration.zero;
    }
    setState(() {});
  }

  // --- group / fall-behind -------------------------------------------------

  void _evaluateGroup(Map<String, LiveLocation> locs, DateTime now) {
    final ride = ref.read(rideProvider(widget.rideId)).value;
    final members = ref.read(membersProvider(widget.rideId)).value ?? const [];
    if (ride == null) return;
    final active = {
      for (final m in members)
        if (m.isActive) m.uid,
    };
    final usable = usableLocations(locs.values.where((l) => active.contains(l.uid)), now);
    final newly = _detector.update(groupSpread(usable), ride.fallBehindMeters, now);
    final me = ref.read(authUserProvider).value?.uid;
    setState(() {
      _banners
        ..retainAll(_detector.flagged)
        ..addAll(newly.where((u) => u != me));
    });
  }

  // --- camera ---------------------------------------------------------------

  Coord? _myPoint(Map<String, LiveLocation> locs) {
    final uid = ref.read(authUserProvider).value?.uid;
    return ref.read(trackingProvider).lastFix?.point ?? locs[uid]?.point;
  }

  void _centerOnMe(Map<String, LiveLocation> locs) {
    final p = _myPoint(locs);
    if (p == null) {
      showSnack(context, 'Your location isn’t available yet. Start sharing to see yourself.');
      return;
    }
    _cam?.moveTo(p, zoom: 15);
  }

  void _fitAll(Map<String, LiveLocation> locs) {
    final pts = [for (final l in locs.values) l.point, ?_myPoint(locs)];
    final h = MediaQuery.sizeOf(context).height;
    // Keep riders clear of the top bar and the bottom panel.
    _cam?.fit(pts, padding: EdgeInsets.fromLTRB(48, 150, 72, h * panelInitialSize + 48));
  }

  void _select(String uid, Map<String, LiveLocation> locs) {
    setState(() => _selected = uid);
    final p = locs[uid]?.point;
    if (p != null) _cam?.moveTo(p);
  }

  // --- navigation hand-off ------------------------------------------------

  /// Hands off to Google Maps turn-by-turn (two-wheeler mode where supported).
  Future<void> _navigate(Coord to) async {
    final uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '${to.lat},${to.lng}',
      'travelmode': 'two-wheeler',
    });
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      showSnack(context, 'Could not open Google Maps.');
    }
  }

  // --- markers --------------------------------------------------------------

  Set<Marker> _markers(List<RideMember> members, Map<String, LiveLocation> locs, DateTime now, String? me) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final out = <Marker>{};
    for (final m in members) {
      final l = locs[m.uid];
      if (!m.isActive || l == null) continue;
      // Our own position is the blue dot when permission allows it.
      if (m.uid == me && _locationGranted && !kIsWeb) continue;
      final status = statusOf(l, now);
      final live = status.isLive;
      final heading = live ? l.heading : null;
      final key = MarkerIcons.keyFor(m.uid, m.name, live: live, heading: heading);
      var icon = _icons.cached(key);
      if (icon == null) {
        _icons.get(m.uid, m.name, live: live, heading: heading, dpr: dpr).then((_) {
          if (mounted) setState(() {});
        });
        icon = BitmapDescriptor.defaultMarkerWithHue(HSVColor.fromColor(riderColor(m.uid)).hue);
      }
      final p = _displayed(m.uid, locs, now)!;
      out.add(
        Marker(
          markerId: MarkerId(m.uid),
          position: LatLng(p.lat, p.lng),
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          alpha: live ? 1 : 0.65,
          zIndexInt: m.uid == _selected ? 2 : (live ? 1 : 0),
          consumeTapEvents: true,
          infoWindow: InfoWindow(title: m.name, snippet: status.label),
          onTap: () => _select(m.uid, locs),
        ),
      );
    }
    return out;
  }

  /// Web markers. Includes ourselves, since browsers get no native blue dot.
  List<OsmRider> _osmRiders(List<RideMember> members, Map<String, LiveLocation> locs, DateTime now) => [
    for (final m in members)
      if (locs[m.uid] case final l?)
        OsmRider(
          uid: m.uid,
          name: m.name,
          point: _displayed(m.uid, locs, now)!,
          live: statusOf(l, now).isLive,
          heading: statusOf(l, now).isLive ? l.heading : null,
          selected: m.uid == _selected,
          onTap: () => _select(m.uid, locs),
        ),
  ];

  @override
  Widget build(BuildContext context) {
    final rideId = widget.rideId;
    final ride = ref.watch(rideProvider(rideId)).value;
    final members = ref.watch(membersProvider(rideId)).value ?? const [];
    final locData = ref.watch(locationsProvider(rideId)).value;
    final locs = locData?.locations ?? const <String, LiveLocation>{};
    final tracking = ref.watch(trackingProvider);
    final me = ref.watch(authUserProvider).value?.uid;
    final now = watchNow(ref);
    final dark = Theme.of(context).brightness == Brightness.dark;

    ref.listen(locationsProvider(rideId), (prev, next) {
      final n = next.value?.locations;
      if (n == null) return;
      _onLocations(prev?.value?.locations, n);
      if (!_fitted && n.isNotEmpty && _cam != null) {
        _fitted = true;
        _fitAll(n);
      }
    });
    ref.listen(clockProvider, (_, next) {
      final current = ref.read(locationsProvider(rideId)).value?.locations ?? const {};
      _evaluateGroup(current, next.value ?? DateTime.now());
    });

    if (ride == null) return const Scaffold(body: Loading());

    final active = members.where((m) => m.isActive).toList();
    final liveCount = active.where((m) => statusOf(locs[m.uid], now).isLive).length;
    final myPoint = _myPoint(locs);
    final activeIds = {for (final m in active) m.uid};
    final spread = groupSpread(usableLocations(locs.values.where((l) => activeIds.contains(l.uid)), now));
    final h = MediaQuery.sizeOf(context).height;
    final initial = myPoint ?? locs.values.firstOrNull?.point ?? const Coord(22.5, 79); // India

    return RideScope(
      rideId: rideId,
      onShowRider: (uid) => _select(uid, locs),
      child: Scaffold(
        body: Stack(
          children: [
            if (kIsWeb)
              OsmMap(
                controller: _osm,
                initial: initial,
                initialZoom: myPoint == null && locs.isEmpty ? 5 : 14,
                riders: _osmRiders(active, locs, now),
                attributionBottom: h * panelInitialSize,
                onMapTap: () => setState(() => _selected = null),
                onReady: () {
                  _cam = OsmCamera(_osm);
                  if (locs.isNotEmpty && !_fitted) {
                    _fitted = true;
                    // Next frame: moving the camera before the tile layer's
                    // first frame leaves flutter_map's tiles stuck (grey).
                    WidgetsBinding.instance.addPostFrameCallback((_) => _fitAll(locs));
                  }
                },
              )
            else
              GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: LatLng(initial.lat, initial.lng),
                  zoom: myPoint == null && locs.isEmpty ? 5 : 14,
                ),
                onMapCreated: (c) {
                  _gmap = c;
                  _cam = GoogleCamera(c);
                  if (locs.isNotEmpty && !_fitted) {
                    _fitted = true;
                    _fitAll(locs);
                  }
                },
                style: dark ? _darkMapStyle : null,
                markers: _markers(active, locs, now, me),
                myLocationEnabled: _locationGranted && !kIsWeb,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                compassEnabled: true,
                onTap: (_) => setState(() => _selected = null),
                padding: EdgeInsets.only(bottom: h * panelInitialSize, top: 110),
              ),
            SafeArea(
              child: Column(
                children: [
                  _TopBar(ride: ride, liveCount: liveCount, total: active.length, sharing: tracking.phase, now: now),
                  if (locData?.fromCache ?? false)
                    const _Banner(icon: Icons.cloud_off, text: 'Offline — showing last known positions'),
                  if (tracking.error != null) _Banner(icon: Icons.gps_off, text: tracking.error!),
                  if (kIsWeb && tracking.isSharing)
                    const _Banner(
                      icon: Icons.phone_iphone,
                      text: 'Keep this page open — sharing pauses if you lock the phone or switch apps.',
                    ),
                  for (final uid in _banners)
                    _Banner(
                      icon: Icons.warning_amber,
                      text: _fallBehindText(uid, members, spread),
                      onTap: () => _select(uid, locs),
                      onClose: () => setState(() => _banners.remove(uid)),
                    ),
                ],
              ),
            ),
            Positioned(
              right: 12,
              bottom: h * panelInitialSize + 12,
              child: Column(
                children: [
                  _MapButton(icon: Icons.add, tooltip: 'Zoom in', onTap: () => _cam?.zoomBy(1)),
                  _MapButton(icon: Icons.remove, tooltip: 'Zoom out', onTap: () => _cam?.zoomBy(-1)),
                  const SizedBox(height: 8),
                  _MapButton(icon: Icons.groups, tooltip: 'Show everyone', onTap: () => _fitAll(locs)),
                  _MapButton(icon: Icons.my_location, tooltip: 'Center on me', onTap: () => _centerOnMe(locs)),
                ],
              ),
            ),
            RidePanel(
              ride: ride,
              members: active,
              locations: locs,
              now: now,
              myUid: me,
              myPoint: myPoint,
              spread: spread,
              flagged: _detector.flagged,
              selected: _selected,
              onSelect: (uid) => _select(uid, locs),
              onCloseSelected: () => setState(() => _selected = null),
              onNavigate: (uid) {
                final p = locs[uid]?.point;
                if (p != null) _navigate(p);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _fallBehindText(String uid, List<RideMember> members, Map<String, RiderSpread> spread) {
    final name = members.where((m) => m.uid == uid).firstOrNull?.name ?? 'A rider';
    final s = spread[uid];
    if (s == null) return '$name is far from the group';
    final where = switch (s.alongTrackM) {
      final a? when a < 0 => 'behind',
      final a? when a > 0 => 'ahead of',
      _ => 'away from',
    };
    return '$name is ≈ ${formatDistance(s.distanceFromGroupM)} $where the group';
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.ride,
    required this.liveCount,
    required this.total,
    required this.sharing,
    required this.now,
  });
  final Ride ride;
  final int liveCount;
  final int total;
  final SharingPhase sharing;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (pillColor, pillText) = switch (sharing) {
      SharingPhase.sharing => (const Color(0xFF2E7D32), 'You’re sharing'),
      SharingPhase.paused => (const Color(0xFFF9A825), 'Paused'),
      SharingPhase.off => (scheme.error, 'Not sharing'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(16),
        color: scheme.surface,
        child: Row(
          children: [
            const BackButton(),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ride.name, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                  Text(
                    '$liveCount/$total live · ${ride.code}'
                    '${ride.startedAt == null ? '' : ' · ${formatDuration(now.difference(ride.startedAt!))}'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: pillColor, borderRadius: BorderRadius.circular(20)),
                child: Text(
                  pillText,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Ride settings',
              icon: const Icon(Icons.settings),
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => RideSettingsScreen(rideId: ride.id))),
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.onTap, this.onClose});
  final IconData icon;
  final String text;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    child: Material(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        dense: true,
        leading: Icon(icon),
        title: Text(text),
        onTap: onTap,
        trailing: onClose == null ? null : IconButton(icon: const Icon(Icons.close), onPressed: onClose),
      ),
    ),
  );
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      elevation: 3,
      shape: const CircleBorder(),
      color: Theme.of(context).colorScheme.surface,
      child: IconButton(
        iconSize: 26,
        padding: const EdgeInsets.all(12),
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onTap,
      ),
    ),
  );
}

const _darkMapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#242f3e"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#d0d0d0"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#242f3e"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#d59563"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#38414e"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#212a37"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#746855"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#f3d19c"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#17263c"}]}
]
''';

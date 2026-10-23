import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/ride_repository.dart';
import '../../domain/ride_logic.dart';
import '../../providers.dart';
import 'ride_screen.dart';

class JoinRideScreen extends ConsumerStatefulWidget {
  const JoinRideScreen({super.key, this.initialCode});

  /// Pre-filled from an invite link.
  final String? initialCode;
  @override
  ConsumerState<JoinRideScreen> createState() => _JoinRideScreenState();
}

class _JoinRideScreenState extends ConsumerState<JoinRideScreen> {
  late final _code = TextEditingController(text: widget.initialCode ?? '');
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialCode != null) WidgetsBinding.instance.addPostFrameCallback((_) => _join());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = inviteCodeFromText(_code.text);
    if (code == null) {
      setState(() => _error = 'Codes are 8 letters/digits, e.g. K7QM-4XPA');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(rideRepoProvider);
      final inv = await repo.lookupInvite(code);
      final rideId = await repo.joinRide(ref.read(profileProvider).value!, inv);
      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => RideScreen(rideId: rideId)));
      }
    } on RideException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Join a ride')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Enter the ride code or paste the invite link you received.'),
        const SizedBox(height: 16),
        TextField(
          controller: _code,
          autofocus: widget.initialCode == null,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontSize: 24, letterSpacing: 4, fontWeight: FontWeight.w600),
          decoration: InputDecoration(labelText: 'Ride code', errorText: _error, errorMaxLines: 3),
          onSubmitted: (_) => _join(),
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: _busy ? null : _join, child: const Text('Join ride')),
        if (_busy) const Padding(padding: EdgeInsets.all(16), child: Loading()),
      ],
    ),
  );
}

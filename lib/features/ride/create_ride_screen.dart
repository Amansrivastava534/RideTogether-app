import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../domain/models.dart';
import '../../providers.dart';
import 'ride_screen.dart';

class CreateRideScreen extends ConsumerStatefulWidget {
  const CreateRideScreen({super.key});
  @override
  ConsumerState<CreateRideScreen> createState() => _CreateRideScreenState();
}

class _CreateRideScreenState extends ConsumerState<CreateRideScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  bool _requireApproval = true;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final me = ref.read(profileProvider).value!;
      final id = await ref
          .read(rideRepoProvider)
          .createRide(me: me, name: _name.text, requireApproval: _requireApproval);
      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => RideScreen(rideId: id)));
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Could not create ride: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Create a ride')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextFormField(
            controller: _name,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Ride name', hintText: 'Jodhpur Road Trip'),
            validator: Ride.validateName,
            onFieldSubmitted: (_) => _create(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Approve riders before they join'),
            subtitle: const Text(
              'Recommended. People with the code must be approved by you before they can see anyone.',
            ),
            value: _requireApproval,
            onChanged: (v) => setState(() => _requireApproval = v),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy ? null : _create, child: const Text('Create ride')),
        ],
      ),
    ),
  );
}

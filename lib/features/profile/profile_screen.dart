import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../domain/models.dart';
import '../../domain/ride_logic.dart';
import '../../providers.dart';
import '../history/history_screens.dart';
import '../tracking/tracking_controller.dart';

/// First-run profile setup ([setup] = true) and the profile & app settings
/// screen.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key, this.setup = false});
  final bool setup;
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _bike;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider).value;
    final user = ref.read(authUserProvider).value;
    _name = TextEditingController(text: p?.name ?? user?.displayName ?? '');
    _bike = TextEditingController(text: p?.bikeName ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _bike.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final user = ref.read(authUserProvider).value!;
    final current = ref.read(profileProvider).value;
    setState(() => _saving = true);
    try {
      final bike = _bike.text.trim();
      await ref
          .read(userRepoProvider)
          .saveProfile(
            UserProfile(
              uid: user.uid,
              name: _name.text.trim(),
              photoUrl: user.photoURL,
              bikeName: bike.isEmpty ? null : bike.substring(0, bike.length.clamp(0, 40)),
              historyConsent: current?.historyConsent ?? false,
            ),
          );
      if (mounted && !widget.setup) showSnack(context, 'Profile saved');
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setConsent(UserProfile p, bool v) async {
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Save your ride routes?'),
          content: Text(
            'While you share your location, RideTogether will keep a simplified copy of your own route so you can '
            'see it later in Ride history. Only you can see it. Routes are deleted automatically after '
            '${RideConfig.historyTtl.inDays} days, and you can delete them at any time.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No thanks')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save routes')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await ref.read(userRepoProvider).saveProfile(p.copyWith(historyConsent: v));
  }

  Future<void> _deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This deletes your profile, ride history and memberships, and stops any location sharing. '
          'It cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(trackingProvider.notifier).stopSharing();
      await ref.read(userRepoProvider).deleteAccount();
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showSnack(context, 'Could not delete account: ${friendlyError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authUserProvider).value;
    final profile = ref.watch(profileProvider).value;
    final settings = ref.watch(settingsProvider);
    final form = Form(
      key: _form,
      child: Column(
        children: [
          RiderAvatar(uid: user?.uid ?? '', name: _name.text, photoUrl: user?.photoURL, radius: 40),
          const SizedBox(height: 24),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Your name (shown to riders)'),
            validator: UserProfile.validateName,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _bike,
            decoration: const InputDecoration(labelText: 'Bike (optional)', hintText: 'e.g. Royal Enfield Himalayan'),
            maxLength: 40,
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _saving ? null : _save, child: Text(widget.setup ? 'Continue' : 'Save profile')),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(widget.setup ? 'Create your profile' : 'Profile & settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          form,
          if (!widget.setup && profile != null) ...[
            const SizedBox(height: 24),
            const Divider(),
            ListTile(
              title: const Text('Map & app theme'),
              trailing: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode)),
                  ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode)),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (s) => ref.read(settingsProvider.notifier).setThemeMode(s.first),
              ),
            ),
            if (!kIsWeb)
              SwitchListTile(
                title: const Text('Keep sharing in the background'),
                subtitle: const Text(
                  'Shows a persistent notification on Android. If off, others will see you as '
                  '“Location unavailable” while the app is not open. Applies the next time you start sharing.',
                ),
                value: settings.backgroundSharing,
                onChanged: ref.read(settingsProvider.notifier).setBackgroundSharing,
              ),
            SwitchListTile(
              title: const Text('Save my routes (ride history)'),
              subtitle: Text('Only you can see them. Auto-deleted after ${RideConfig.historyTtl.inDays} days.'),
              value: profile.historyConsent,
              onChanged: (v) => _setConsent(profile, v),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Ride history'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () async {
                await ref.read(trackingProvider.notifier).stopSharing();
                await ref.read(userRepoProvider).signOut();
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
              title: Text('Delete account', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: _deleteAccount,
            ),
          ],
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../providers.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showSnack(context, 'Sign-in failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(userRepoProvider);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(Icons.two_wheeler, size: 88, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('RideTogether', style: t.headlineLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'See your whole group on one map.\nNo more “where are you?” calls.',
                style: t.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              const _PrivacyNote(),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : () => _run(repo.signInWithGoogle),
                icon: const Icon(Icons.login),
                label: const Text('Continue with Google'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : () => _run(repo.signInAsGuest),
                child: const Text('Join as guest'),
              ),
              if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: Loading()),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'Your location is shared only while you choose to share it, and only with members of the ride '
        'you joined. You can pause or stop at any time. Guests lose their data if they sign out.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
  );
}

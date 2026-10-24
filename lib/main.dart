import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Invite links are real paths (/j/CODE), not #fragments.
    usePathUrlStrategy();
  }
  await Firebase.initializeApp(
    // Same-origin auth handler: Safari blocks the cross-site storage that a
    // firebaseapp.com redirect would need.
    options: kIsWeb
        ? DefaultFirebaseOptions.currentPlatform.copyWith(authDomain: 'ridetogether-4590.web.app')
        : DefaultFirebaseOptions.currentPlatform,
  );
  // Offline cache: the map keeps showing last-known data (marked stale) and
  // writes are queued while connectivity drops.
  FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true);
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(overrides: [prefsProvider.overrideWithValue(prefs)], child: const RideTogetherApp()));
}

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../domain/models.dart';
import '../domain/ride_logic.dart';

/// Auth, profile, FCM token and ride-history access for the signed-in user.
class UserRepository {
  UserRepository(this._auth, this._db);

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;
  bool _googleReady = false;

  DocumentReference<Map<String, dynamic>> _user(String uid) => _db.collection('users').doc(uid);
  CollectionReference<Map<String, dynamic>> _history(String uid) => _user(uid).collection('history');

  Stream<User?> authChanges() => _auth.authStateChanges();

  Future<void> signInWithGoogle() async => _auth.signInWithCredential(await _googleCredential());

  Future<AuthCredential> _googleCredential() async {
    final gsi = GoogleSignIn.instance;
    if (!_googleReady) {
      // Client IDs come from google-services.json / GoogleService-Info.plist.
      await gsi.initialize();
      _googleReady = true;
    }
    final account = await gsi.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) throw StateError('Google did not return an ID token');
    return GoogleAuthProvider.credential(idToken: idToken);
  }

  Future<void> signInAsGuest() => _auth.signInAnonymously();

  Future<void> signOut() async {
    if (_googleReady) await GoogleSignIn.instance.signOut();
    await _auth.signOut();
  }

  Stream<UserProfile?> watchProfile(String uid) =>
      _user(uid).snapshots().map((s) => s.exists ? UserProfile.fromMap(uid, s.data()!) : null);

  Future<void> saveProfile(UserProfile p) =>
      _user(p.uid).set({...p.toMap(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  /// Stores the FCM token so Cloud Functions can push SOS / join requests.
  /// Tokens live on the private user doc, never on member docs.
  Future<void> registerPushToken(String uid) async {
    final fcm = FirebaseMessaging.instance;
    await fcm.requestPermission();
    // ponytail: classic registration token (deprecated in favour of FID
    // direct-send); migrate once firebase-admin supports FID targets.
    // ignore: deprecated_member_use
    final token = await fcm.getToken();
    if (token == null) return;
    await _user(uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
    }, SetOptions(merge: true));
  }

  // --- history -------------------------------------------------------------

  Stream<List<RideHistory>> watchHistory(String uid) => _history(uid)
      .orderBy('endedAt', descending: true)
      .limit(50)
      .snapshots()
      .map((q) => [for (final d in q.docs) RideHistory.fromMap(d.id, d.data())]);

  Future<void> saveHistory(String uid, RideHistory h) => _history(
    uid,
  ).doc(h.rideId).set({...h.toMap(), 'expireAt': Timestamp.fromDate(h.endedAt.add(RideConfig.historyTtl))});

  Future<void> deleteHistory(String uid, String rideId) => _history(uid).doc(rideId).delete();

  Future<void> deleteAllHistory(String uid) async {
    final docs = await _history(uid).get();
    for (var i = 0; i < docs.docs.length; i += 400) {
      final batch = _db.batch();
      for (final d in docs.docs.skip(i).take(400)) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }
  }

  /// Deletes the user's own data, then the auth account. Ride metadata the
  /// user took part in expires via TTL (see README retention policy).
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final uid = user.uid;
    await deleteAllHistory(uid);
    final recent = await _user(uid).collection('recentRides').get();
    for (final r in recent.docs) {
      // Best effort: owner docs / removed docs are protected by rules.
      await _db.collection('rides').doc(r.id).collection('members').doc(uid).delete().catchError((_) {});
      await r.reference.delete();
    }
    await _user(uid).delete();
    try {
      await user.delete();
    } on FirebaseAuthException catch (e) {
      if (e.code != 'requires-recent-login') rethrow;
      if (user.isAnonymous) rethrow;
      // Re-authenticate the same user (a different Google account fails).
      await user.reauthenticateWithCredential(await _googleCredential());
      await user.delete();
    }
    if (_googleReady) await GoogleSignIn.instance.signOut();
  }
}

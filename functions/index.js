// Push notifications only. Membership and location access are enforced by
// firestore.rules; these functions re-check membership before notifying so a
// push can be trusted to come from a real ride member.
const { setGlobalOptions } = require('firebase-functions/v2');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { logger } = require('firebase-functions');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();
setGlobalOptions({ region: 'asia-south1', maxInstances: 10 });

const db = () => getFirestore();

const DEAD_TOKEN = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);

/** Sends to every token of [uids]; prunes tokens FCM reports as dead. */
async function pushTo(uids, message) {
  const users = await Promise.all(uids.map((u) => db().doc(`users/${u}`).get()));
  const owners = [];
  const tokens = [];
  for (const u of users) {
    for (const t of u.get('fcmTokens') ?? []) {
      owners.push(u.ref);
      tokens.push(t);
    }
  }
  if (tokens.length === 0) return 0;
  let sent = 0;
  for (let i = 0; i < tokens.length; i += 500) {
    const batch = tokens.slice(i, i + 500);
    const res = await getMessaging().sendEachForMulticast({ ...message, tokens: batch });
    sent += res.successCount;
    await Promise.all(
      res.responses.map((r, j) =>
        !r.success && DEAD_TOKEN.has(r.error?.code)
          ? owners[i + j].update({ fcmTokens: FieldValue.arrayRemove(batch[j]) })
          : null,
      ),
    );
  }
  return sent;
}

const urgent = {
  android: { priority: 'high' },
  apns: { headers: { 'apns-priority': '10' }, payload: { aps: { sound: 'default' } } },
};

exports.onSos = onDocumentCreated('rides/{rideId}/alerts/{alertId}', async (event) => {
  const { rideId } = event.params;
  const alert = event.data?.data();
  if (!alert || alert.type !== 'sos') return;

  const sender = await db().doc(`rides/${rideId}/members/${alert.uid}`).get();
  if (sender.get('status') !== 'active') {
    logger.warn('SOS from non-member ignored', { rideId });
    return;
  }
  const [ride, members] = await Promise.all([
    db().doc(`rides/${rideId}`).get(),
    db().collection(`rides/${rideId}/members`).where('status', '==', 'active').get(),
  ]);
  const recipients = members.docs.map((d) => d.id).filter((u) => u !== alert.uid);
  const name = sender.get('name') ?? 'A rider';
  const sent = await pushTo(recipients, {
    notification: {
      title: `🆘 SOS from ${name}`,
      body: `${name} needs help on “${ride.get('name') ?? 'your ride'}”. Open RideTogether to see their last location.`,
    },
    data: { type: 'sos', rideId, uid: alert.uid },
    ...urgent,
  });
  // No coordinates in logs.
  logger.info('SOS pushed', { rideId, recipients: recipients.length, sent });
});

exports.onJoinRequest = onDocumentCreated('rides/{rideId}/members/{uid}', async (event) => {
  const { rideId } = event.params;
  const m = event.data?.data();
  if (!m || m.status !== 'pending') return;
  const ride = await db().doc(`rides/${rideId}`).get();
  const ownerId = ride.get('ownerId');
  if (!ownerId) return;
  await pushTo([ownerId], {
    notification: {
      title: 'Join request',
      body: `${m.name ?? 'Someone'} wants to join “${ride.get('name')}”.`,
    },
    data: { type: 'join_request', rideId },
  });
});

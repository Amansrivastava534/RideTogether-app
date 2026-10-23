// Emulator smoke test for function triggers (no real FCM delivery).
import { initializeApp } from 'firebase/app';
import { connectFirestoreEmulator, doc, getFirestore, setDoc } from 'firebase/firestore';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
const env = await initializeTestEnvironment({ projectId: 'demo-ridetogether', firestore: { host: '127.0.0.1', port: 8080 } });
await env.withSecurityRulesDisabled(async (c) => {
  const f = c.firestore();
  await setDoc(doc(f, 'rides/r1'), { name: 'Trip', ownerId: 'owner', status: 'active' });
  await setDoc(doc(f, 'rides/r1/members/owner'), { name: 'Owner', status: 'active', role: 'owner' });
  await setDoc(doc(f, 'rides/r1/members/bob'), { name: 'Bob', status: 'pending', role: 'member' });
  await setDoc(doc(f, 'rides/r1/alerts/a1'), { type: 'sos', uid: 'owner', name: 'Owner' });
  await setDoc(doc(f, 'rides/r1/alerts/a2'), { type: 'sos', uid: 'eve', name: 'Eve' });
});
await new Promise((r) => setTimeout(r, 6000));
await env.cleanup();

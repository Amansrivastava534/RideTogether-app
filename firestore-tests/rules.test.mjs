// Security-rules integration tests: create → join → approve → share → end.
// Run: npm test   (starts the Firestore emulator via firebase emulators:exec)
import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, test } from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
  updateDoc,
  writeBatch,
} from 'firebase/firestore';

let env;
const RIDE = 'ride1';
const CODE = 'K7QM4XPA';
const hours = (h) => Timestamp.fromMillis(Date.now() + h * 3600e3);

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ridetogether',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8'), host: '127.0.0.1', port: 8080 },
  });
});
after(() => env.cleanup());
beforeEach(() => env.clearFirestore());

const db = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();

function member(name, role, status, code) {
  return {
    name, photoUrl: null, bikeName: null, role, status,
    joinedAt: serverTimestamp(), expireAt: hours(720), ...(code ? { inviteCode: code } : {}),
  };
}

function loc(lat, secondsAgo = 0, extra = {}) {
  return {
    lat, lng: 73.0, accuracy: 8, speed: 10, heading: 0,
    clientTs: Timestamp.fromMillis(Date.now() - secondsAgo * 1000),
    serverTs: serverTimestamp(), sharing: true, expireAt: hours(24), ...extra,
  };
}

async function createRide(owner = 'owner', { requireApproval = true, code = CODE } = {}) {
  const f = db(owner);
  const b = writeBatch(f);
  b.set(doc(f, 'rides', RIDE), {
    name: 'Jodhpur Road Trip', ownerId: owner, code, requireApproval, status: 'waiting',
    createdAt: serverTimestamp(), fallBehindMeters: 3000, expireAt: hours(720),
  });
  b.set(doc(f, `rides/${RIDE}/members/${owner}`), member('Owner', 'owner', 'active'));
  b.set(doc(f, 'invites', code), {
    rideId: RIDE, rideName: 'Jodhpur Road Trip', requireApproval, createdBy: owner, expireAt: hours(24),
  });
  b.set(doc(f, `users/${owner}/recentRides/${RIDE}`), { name: 'x', joinedAt: serverTimestamp(), expireAt: hours(720) });
  return b.commit();
}

const join = (uid, status, code = CODE) =>
  setDoc(doc(db(uid), `rides/${RIDE}/members/${uid}`), member(uid, 'member', status, code));

async function activeMember(uid) {
  await join(uid, 'pending');
  await updateDoc(doc(db('owner'), `rides/${RIDE}/members/${uid}`), { status: 'active' });
}

describe('creating a ride', () => {
  test('owner can create ride + membership + invite atomically', async () => {
    await assertSucceeds(createRide());
  });
  test('cannot create a ride owned by someone else', async () => {
    await assertFails(setDoc(doc(db('mallory'), 'rides', 'r2'), {
      name: 'x', ownerId: 'owner', code: CODE, requireApproval: true, status: 'waiting',
      createdAt: serverTimestamp(), fallBehindMeters: 3000, expireAt: hours(1),
    }));
  });
  test('cannot self-promote to owner of an existing ride', async () => {
    await createRide();
    await assertFails(setDoc(doc(db('mallory'), `rides/${RIDE}/members/mallory`), member('M', 'owner', 'active')));
  });
  test('unauthenticated users get nothing', async () => {
    await createRide();
    await assertFails(getDoc(doc(anon(), 'rides', RIDE)));
    await assertFails(getDoc(doc(anon(), 'invites', CODE)));
  });
});

describe('joining', () => {
  beforeEach(() => createRide());

  test('invite code can be looked up but invites cannot be listed', async () => {
    await assertSucceeds(getDoc(doc(db('bob'), 'invites', CODE)));
    await assertFails(getDocs(collection(db('bob'), 'invites')));
  });
  test('private ride: joiner must start as pending', async () => {
    await assertFails(join('bob', 'active'));
    await assertSucceeds(join('bob', 'pending'));
  });
  test('public ride: joiner becomes active directly', async () => {
    await env.clearFirestore();
    await createRide('owner', { requireApproval: false });
    await assertFails(join('bob', 'pending'));
    await assertSucceeds(join('bob', 'active'));
  });
  test('wrong or expired code is rejected', async () => {
    await assertFails(join('bob', 'pending', 'ZZZZZZZZ'));
    await env.withSecurityRulesDisabled((c) =>
      updateDoc(doc(c.firestore(), 'invites', CODE), { expireAt: Timestamp.fromMillis(Date.now() - 1000) }));
    await assertFails(join('bob', 'pending'));
  });
  test('a code for another ride does not grant this ride', async () => {
    await env.withSecurityRulesDisabled((c) =>
      setDoc(doc(c.firestore(), 'invites', 'OTHER234'), { rideId: 'otherRide', expireAt: hours(1) }));
    await assertFails(join('bob', 'pending', 'OTHER234'));
  });
  test('pending member sees the ride name but no members or locations', async () => {
    await join('bob', 'pending');
    await assertSucceeds(getDoc(doc(db('bob'), 'rides', RIDE)));
    await assertSucceeds(getDoc(doc(db('bob'), `rides/${RIDE}/members/bob`)));
    await assertFails(getDocs(collection(db('bob'), `rides/${RIDE}/members`)));
    await assertFails(getDocs(collection(db('bob'), `rides/${RIDE}/locations`)));
    await assertFails(setDoc(doc(db('bob'), `rides/${RIDE}/locations/bob`), loc(26.1)));
  });
  test('only the owner approves; members cannot approve themselves', async () => {
    await join('bob', 'pending');
    await assertFails(updateDoc(doc(db('bob'), `rides/${RIDE}/members/bob`), { status: 'active' }));
    await assertSucceeds(updateDoc(doc(db('owner'), `rides/${RIDE}/members/bob`), { status: 'active' }));
  });
});

describe('live locations', () => {
  beforeEach(async () => {
    await createRide();
    await activeMember('bob');
  });

  test('strangers cannot read the ride or any location', async () => {
    await setDoc(doc(db('bob'), `rides/${RIDE}/locations/bob`), loc(26.1));
    await assertFails(getDoc(doc(db('eve'), 'rides', RIDE)));
    await assertFails(getDoc(doc(db('eve'), `rides/${RIDE}/locations/bob`)));
    await assertFails(getDocs(collection(db('eve'), `rides/${RIDE}/locations`)));
  });
  test('active members read all locations and write only their own', async () => {
    await assertSucceeds(setDoc(doc(db('bob'), `rides/${RIDE}/locations/bob`), loc(26.1)));
    await assertSucceeds(getDocs(collection(db('owner'), `rides/${RIDE}/locations`)));
    await assertFails(setDoc(doc(db('bob'), `rides/${RIDE}/locations/owner`), loc(26.2)));
  });
  test('out-of-order fix cannot replace a newer one', async () => {
    const ref = doc(db('bob'), `rides/${RIDE}/locations/bob`);
    await assertSucceeds(setDoc(ref, loc(26.1, 5)));
    await assertFails(setDoc(ref, loc(26.0, 30)));
    await assertSucceeds(setDoc(ref, loc(26.2, 0)));
  });
  test('client cannot fake server time, future time, or bad coordinates', async () => {
    const ref = doc(db('bob'), `rides/${RIDE}/locations/bob`);
    await assertFails(setDoc(ref, loc(26.1, 0, { serverTs: Timestamp.fromMillis(Date.now() + 3600e3) })));
    await assertFails(setDoc(ref, loc(26.1, -3600)));
    await assertFails(setDoc(ref, loc(123)));
    await assertFails(setDoc(ref, loc(26.1, 0, { extra: 'x' })));
  });
  test('removed member loses access, cannot rejoin or erase the removal', async () => {
    await updateDoc(doc(db('owner'), `rides/${RIDE}/members/bob`), { status: 'removed' });
    await assertFails(getDocs(collection(db('bob'), `rides/${RIDE}/locations`)));
    await assertFails(setDoc(doc(db('bob'), `rides/${RIDE}/locations/bob`), loc(26.1)));
    await assertFails(deleteDoc(doc(db('bob'), `rides/${RIDE}/members/bob`)));
    await assertFails(join('bob', 'pending'));
  });
  test('leaving revokes access', async () => {
    const f = db('bob');
    const b = writeBatch(f);
    b.delete(doc(f, `rides/${RIDE}/locations/bob`));
    b.delete(doc(f, `rides/${RIDE}/members/bob`));
    await assertSucceeds(b.commit());
    await assertFails(getDocs(collection(db('bob'), `rides/${RIDE}/locations`)));
  });
  test('owner can delete a removed rider’s location', async () => {
    await setDoc(doc(db('bob'), `rides/${RIDE}/locations/bob`), loc(26.1));
    await assertSucceeds(deleteDoc(doc(db('owner'), `rides/${RIDE}/locations/bob`)));
  });
});

describe('invite rotation', () => {
  beforeEach(() => createRide());
  test('owner rotates the code; old code stops working; others cannot mint codes', async () => {
    const f = db('owner');
    const b = writeBatch(f);
    b.delete(doc(f, 'invites', CODE));
    b.set(doc(f, 'invites', 'NEWC0DE2'.replace('0', 'Q')), {
      rideId: RIDE, rideName: 'x', requireApproval: true, createdBy: 'owner', expireAt: hours(24),
    });
    b.update(doc(f, 'rides', RIDE), { code: 'NEWCQDE2' });
    await assertSucceeds(b.commit());
    await assertFails(join('bob', 'pending', CODE));
    await assertSucceeds(join('bob', 'pending', 'NEWCQDE2'));
    await assertFails(setDoc(doc(db('bob'), 'invites', 'BOBC0DE2'), {
      rideId: RIDE, rideName: 'x', requireApproval: false, createdBy: 'bob', expireAt: hours(24),
    }));
  });
});

describe('ending a ride', () => {
  beforeEach(async () => {
    await createRide();
    await activeMember('bob');
  });

  test('only the owner can start/end, and status only moves forward', async () => {
    await assertFails(updateDoc(doc(db('bob'), 'rides', RIDE), { status: 'ended' }));
    await assertSucceeds(updateDoc(doc(db('owner'), 'rides', RIDE), { status: 'active', startedAt: serverTimestamp() }));
    await assertFails(updateDoc(doc(db('owner'), 'rides', RIDE), { status: 'waiting' }));
    await assertSucceeds(updateDoc(doc(db('owner'), 'rides', RIDE), { status: 'ended', endedAt: serverTimestamp() }));
  });
  test('after end: no location writes, no new joins, ride frozen', async () => {
    await updateDoc(doc(db('owner'), 'rides', RIDE), { status: 'ended', endedAt: serverTimestamp() });
    await assertFails(setDoc(doc(db('bob'), `rides/${RIDE}/locations/bob`), loc(26.1)));
    await assertFails(join('carol', 'pending'));
    await assertFails(updateDoc(doc(db('owner'), 'rides', RIDE), { requireApproval: false }));
    // Members can still read the ride for their summary.
    await assertSucceeds(getDoc(doc(db('bob'), 'rides', RIDE)));
  });
});

describe('SOS and private data', () => {
  beforeEach(async () => {
    await createRide();
    await activeMember('bob');
  });
  const sos = (uid) => ({
    type: 'sos', uid, name: 'Bob', lat: 26.1, lng: 73, createdAt: serverTimestamp(), expireAt: hours(168),
  });

  test('members can raise SOS as themselves only', async () => {
    await assertSucceeds(setDoc(doc(db('bob'), `rides/${RIDE}/alerts/a1`), sos('bob')));
    await assertFails(setDoc(doc(db('bob'), `rides/${RIDE}/alerts/a2`), sos('owner')));
    await assertFails(setDoc(doc(db('eve'), `rides/${RIDE}/alerts/a3`), sos('eve')));
    await assertFails(getDocs(collection(db('eve'), `rides/${RIDE}/alerts`)));
  });
  test('user profiles, tokens and history are private', async () => {
    await assertSucceeds(setDoc(doc(db('bob'), 'users/bob'), { name: 'Bob', fcmTokens: ['t'] }));
    await assertFails(getDoc(doc(db('owner'), 'users/bob')));
    await assertSucceeds(setDoc(doc(db('bob'), 'users/bob/history/r'), { name: 'x' }));
    await assertFails(getDoc(doc(db('owner'), 'users/bob/history/r')));
  });
});

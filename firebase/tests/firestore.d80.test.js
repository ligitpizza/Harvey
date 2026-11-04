import { afterAll, beforeAll, beforeEach, describe, test } from 'vitest';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, serverTimestamp, setDoc } from 'firebase/firestore';
import { as, makeEnv } from './helpers.js';

// D-80: family location map, staff leave and password reset codes.
let env;
const P = 'u-patient';
const F = 'u-family';

beforeAll(async () => {
  env = await makeEnv();
});
afterAll(async () => {
  await env.cleanup();
});
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `users/${P}`), { role: 'patient', name: 'Siti' });
    await setDoc(doc(db, `users/${F}`), { role: 'family_member', name: 'Aisyah', patientId: P });
    await setDoc(doc(db, 'users/u-stranger'), { role: 'family_member', name: 'X', patientId: null });
    await setDoc(doc(db, `patient_locations/${P}`), { lat: 3.15, lng: 101.7, sharing: true });
    await setDoc(doc(db, 'leave_requests/l1'), { staffId: 'u-doctor', status: 'pending' });
    await setDoc(doc(db, 'password_otps/k1'), { uid: P, codeHash: 'x' });
  });
});

const here = (extra = {}) => ({
  lat: 3.1,
  lng: 101.6,
  accuracy: 12,
  sharing: true,
  updatedAt: serverTimestamp(),
  ...extra,
});

describe('patient_locations', () => {
  test('the patient writes their own location', async () => {
    const db = as(env, 'patient', P).firestore();
    await assertSucceeds(setDoc(doc(db, `patient_locations/${P}`), here()));
  });
  test('the patient cannot write someone else\'s location', async () => {
    const db = as(env, 'patient', P).firestore();
    await assertFails(setDoc(doc(db, 'patient_locations/u-other'), here()));
  });
  test('bad coordinates, extra fields or a client clock are refused', async () => {
    const db = as(env, 'patient', P).firestore();
    await assertFails(setDoc(doc(db, `patient_locations/${P}`), here({ lat: 200 })));
    await assertFails(setDoc(doc(db, `patient_locations/${P}`), here({ note: 'x' })));
    await assertFails(setDoc(doc(db, `patient_locations/${P}`), here({ updatedAt: new Date() })));
  });
  test('sharing off must not keep coordinates', async () => {
    const db = as(env, 'patient', P).firestore();
    await assertFails(setDoc(doc(db, `patient_locations/${P}`), here({ sharing: false })));
    await assertSucceeds(
      setDoc(doc(db, `patient_locations/${P}`), { sharing: false, updatedAt: serverTimestamp() }),
    );
  });
  test('the linked family member reads it; others cannot', async () => {
    await assertSucceeds(getDoc(doc(as(env, 'family_member', F).firestore(), `patient_locations/${P}`)));
    await assertFails(
      getDoc(doc(as(env, 'family_member', 'u-stranger').firestore(), `patient_locations/${P}`)),
    );
    await assertFails(getDoc(doc(as(env, 'doctor').firestore(), `patient_locations/${P}`)));
  });
  test('family members cannot write the location', async () => {
    const db = as(env, 'family_member', F).firestore();
    await assertFails(setDoc(doc(db, `patient_locations/${P}`), here()));
  });
});

describe('server-only collections', () => {
  test('leave requests are not readable or writable from clients', async () => {
    await assertFails(getDoc(doc(as(env, 'doctor', 'u-doctor').firestore(), 'leave_requests/l1')));
    await assertFails(getDoc(doc(as(env, 'admin').firestore(), 'leave_requests/l1')));
    await assertFails(
      setDoc(doc(as(env, 'admin').firestore(), 'leave_requests/l2'), { status: 'approved' }),
    );
  });
  test('password reset codes are never readable', async () => {
    await assertFails(getDoc(doc(as(env, 'patient', P).firestore(), 'password_otps/k1')));
    await assertFails(getDoc(doc(as(env, 'admin').firestore(), 'password_otps/k1')));
  });
});


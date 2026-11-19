import { afterAll, beforeAll, beforeEach, describe, test } from 'vitest';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { collection, doc, getDoc, getDocs, query, updateDoc, where, setDoc } from 'firebase/firestore';
import { as, makeEnv } from './helpers.js';

// D-120: a doctor covering one visit reads the patient's data only inside the window
// (users/{patient}.coverAccess, written by FastAPI).
let env;
const P = 'u-patient';
const OWN = 'u-own';
const COVER = 'u-cover';
const LATE = 'u-late'; // window over
const EARLY = 'u-early'; // window not started
const OTHER = 'u-other-doc';
const DAY = 24 * 3600 * 1000;

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
    const now = Date.now();
    await setDoc(doc(db, `users/${P}`), {
      role: 'patient',
      name: 'Siti',
      assignedDoctorId: OWN,
      coverAccess: {
        [COVER]: { from: new Date(now - DAY), until: new Date(now + 7 * DAY) },
        [LATE]: { from: new Date(now - 10 * DAY), until: new Date(now - DAY) },
        [EARLY]: { from: new Date(now + DAY), until: new Date(now + 9 * DAY) },
      },
    });
    for (const d of [OWN, COVER, LATE, EARLY, OTHER]) {
      await setDoc(doc(db, `users/${d}`), { role: 'doctor', name: d });
    }
    await setDoc(doc(db, 'vital_readings/r1'), { patientId: P, systolic: 150, diastolic: 95 });
    await setDoc(doc(db, 'clinical_notes/n1'), { patientId: P, doctorId: OWN, content: 'x' });
    await setDoc(doc(db, `health_profiles/${P}`), { patientId: P });
    await setDoc(doc(db, 'health_records/h1'), { patientId: P, sharedWithDoctor: true });
    await setDoc(doc(db, 'health_records/h2'), { patientId: P, sharedWithDoctor: false });
  });
});

const doctor = (uid) => as(env, 'doctor', uid).firestore();
const patient = () => as(env, 'patient', P).firestore();

describe('D-120 covering doctor', () => {
  test('reads the patient, readings, notes and profile inside the window', async () => {
    const db = doctor(COVER);
    await assertSucceeds(getDoc(doc(db, `users/${P}`)));
    await assertSucceeds(getDoc(doc(db, 'vital_readings/r1')));
    await assertSucceeds(getDocs(query(collection(db, 'clinical_notes'), where('patientId', '==', P))));
    await assertSucceeds(getDoc(doc(db, `health_profiles/${P}`)));
  });

  test('reads only shared records', async () => {
    await assertSucceeds(getDoc(doc(doctor(COVER), 'health_records/h1')));
    await assertFails(getDoc(doc(doctor(COVER), 'health_records/h2')));
  });

  test('is refused before and after the window, and without a cover visit', async () => {
    for (const uid of [LATE, EARLY, OTHER]) {
      await assertFails(getDoc(doc(doctor(uid), `users/${P}`)));
      await assertFails(getDoc(doc(doctor(uid), 'vital_readings/r1')));
    }
  });

  test('cannot write notes directly (FastAPI only)', async () => {
    await assertFails(setDoc(doc(doctor(COVER), 'clinical_notes/n2'), {
      patientId: P, doctorId: COVER, content: 'y',
    }));
  });

  test('nobody but FastAPI changes coverAccess', async () => {
    await assertFails(updateDoc(doc(patient(), `users/${P}`), { coverAccess: {} }));
    await assertFails(updateDoc(doc(as(env, 'admin').firestore(), `users/${P}`), {
      coverAccess: {},
    }));
  });
});

describe('D-120 patient sees who covered', () => {
  test('reads the covering doctors named in coverAccess, not other doctors', async () => {
    await assertSucceeds(getDoc(doc(patient(), `users/${COVER}`)));
    await assertSucceeds(getDoc(doc(patient(), `users/${LATE}`))); // history keeps the name
    await assertSucceeds(getDoc(doc(patient(), `users/${OWN}`)));
    await assertFails(getDoc(doc(patient(), `users/${OTHER}`)));
  });
});

import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/config/app_config.dart';
import '../../../firebase_options_patient.dart';
import 'patient_location.dart';

/// D-80: the family map's location while Harvey is closed. Android's WorkManager wakes
/// this about every 15 minutes (Android decides the exact time; idle phones and some
/// brands' battery savers delay it). It needs the "Allow all the time" location
/// permission and only runs for a signed-in patient with sharing on.
const backgroundLocationTask = 'harvey-family-location';
const backgroundLocationEvery = Duration(minutes: 15);

/// Entry point of the background isolate (WorkManager calls it; it must be top level).
@pragma('vm:entry-point')
void backgroundLocationDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      await reportLocationInBackground();
    } catch (e) {
      debugPrint('Harvey: background location failed: $e');
    }
    return true; // never ask Android to retry sooner: the next period comes anyway
  });
}

/// One background update. Returns what happened (for logs and tests).
Future<String> reportLocationInBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    if (AppConfig.useEmulators) {
      final host = AppConfig.emulatorHost;
      await FirebaseAuth.instance.useAuthEmulator(
        host,
        AppConfig.authEmulatorPort,
        automaticHostMapping: false,
      );
      FirebaseFirestore.instance.useFirestoreEmulator(
        host,
        AppConfig.firestoreEmulatorPort,
        automaticHostMapping: false,
      );
    }
  }
  // The signed-in user is restored from the phone; signed out = stop for good.
  final user = await FirebaseAuth.instance.authStateChanges().first.timeout(
    const Duration(seconds: 10),
    onTimeout: () => null,
  );
  if (user == null) {
    await Workmanager().cancelByUniqueName(backgroundLocationTask);
    return 'signed out';
  }
  if (await Geolocator.checkPermission() != LocationPermission.always) return 'no permission';
  if (!await Geolocator.isLocationServiceEnabled()) return 'location off';
  final repo = FirestorePatientLocationRepository(FirebaseFirestore.instance);
  final saved = await repo.watch(user.uid).first;
  if (saved != null && !saved.sharing) return 'sharing off';
  Position? pos;
  try {
    pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
    ).timeout(const Duration(seconds: 20));
  } catch (_) {
    pos = await Geolocator.getLastKnownPosition();
  }
  if (pos == null) return 'no fix';
  await repo.save(user.uid, lat: pos.latitude, lng: pos.longitude, accuracy: pos.accuracy);
  return 'saved';
}

/// Starts and stops the background job; asks for "Allow all the time".
abstract interface class BackgroundLocation {
  /// Whether Android allows location while Harvey is closed.
  Future<bool> allowedAllTheTime();

  /// Asks for "Allow all the time" (Android shows it on its settings page). True when
  /// granted.
  Future<bool> askAllTheTime();

  Future<void> openSettings();

  /// Schedule (or keep) the 15-minute job. Does nothing without the permission.
  Future<void> start();

  Future<void> stop();
}

class WorkmanagerBackgroundLocation implements BackgroundLocation {
  WorkmanagerBackgroundLocation();

  static bool _initialised = false;

  Future<void> _init() async {
    if (_initialised) return;
    await Workmanager().initialize(backgroundLocationDispatcher);
    _initialised = true;
  }

  @override
  Future<bool> allowedAllTheTime() async =>
      await Geolocator.checkPermission() == LocationPermission.always;

  @override
  Future<bool> askAllTheTime() async {
    // Android first needs "while using the app", then "all the time".
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.always) return true;
    if (p != LocationPermission.whileInUse) return false;
    final status = await Permission.locationAlways.request();
    return status.isGranted;
  }

  @override
  Future<void> openSettings() => Geolocator.openAppSettings();

  @override
  Future<void> start() async {
    if (!await allowedAllTheTime()) return;
    await _init();
    await Workmanager().registerPeriodicTask(
      backgroundLocationTask,
      backgroundLocationTask,
      frequency: backgroundLocationEvery,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  @override
  Future<void> stop() async {
    await _init();
    await Workmanager().cancelByUniqueName(backgroundLocationTask);
  }
}

/// Web, tests and the family / staff apps: no background job.
class NoBackgroundLocation implements BackgroundLocation {
  const NoBackgroundLocation();

  @override
  Future<bool> allowedAllTheTime() async => false;

  @override
  Future<bool> askAllTheTime() async => false;

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

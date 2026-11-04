import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/enums.dart';

/// D-80: the patient's last known location for the family map
/// (`patient_locations/{patientId}`). Written only by the patient's phone; read by the
/// patient and their linked family members (Security Rules). With sharing off the
/// coordinates are removed.
class PatientLocation {
  const PatientLocation({required this.sharing, this.lat, this.lng, this.accuracy, this.updatedAt});

  final bool sharing;
  final double? lat;
  final double? lng;
  final double? accuracy;
  final DateTime? updatedAt;

  bool get hasPoint => sharing && lat != null && lng != null;

  factory PatientLocation.fromMap(Map<String, dynamic> d) => PatientLocation(
    sharing: d['sharing'] != false,
    lat: (d['lat'] as num?)?.toDouble(),
    lng: (d['lng'] as num?)?.toDouble(),
    accuracy: (d['accuracy'] as num?)?.toDouble(),
    updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
  );
}

abstract interface class PatientLocationRepository {
  /// Live: null when the patient never shared a location.
  Stream<PatientLocation?> watch(String patientId);

  /// The patient's phone saves where it is now (sharing on).
  Future<void> save(String patientId, {required double lat, required double lng, double? accuracy});

  /// Turn sharing off (coordinates removed) or back on (next update fills them).
  Future<void> setSharing(String patientId, bool on);
}

class FirestorePatientLocationRepository implements PatientLocationRepository {
  FirestorePatientLocationRepository(this._db);
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String id) =>
      _db.collection(Collections.patientLocations).doc(id);

  @override
  Stream<PatientLocation?> watch(String patientId) =>
      _doc(patientId).snapshots().map((s) => s.exists ? PatientLocation.fromMap(s.data()!) : null);

  @override
  Future<void> save(
    String patientId, {
    required double lat,
    required double lng,
    double? accuracy,
  }) => _doc(patientId).set({
    'lat': lat,
    'lng': lng,
    'accuracy': ?accuracy,
    'sharing': true,
    'updatedAt': FieldValue.serverTimestamp(),
  });

  @override
  Future<void> setSharing(String patientId, bool on) => on
      // On is the default: drop the "off" marker; the next update saves the location.
      ? _doc(patientId).delete()
      : _doc(patientId).set({'sharing': false, 'updatedAt': FieldValue.serverTimestamp()});
}

/// "5 min ago", "2 h ago", "3 days ago".
String agoText(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
}

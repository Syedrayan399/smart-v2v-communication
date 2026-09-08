import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  static final FirebaseFirestore _firestore =
      FirebaseFirestore.instance;

  /// Save or update a vehicle in Firestore.
  static Future<void> updateVehicle({
    required String vehicleId,
    required String vehicleName,
    required String vehicleType,
    required double latitude,
    required double longitude,
    required bool isActive,
  }) async {
    try {
      await _firestore.collection('vehicles').doc(vehicleId).set(
        {
          'vehicleId': vehicleId,
          'vehicleName': vehicleName,
          'vehicleType': vehicleType,
          'latitude': latitude,
          'longitude': longitude,
          'isActive': isActive,
          'lastUpdated': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      print('Firestore vehicle update error: $e');
    }
  }

  /// Mark vehicle as offline.
  static Future<void> setVehicleOffline(
    String vehicleId,
  ) async {
    try {
      await _firestore.collection('vehicles').doc(vehicleId).update(
        {
          'isActive': false,
          'lastUpdated': FieldValue.serverTimestamp(),
        },
      );
    } catch (e) {
      print('Firestore offline update error: $e');
    }
  }

  /// Stream all active vehicles.
  static Stream<QuerySnapshot<Map<String, dynamic>>>
      getActiveVehicles() {
    return _firestore
        .collection('vehicles')
        .where('isActive', isEqualTo: true)
        .snapshots();
  }

  /// Get one vehicle.
  static Stream<DocumentSnapshot<Map<String, dynamic>>>
      getVehicle(String vehicleId) {
    return _firestore
        .collection('vehicles')
        .doc(vehicleId)
        .snapshots();
  }

  /// Delete vehicle document.
  static Future<void> deleteVehicle(
    String vehicleId,
  ) async {
    try {
      await _firestore
          .collection('vehicles')
          .doc(vehicleId)
          .delete();
    } catch (e) {
      print('Firestore delete error: $e');
    }
  }
}
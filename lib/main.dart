import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:just_audio/just_audio.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

import 'v2v_service.dart';

const String kCollisionAudioAsset =
    'assets/audio/collision_warning_chicken_squawk.wav';

// =====================================================
// APP
// =====================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    const V2VApp(),
  );
}

class V2VApp extends StatelessWidget {
  const V2VApp({
    super.key,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SMART V2V Communication',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const V2VHomePage(),
    );
  }
}

// =====================================================
// HOME PAGE
// =====================================================

class V2VHomePage extends StatefulWidget {
  const V2VHomePage({
    super.key,
  });

  @override
  State<V2VHomePage> createState() =>
      _V2VHomePageState();
}

class _V2VHomePageState
    extends State<V2VHomePage> {
  // =====================================================
  // SERVICES
  // =====================================================

  final V2VService v2vService =
      V2VService();

  final AudioPlayer collisionAudioPlayer =
      AudioPlayer();

  final MapController mapController =
      MapController();

  StreamSubscription<Position>?
      gpsSubscription;

  // Fast V2V synchronization. GPS hardware decides when a truly new
  // satellite fix is available, but the app checks and publishes the
  // latest position every second.
  Timer? _gpsPollingTimer;
  Timer? _v2vSyncTimer;
  bool _gpsPollInProgress = false;

  // Vehicle updates are throttled to a single choke point so the GPS
  // stream, the fast-poll timer, and the sync timer can't each fire a
  // socket emit within the same window. Every backend vehicleUpdate
  // recomputes nearby-vehicle data for all connected vehicles, so keeping
  // this interval sane matters for both battery life and server load.
  DateTime? _lastVehicleUpdateSentAt;
  static const Duration _vehicleUpdateMinInterval =
      Duration(milliseconds: 700);

  // =====================================================
  // AUDIO
  // =====================================================

  bool collisionAudioReady = false;

  bool warningSoundPlaying = false;

  Future<void>? _audioInitFuture;


  // =====================================================
  // VEHICLE INFORMATION
  // =====================================================

  // A unique ID is generated for each running app instance so two
  // devices never overwrite each other in the V2V backend.
  final String vehicleId =
      'BIKE${100000 + Random.secure().nextInt(900000)}';

  // User-selected vehicle details. The ID remains unique for backend/V2V
  // communication, while the name is a friendly label shown in the app.
  String vehicleName = '';

  String vehicleType = 'Bike';

  static const List<String> _vehicleTypes = <String>[
    'Bike',
    'Car',
    'Bus',
    'Truck',
    'Ambulance',
  ];


  // =====================================================
  // SAVED VEHICLE INFORMATION
  // =====================================================

  static const String _vehicleNamePreferenceKey =
      'saved_vehicle_name';
  static const String _vehicleTypePreferenceKey =
      'saved_vehicle_type';
  static const String _vehicleSetupCompletePreferenceKey =
      'vehicle_setup_complete';

  Future<bool> _loadSavedVehicleDetails() async {
    final SharedPreferences preferences =
        await SharedPreferences.getInstance();

    final bool setupComplete =
        preferences.getBool(
          _vehicleSetupCompletePreferenceKey,
        ) ??
        false;

    if (!setupComplete) {
      return false;
    }

    final String savedName =
        preferences.getString(
          _vehicleNamePreferenceKey,
        ) ??
        '';

    final String savedType =
        preferences.getString(
          _vehicleTypePreferenceKey,
        ) ??
        'Bike';

    if (!mounted) {
      return false;
    }

    setState(() {
      vehicleName = savedName;
      vehicleType = _vehicleTypes.contains(savedType)
          ? savedType
          : 'Bike';
    });

    return true;
  }

  Future<void> _saveVehicleDetails() async {
    final SharedPreferences preferences =
        await SharedPreferences.getInstance();

    await preferences.setString(
      _vehicleNamePreferenceKey,
      vehicleName,
    );

    await preferences.setString(
      _vehicleTypePreferenceKey,
      vehicleType,
    );

    await preferences.setBool(
      _vehicleSetupCompletePreferenceKey,
      true,
    );
  }

  // =====================================================
  // LOCATION
  // =====================================================

  double latitude = 13.0358;

  double longitude = 77.5970;

  // =====================================================
  // VEHICLE DATA
  // =====================================================

  double speed = 0;

  double previousSpeed = 0;

  double direction = 0;

  bool braking = false;

  // ACTIVE, PARKED, STOPPED, OFFLINE or EMERGENCY.
  String vehicleStatus = 'ACTIVE';

  // =====================================================
  // GPS STATUS
  // =====================================================

  bool gpsConnected = false;

  bool locationAllowed = false;

  bool gpsStarted = false;

  // Horizontal accuracy reported by the GPS chip (metres).
  // Lower = better. Indoor values are often 30–150 m.
  double gpsAccuracyMeters = 999.0;

  // Time of the last accepted GPS fix shown in the GPS status card.
  DateTime? lastGpsUpdate;

  // Only trust a fix for critical alerts when accuracy is this good or better.
  static const double _maxAccuracyForCriticalAlert = 20.0;

  // Completely ignore fixes worse than this. Keeping this tighter reduces
  // large indoor GPS jumps from being broadcast to nearby vehicles.
  static const double _maxAccuracyToAccept = 20.0;

  // Smooth accepted GPS fixes before using them for map/V2V distance logic.
  // This reduces 80 m -> 20 m -> 5 m style jumps caused by noisy GPS fixes.
  static const int _locationSmoothingWindow = 5;
  final List<Position> _recentAccuratePositions = <Position>[];


  // =====================================================
  // V2V STATUS
  // =====================================================

  bool backendChecking = false;

  String backendStatusMessage =
      'Connecting to V2V backend...';

  // =====================================================
  // SAFETY STATUS
  // =====================================================

  String safetyStatus = 'SAFE';

  String collisionMessage =
      'No immediate collision risk';

  Map<String, dynamic>? warningVehicle;

  // =====================================================
  // ALERT INTELLIGENCE
  // =====================================================

  String? _lastAlertVehicleId;

  int _highConfirmationCount = 0;

  // HIGH warnings should not require excessive
  // confirmation because backend updates can be delayed.
  static const int _requiredHighConfirmations = 1;

  // One-shot critical alert control.
  //
  // A vehicle can trigger sound + vibration only once while it remains in the
  // same danger episode. It must move outside this reset distance before a
  // new critical episode can trigger again.
  static const double _criticalDistanceMeters = 5.0;
  static const double _criticalResetDistanceMeters = 8.0;

  final Set<String> _criticalAlertTriggeredVehicles = <String>{};

  // A critical episode is re-armed only after the same vehicle is observed
  // outside the reset zone for multiple consecutive updates.
  final Map<String, int> _criticalResetConfirmationCounts =
      <String, int>{};

  static const int _requiredCriticalResetConfirmations = 3;

  // Global lock so the critical sound can never play twice within a short
  // window, even if two code paths race (backend event + local GPS evaluation).
  DateTime? _lastCriticalSoundAt;
  static const Duration _criticalSoundCooldown =
      Duration(seconds: 8);

  // =====================================================
  // PRIMARY THREAT
  // =====================================================

  String? _primaryThreatVehicleId;

  DateTime? _primaryThreatLastSeen;

  static const Duration
      _primaryThreatHoldDuration =
      Duration(
    seconds: 5,
  );

  // =====================================================
  // VISUAL WARNING
  // =====================================================

  bool _warningDialogVisible = false;

  String? _lastVisualWarningKey;

  DateTime? _lastVisualWarningTime;

  static const Duration
      _visualWarningCooldown =
      Duration(
    seconds: 8,
  );

  // Each warning level for a vehicle is shown once per danger episode.
  // This prevents repeated SnackBars/dialogs while the backend keeps
  // publishing the same threat every second.
  final Set<String> _shownVisualWarningKeys = <String>{};

  // =====================================================
  // NEARBY VEHICLES
  // =====================================================

  List<dynamic> nearbyVehicles = [];

  // Complete active-vehicle snapshot received from the backend for the
  // Intelligence live map. Nearby Vehicles remains a separate, filtered list.
  List<dynamic> liveMapVehicles = [];

  // Only vehicles within this radius are kept and displayed.
  static const double _nearbyVehicleDisplayRadiusMeters = 100.0;

  // =====================================================
  // TRAFFIC DENSITY
  // =====================================================

  String trafficDensity = 'LIGHT';

  int trafficVehicleCount = 0;

  bool trafficCongestion = false;

  double trafficAverageSpeed = 0;

  // =====================================================
  // SIMULATION
  // =====================================================

  bool simulationRunning = false;

  bool simulationLoading = false;

  // =====================================================
  // SAFE NUMBER HELPERS
  // =====================================================

  double _toDouble(
    dynamic value, {
    double fallback = 0,
  }) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(
          value?.toString() ?? '',
        ) ??
        fallback;
  }

  int _toInt(
    dynamic value, {
    int fallback = 0,
  }) {
    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(
          value?.toString() ?? '',
        ) ??
        fallback;
  }

  // =====================================================
  // STATUS NORMALIZATION
  // =====================================================

  String _normalizeStatus(
    dynamic value,
  ) {
    final String raw =
        value
            ?.toString()
            .trim()
            .toUpperCase() ??
        '';

    switch (raw) {
      case 'SAFE':
      case 'NORMAL':
      case 'NONE':
      case 'NO_RISK':
      case 'NO RISK':
        return 'SAFE';

      case 'DETECTED':
      case 'LOW':
      case 'EARLY':
      case 'WARNING':
        return 'EARLY';

      case 'MEDIUM':
      case 'MODERATE':
      case 'CAUTION':
        return 'MEDIUM';

      case 'HIGH':
      case 'DANGER':
      case 'DANGEROUS':
        return 'HIGH';

      case 'CRITICAL':
      case 'EMERGENCY':
      case 'SEVERE':
        return 'CRITICAL';

      default:
        return raw.isEmpty
            ? 'SAFE'
            : raw;
    }
  }

  int _statusPriority(
    String status,
  ) {
    switch (
      _normalizeStatus(status)
    ) {
      case 'CRITICAL':
        return 5;

      case 'HIGH':
        return 4;

      case 'MEDIUM':
        return 3;

      case 'EARLY':
        return 2;

      case 'SAFE':
      default:
        return 1;
    }
  }

  bool _isDangerStatus(
    String status,
  ) {
    final String normalized =
        _normalizeStatus(
      status,
    );

    return normalized == 'MEDIUM' ||
        normalized == 'HIGH' ||
        normalized == 'CRITICAL';
  }


  // =====================================================
  // VEHICLE HELPERS
  // =====================================================

  String _getVehicleId(
    Map<String, dynamic>? vehicle,
  ) {
    if (vehicle == null) {
      return '';
    }

    final dynamic id =
        vehicle['id'] ??
            vehicle['vehicleId'] ??
            vehicle['vehicle_id'] ??
            vehicle['name'];

    return id
            ?.toString()
            .trim() ??
        '';
  }

  String _getVehicleType(
    Map<String, dynamic>? vehicle,
  ) {
    if (vehicle == null) {
      return 'Vehicle';
    }

    return vehicle['type']
            ?.toString() ??
        vehicle['vehicleType']
            ?.toString() ??
        vehicle['vehicle_type']
            ?.toString() ??
        'Vehicle';
  }

  double? _getVehicleLatitude(
    Map<String, dynamic>? vehicle,
  ) {
    if (vehicle == null) {
      return null;
    }

    final dynamic value =
        vehicle['latitude'] ??
            vehicle['lat'];

    if (value == null) {
      return null;
    }

    return _toDouble(
      value,
      fallback: double.nan,
    ).isNaN
        ? null
        : _toDouble(value);
  }

  double? _getVehicleLongitude(
    Map<String, dynamic>? vehicle,
  ) {
    if (vehicle == null) {
      return null;
    }

    final dynamic value =
        vehicle['longitude'] ??
            vehicle['lng'] ??
            vehicle['lon'];

    if (value == null) {
      return null;
    }

    return _toDouble(
      value,
      fallback: double.nan,
    ).isNaN
        ? null
        : _toDouble(value);
  }

  double _getVehicleSpeed(
    Map<String, dynamic>? vehicle,
  ) {
    if (vehicle == null) {
      return 0;
    }

    return _toDouble(
      vehicle['speed'] ??
          vehicle['speedKmh'] ??
          vehicle['speed_kmh'],
    );
  }

  // =====================================================
  // PRIMARY THREAT HELPERS
  // =====================================================

  bool _isPrimaryThreat(
    dynamic vehicle,
  ) {
    if (vehicle is! Map) {
      return false;
    }

    final Map<String, dynamic> data =
        Map<String, dynamic>.from(
      vehicle,
    );

    final String id =
        _getVehicleId(
      data,
    );

    return id.isNotEmpty &&
        id == _primaryThreatVehicleId;
  }

  void _rememberPrimaryThreat(
    String id,
  ) {
    if (id.isEmpty ||
        id == 'UNKNOWN') {
      return;
    }

    _primaryThreatVehicleId =
        id;

    _primaryThreatLastSeen =
        DateTime.now();
  }

  void _clearPrimaryThreat() {
    _primaryThreatVehicleId =
        null;

    _primaryThreatLastSeen =
        null;
  }

  void _clearPrimaryThreatIfExpired() {
    final DateTime? lastSeen =
        _primaryThreatLastSeen;

    if (lastSeen == null) {
      return;
    }

    final bool expired =
        DateTime.now()
                .difference(
              lastSeen,
            ) >=
            _primaryThreatHoldDuration;

    if (expired) {
      _clearPrimaryThreat();
    }
  }

  // =====================================================
  // WARNING VEHICLE EXTRACTION
  // =====================================================

  Map<String, dynamic>?
      _extractWarningVehicle(
    Map<String, dynamic> data,
  ) {
    final List<String> possibleKeys = [
      'vehicle',
      'warningVehicle',
      'threatVehicle',
      'primaryThreat',
      'primaryVehicle',
      'nearbyVehicle',
    ];

    for (final String key
        in possibleKeys) {
      final dynamic value =
          data[key];

      if (value is Map) {
        return Map<String, dynamic>.from(
          value,
        );
      }
    }

    final dynamic vehicleIdValue =
        data['vehicleId'] ??
            data['vehicle_id'] ??
            data['id'];

    if (vehicleIdValue != null) {
      final Map<String, dynamic> vehicle =
          Map<String, dynamic>.from(
        data,
      );

      vehicle['id'] ??=
          vehicleIdValue;

      return vehicle;
    }

    return null;
  }

  // =====================================================
  // ALERT CONFIRMATION
  // =====================================================

  void _resetAlertConfirmation() {
    _highConfirmationCount = 0;

    _lastAlertVehicleId = null;
  }

  bool _confirmHighThreat(
    String vehicleId,
  ) {
    if (vehicleId.isEmpty ||
        vehicleId == 'UNKNOWN') {
      return true;
    }

    if (_lastAlertVehicleId ==
        vehicleId) {
      _highConfirmationCount++;
    } else {
      _lastAlertVehicleId =
          vehicleId;

      _highConfirmationCount = 1;
    }

    return _highConfirmationCount >=
        _requiredHighConfirmations;
  }

  // HIGH and lower warning levels are visual-only. Sound and vibration are
  // reserved exclusively for a confirmed CRITICAL event at 5 metres or less.
  bool _shouldPlayHighAlert(
    String vehicleId,
  ) {
    return false;
  }

  bool _shouldPlayCriticalAlert(
    String vehicleId,
    double distanceMeters,
  ) {
    // Never play the emergency alert unless the actual measured distance is
    // within the 5 m critical zone.
    if (!distanceMeters.isFinite ||
        distanceMeters > _criticalDistanceMeters) {
      return false;
    }

    // Accuracy gate: if our own GPS fix is worse than ~20 m we cannot trust
    // a "5 m" reading. This is the main cause of false alarms indoors.
    if (gpsAccuracyMeters > _maxAccuracyForCriticalAlert) {
      return false;
    }

    // Unknown IDs are not allowed to bypass the one-shot protection.
    if (vehicleId.isEmpty || vehicleId == 'UNKNOWN') {
      return false;
    }

    // Already played for this vehicle in the current danger episode.
    if (_criticalAlertTriggeredVehicles.contains(vehicleId)) {
      return false;
    }

    // Global cooldown – blocks a second play even from a different code path.
    final DateTime now = DateTime.now();
    if (_lastCriticalSoundAt != null &&
        now.difference(_lastCriticalSoundAt!) < _criticalSoundCooldown) {
      return false;
    }

    // Mark as played BEFORE starting the sound so concurrent callers see it.
    _criticalAlertTriggeredVehicles.add(vehicleId);
    _criticalResetConfirmationCounts[vehicleId] = 0;
    _lastCriticalSoundAt = now;
    return true;
  }

  void _rearmCriticalAlertForVehicle(
    String vehicleId,
  ) {
    if (vehicleId.isEmpty || vehicleId == 'UNKNOWN') {
      return;
    }

    _criticalAlertTriggeredVehicles.remove(vehicleId);
    _criticalResetConfirmationCounts.remove(vehicleId);
    _shownVisualWarningKeys.remove('CRITICAL-$vehicleId');
  }

  void _rearmCriticalAlertsFromNearbyVehicles(
    List<dynamic> vehicles,
  ) {
    final Map<String, double> currentDistances =
        <String, double>{};

    for (final dynamic item in vehicles) {
      if (item is! Map) {
        continue;
      }

      final Map<String, dynamic> vehicle =
          Map<String, dynamic>.from(item);

      final String id = _getVehicleId(vehicle);
      if (id.isEmpty || id == 'UNKNOWN') {
        continue;
      }

      currentDistances[id] = _distanceFromVehicle(vehicle);
    }

    // Do not re-arm merely because a single GPS/V2V update temporarily loses a
    // vehicle. A triggered vehicle must be observed outside the 8 m reset zone
    // for several consecutive updates before a new danger episode can alert.
    for (final String id in
        _criticalAlertTriggeredVehicles.toList()) {
      final double? distance = currentDistances[id];

      if (distance == null || !distance.isFinite) {
        continue;
      }

      if (distance >= _criticalResetDistanceMeters) {
        final int confirmations =
            (_criticalResetConfirmationCounts[id] ?? 0) + 1;

        _criticalResetConfirmationCounts[id] =
            confirmations;

        if (confirmations >=
            _requiredCriticalResetConfirmations) {
          _rearmCriticalAlertForVehicle(id);
        }
      } else {
        _criticalResetConfirmationCounts[id] = 0;
      }
    }
  }

  // =====================================================
  // AUDIO INITIALIZATION
  // =====================================================

  Future<void>
      initializeCollisionAudio() {
    return _audioInitFuture ??=
        _initializeCollisionAudio();
  }

  Future<void>
      _initializeCollisionAudio() async {
    try {
      final ByteData bytes =
          await rootBundle.load(
        kCollisionAudioAsset,
      );

      if (bytes.lengthInBytes <
          100) {
        throw Exception(
          'Audio file is empty or corrupted.',
        );
      }

      await collisionAudioPlayer
          .setAsset(
        kCollisionAudioAsset,
      );

      await collisionAudioPlayer
          .setVolume(
        1.0,
      );

      collisionAudioReady = true;
    } catch (e) {
      collisionAudioReady = false;

      _audioInitFuture = null;

      debugPrint(
        'AUDIO INIT ERROR: $e',
      );
    }
  }

  // =====================================================
  // PLAY WARNING SOUND
  // =====================================================

  Future<void>
      playCollisionWarning() async {
    // Hard lock: sound may play only once until the current playback
    // (or a minimum cooldown) finishes. This prevents rapid re-triggers
    // from GPS updates + backend collisionWarning arriving together.
    if (warningSoundPlaying) {
      return;
    }

    warningSoundPlaying = true;

    try {
      await initializeCollisionAudio();

      if (!collisionAudioReady) {
        return;
      }

      await collisionAudioPlayer.stop();

      await collisionAudioPlayer
          .setVolume(
        1.0,
      );

      await collisionAudioPlayer
          .seek(
        Duration.zero,
      );

      await collisionAudioPlayer
          .play();

      // Keep the lock until the sound has had time to finish.
      // Most short warning clips are 1–3 seconds; we hold 4 s minimum.
      await Future<void>.delayed(
        const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint(
        'WARNING SOUND ERROR: $e',
      );
    } finally {
      warningSoundPlaying =
          false;
    }
  }

  // =====================================================
  // VIBRATION HELPERS
  // =====================================================

  Future<void>
      _vibratePattern(
    List<int> pattern,
  ) async {
    try {
      final bool? hasVibrator =
          await Vibration
              .hasVibrator();

      if (hasVibrator != true) {
        return;
      }

      await Vibration.vibrate(
        pattern: pattern,
      );
    } catch (e) {
      debugPrint(
        'VIBRATION ERROR: $e',
      );
    }
  }
    // =====================================================
  // WARNING VIBRATION
  // =====================================================

  Future<void> vibrateForWarning(
    String status,
  ) async {
    final String normalized =
        _normalizeStatus(
      status,
    );

    if (normalized == 'CRITICAL') {
      await _vibratePattern(
        [
          0,
          500,
          150,
          500,
          150,
          700,
        ],
      );
      return;
    }

    if (normalized == 'HIGH') {
      await _vibratePattern(
        [
          0,
          350,
          150,
          350,
        ],
      );
      return;
    }

    if (normalized == 'MEDIUM') {
      await _vibratePattern(
        [
          0,
          200,
          150,
          200,
        ],
      );
      return;
    }

    if (normalized == 'EARLY') {
      await _vibratePattern(
        [
          0,
          150,
        ],
      );
    }
  }

  // =====================================================
  // TEST WARNING SOUND
  // =====================================================

  Future<void> testWarningSound() async {
    try {
      await initializeCollisionAudio();

      if (!collisionAudioReady) {
        _showSnackBar(
          'Warning audio is not ready.',
          Colors.orange,
        );
        return;
      }

      await playCollisionWarning();

      await _vibratePattern(
        [
          0,
          180,
        ],
      );

      _showSnackBar(
        'Warning sound and vibration tested.',
        Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        'Could not play warning sound: $e',
        Colors.red,
      );
    }
  }

  // =====================================================
  // VEHICLE SETUP
  // =====================================================

  Future<void> _showVehicleSetupDialog() async {
    String selectedType = vehicleType;
    String enteredName = vehicleName;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (
            BuildContext context,
            StateSetter setDialogState,
          ) {
            return AlertDialog(
              title: const Text('Set Up Your Vehicle'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Enter a name and select the type of vehicle you are using.',
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      initialValue: vehicleName,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 30,
                      onChanged: (String value) {
                        enteredName = value;
                      },
                      decoration: const InputDecoration(
                        labelText: 'Vehicle Name',
                        hintText: 'Example: Rayan Bike',
                        prefixIcon: Icon(Icons.drive_file_rename_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: selectedType,
                      decoration: const InputDecoration(
                        labelText: 'Vehicle Type',
                        prefixIcon: Icon(Icons.directions_car_filled_rounded),
                        border: OutlineInputBorder(),
                      ),
                      items: _vehicleTypes
                          .map(
                            (String type) => DropdownMenuItem<String>(
                              value: type,
                              child: Text(type),
                            ),
                          )
                          .toList(),
                      onChanged: (String? value) {
                        if (value != null) {
                          setDialogState(() {
                            selectedType = value;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () async {
                    // If the user typed a name and left the default Bike type,
                    // the text field may still own focus. Release that focus
                    // before removing the dialog.
                    FocusManager.instance.primaryFocus?.unfocus();

                    await Future<void>.delayed(
                      const Duration(milliseconds: 150),
                    );

                    if (!dialogContext.mounted || !mounted) {
                      return;
                    }

                    setState(() {
                      final String trimmedName =
                          enteredName.trim();

                      vehicleName = trimmedName.isEmpty
                          ? 'My $selectedType'
                          : trimmedName;
                      vehicleType = selectedType;
                    });

                    await _saveVehicleDetails();

                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('Start V2V'),
                ),
              ],
            );
          },
        );
      },
    );
  }


  // =====================================================
  // VEHICLE SETTINGS
  // =====================================================

  Future<void> _showVehicleSettingsDialog() async {
    String selectedType = vehicleType;
    String enteredName = vehicleName;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              title: const Text('Vehicle Settings'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      initialValue: vehicleName,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 30,
                      onChanged: (String value) {
                        enteredName = value;
                      },
                      decoration: const InputDecoration(
                        labelText: 'Vehicle Name',
                        prefixIcon: Icon(Icons.drive_file_rename_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedType,
                      decoration: const InputDecoration(
                        labelText: 'Vehicle Type',
                        prefixIcon: Icon(Icons.directions_car_filled_rounded),
                        border: OutlineInputBorder(),
                      ),
                      items: _vehicleTypes
                          .map((String type) => DropdownMenuItem<String>(
                                value: type,
                                child: Text(type),
                              ))
                          .toList(),
                      onChanged: (String? value) {
                        if (value != null) {
                          setDialogState(() {
                            selectedType = value;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    FocusManager.instance.primaryFocus?.unfocus();
                    await Future<void>.delayed(
                      const Duration(milliseconds: 100),
                    );

                    if (!mounted || !dialogContext.mounted) {
                      return;
                    }

                    setState(() {
                      final String trimmedName = enteredName.trim();
                      vehicleName = trimmedName.isEmpty
                          ? 'My $selectedType'
                          : trimmedName;
                      vehicleType = selectedType;
                    });

                    await _saveVehicleDetails();

                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }

                    _showSnackBar(
                      'Vehicle details saved.',
                      Colors.green,
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // =====================================================
  // APP LIFECYCLE
  // =====================================================

  @override
  void initState() {
    super.initState();

    initializeCollisionAudio();

    _configureV2VCallbacks();

    WidgetsBinding.instance
        .addPostFrameCallback(
      (_) async {
        final bool hasSavedVehicle =
            await _loadSavedVehicleDetails();

        if (!hasSavedVehicle && mounted) {
          await _showVehicleSetupDialog();
        }

        if (mounted) {
          allowLocation();
        }
      },
    );
  }

  @override
  void dispose() {
    _gpsPollingTimer?.cancel();
    _v2vSyncTimer?.cancel();
    gpsSubscription?.cancel();

    v2vService.disconnect();

    collisionAudioPlayer.dispose();

    super.dispose();
  }

  // =====================================================
  // V2V CALLBACK CONFIGURATION
  // =====================================================

  void _configureV2VCallbacks() {
    v2vService.onConnected = () {
      if (!mounted) {
        return;
      }

      setState(() {
        backendStatusMessage =
            'V2V backend connected';
      });
    };

    v2vService.onDisconnected = () {
      if (!mounted) {
        return;
      }

      setState(() {
        backendStatusMessage =
            'V2V backend disconnected';
      });
    };

    v2vService.onConnectionError = (
      String error,
    ) {
      if (!mounted) {
        return;
      }

      setState(() {
        backendStatusMessage =
            'Connection error: $error';
      });
    };

    v2vService.onRegistrationSuccess = (
      String registeredVehicleId,
    ) {
      if (!mounted) {
        return;
      }

      setState(() {
        backendStatusMessage =
            'Vehicle $registeredVehicleId connected';
      });

      // Ask the backend for an immediate snapshot. This prevents the
      // Nearby Vehicles card and live map from staying empty until the
      // next GPS update.
      _sendVehicleUpdate();
      v2vService.requestLiveMapData();
    };

    v2vService.onNearbyVehicles =
        (
      List<dynamic> vehicles,
      Map<String, dynamic> density,
    ) {
      _handleNearbyVehicles(
        vehicles,
        density,
      );
    };

    v2vService.onCollisionWarning =
        (
      Map<String, dynamic> data,
    ) {
      _handleCollisionWarning(
        data,
      );
    };

    v2vService.onVehiclePosition =
        (
      Map<String, dynamic> data,
    ) {
      _handleVehiclePosition(
        data,
      );
    };

    v2vService.onLiveMapData =
    (
  Map<String, dynamic> data,
) {
  final List<dynamic> vehicles =
      data['vehicles'] is List
          ? List<dynamic>.from(
              data['vehicles'],
            )
          : <dynamic>[];

  _handleLiveMapData(
    vehicles,
  );
};

    v2vService.onVehicleRemoved =
        (
      String removedVehicleId,
    ) {
      _handleVehicleRemoved(
        removedVehicleId,
      );
    };
  }

  // =====================================================
  // BACKEND CONNECTION
  // =====================================================

  Future<void>
      checkBackendConnection() async {
    if (backendChecking) {
      return;
    }

    setState(() {
      backendChecking = true;
      backendStatusMessage =
          'Checking V2V backend...';
    });

    try {
      final bool available =
          await v2vService
              .checkBackend();

      if (!mounted) {
        return;
      }

      if (available) {
        setState(() {
          backendStatusMessage =
              'Backend available';
        });

        _connectToV2V();
      } else {
        setState(() {
          backendStatusMessage =
              'Backend is unavailable';
        });
      }
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        backendStatusMessage =
            'Backend check failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          backendChecking = false;
        });
      }
    }
  }

  // =====================================================
  // CONNECT TO V2V
  // =====================================================

  void _connectToV2V() {
    if (!locationAllowed) {
      return;
    }

    if (v2vService.isConnected) {
      return;
    }

    setState(() {
      backendStatusMessage =
          'Connecting to V2V backend...';
    });

    v2vService.connect(
      vehicleId: vehicleId,
      vehicleName:
          vehicleName.isEmpty
              ? vehicleId
              : vehicleName,
      vehicleType:
          vehicleType,
      vehicleStatus:
          vehicleStatus,
      latitude:
          latitude,
      longitude:
          longitude,
      gpsAccuracy:
          gpsAccuracyMeters.isFinite
              ? gpsAccuracyMeters
              : 0,
      gpsTimestamp:
          lastGpsUpdate
              ?.millisecondsSinceEpoch ??
          DateTime.now()
              .millisecondsSinceEpoch,
    );
  }

  // =====================================================
  // LOCATION PERMISSION
  // =====================================================

  Future<void> allowLocation() async {
    bool serviceEnabled =
        await Geolocator
            .isLocationServiceEnabled();

    if (!serviceEnabled) {
      if (!mounted) {
        return;
      }

      setState(() {
        gpsConnected = false;
        locationAllowed = false;
        backendStatusMessage =
            'Please enable location services';
      });

      _showSnackBar(
        'Location services are disabled.',
        Colors.red,
      );

      return;
    }

    LocationPermission permission =
        await Geolocator
            .checkPermission();

    if (permission ==
        LocationPermission.denied) {
      permission =
          await Geolocator
              .requestPermission();
    }

    if (permission ==
            LocationPermission.denied ||
        permission ==
            LocationPermission
                .deniedForever) {
      if (!mounted) {
        return;
      }

      setState(() {
        gpsConnected = false;
        locationAllowed = false;
        backendStatusMessage =
            'Location permission denied';
      });

      _showSnackBar(
        'Location permission is required for V2V.',
        Colors.red,
      );

      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      locationAllowed = true;
    });

    await _startGpsTracking();
  }

  // =====================================================
  // GPS TRACKING
  // =====================================================

  Future<void>
      _startGpsTracking() async {
    if (gpsStarted) {
      return;
    }

    gpsStarted = true;

    try {
      final LocationSettings
          locationSettings =
          AndroidSettings(
        accuracy:
            LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        // Force the more accurate GPS provider when possible.
        forceLocationManager: false,
        intervalDuration: const Duration(milliseconds: 500),
        foregroundNotificationConfig:
            const ForegroundNotificationConfig(
          notificationText:
              'V2V is tracking your vehicle location.',
          notificationTitle:
              'SMART V2V Communication',
          enableWakeLock: true,
        ),
      );

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 8),
        ),
      );

      _updateOwnPosition(
        position,
      );

      gpsSubscription =
          Geolocator
              .getPositionStream(
        locationSettings:
            locationSettings,
      ).listen(
        _updateOwnPosition,
        onError: (
          Object error,
        ) {
          if (!mounted) {
            return;
          }

          setState(() {
            gpsConnected = false;
            backendStatusMessage =
                'GPS error: $error';
          });
        },
      );


      // Check for a fresh high-accuracy position every second.
      _gpsPollingTimer?.cancel();
      _gpsPollingTimer = Timer.periodic(
        const Duration(milliseconds: 750),
        (_) => _pollFastGps(),
      );

      // Publish the latest position every second. The actual socket emit is
      // throttled inside _sendVehicleUpdate, so this timer just guarantees a
      // periodic attempt even if no new GPS fix has arrived.
      _v2vSyncTimer?.cancel();
      _v2vSyncTimer = Timer.periodic(
        const Duration(milliseconds: 750),
        (_) {
          if (!mounted) {
            return;
          }

          _sendVehicleUpdate();
        },
      );
    } catch (e) {
      gpsStarted = false;

      if (!mounted) {
        return;
      }

      setState(() {
        gpsConnected = false;
        backendStatusMessage =
            'Could not start GPS: $e';
      });
    }
  }

  // =====================================================
  // FAST GPS POLLING
  // =====================================================

  Future<void> _pollFastGps() async {
    if (_gpsPollInProgress || !locationAllowed) {
      return;
    }

    _gpsPollInProgress = true;

    try {
      final Position position =
          await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 2),
        ),
      );

      if (mounted) {
        _updateOwnPosition(position);
      }
    } catch (_) {
      // Keep the continuous GPS stream alive even if one fast poll fails.
    } finally {
      _gpsPollInProgress = false;
    }
  }

  // =====================================================
  // UPDATE OWN POSITION
  // =====================================================

  void _updateOwnPosition(
    Position position,
  ) {
    // ---- Accuracy gate -------------------------------------------------
    // Android/iOS report horizontal accuracy in metres.
    // Bad indoor fixes are often 40–200 m and cause false 5 m alerts.
    final double accuracy =
        position.accuracy.isFinite && position.accuracy > 0
            ? position.accuracy
            : 999.0;

    // Completely discard extremely poor fixes so they never move the marker
    // or trigger risk calculations.
    if (accuracy > _maxAccuracyToAccept) {
      if (mounted) {
        setState(() {
          gpsAccuracyMeters = accuracy;
          backendStatusMessage =
              'GPS accuracy too low (${accuracy.toStringAsFixed(0)} m). Move outdoors.';
        });
      }
      return;
    }

    // ---- GPS smoothing --------------------------------------------------
    // Keep a short window of only good fixes and use an accuracy-weighted
    // average. More accurate fixes influence the result more strongly.
    _recentAccuratePositions.add(position);
    if (_recentAccuratePositions.length > _locationSmoothingWindow) {
      _recentAccuratePositions.removeAt(0);
    }

    double totalWeight = 0;
    double smoothedLatitude = 0;
    double smoothedLongitude = 0;

    for (final Position sample in _recentAccuratePositions) {
      final double sampleAccuracy =
          sample.accuracy.isFinite && sample.accuracy > 0
              ? sample.accuracy
              : _maxAccuracyToAccept;
      final double weight = 1 / (sampleAccuracy * sampleAccuracy);
      totalWeight += weight;
      smoothedLatitude += sample.latitude * weight;
      smoothedLongitude += sample.longitude * weight;
    }

    if (totalWeight > 0) {
      smoothedLatitude /= totalWeight;
      smoothedLongitude /= totalWeight;
    } else {
      smoothedLatitude = position.latitude;
      smoothedLongitude = position.longitude;
    }

    final Position filteredPosition = Position(
      latitude: smoothedLatitude,
      longitude: smoothedLongitude,
      timestamp: position.timestamp,
      accuracy: accuracy,
      altitude: position.altitude,
      altitudeAccuracy: position.altitudeAccuracy,
      heading: position.heading,
      headingAccuracy: position.headingAccuracy,
      speed: position.speed,
      speedAccuracy: position.speedAccuracy,
      isMocked: position.isMocked,
    );


    final double newSpeedKmh =
        position.speed.isFinite &&
                position.speed > 0
            ? position.speed * 3.6
            : 0;

    final double newDirection =
        position.heading.isFinite &&
                position.heading >= 0
            ? position.heading
            : direction;

    final bool newBraking =
        previousSpeed -
                newSpeedKmh >
            12;

    previousSpeed =
        newSpeedKmh;

    if (!mounted) {
      return;
    }

    setState(() {
      latitude =
          filteredPosition.latitude;

      longitude =
          filteredPosition.longitude;

      speed =
          newSpeedKmh;

      direction =
          newDirection;

      braking =
          newBraking;

      gpsAccuracyMeters = accuracy;

      lastGpsUpdate = DateTime.now();

      gpsConnected = true;

      if (accuracy > _maxAccuracyForCriticalAlert) {
        backendStatusMessage =
            'GPS accuracy ${accuracy.toStringAsFixed(0)} m (critical alerts paused)';
      }
    });

    _connectToV2V();

    _sendVehicleUpdate();

    // Recalculate distances immediately from the new local GPS fix instead of
    // waiting for the backend's next nearby-vehicle snapshot.
    _evaluateNearbyThreats();

    _updateMapPosition();
  }

  // =====================================================
  // SEND VEHICLE UPDATE
  // =====================================================

  // Every trigger for a position update (GPS stream, fast-poll timer, sync
  // timer) funnels through here, and this is the single choke point that
  // throttles how often we actually emit over the socket. This keeps GPS
  // and network usage sane and avoids hammering the backend, which
  // recomputes nearby-vehicle data for every connected vehicle on each
  // vehicleUpdate it receives.
  void _sendVehicleUpdate() {
    if (!v2vService.isConnected) {
      return;
    }

    final DateTime now = DateTime.now();

    if (_lastVehicleUpdateSentAt != null &&
        now.difference(_lastVehicleUpdateSentAt!) <
            _vehicleUpdateMinInterval) {
      return;
    }

    _lastVehicleUpdateSentAt = now;

    v2vService.updateVehicle(
      vehicleId:
          vehicleId,
      name:
          vehicleName.isEmpty
              ? vehicleId
              : vehicleName,
      type:
          vehicleType,
      status:
          vehicleStatus,
      latitude:
          latitude,
      longitude:
          longitude,
      speed:
          speed,
      direction:
          direction,
      braking:
          braking,
      gpsAccuracy:
          gpsAccuracyMeters.isFinite
              ? gpsAccuracyMeters
              : 0,
      gpsTimestamp:
          lastGpsUpdate
              ?.millisecondsSinceEpoch ??
          now.millisecondsSinceEpoch,
    );
  }

  // =====================================================
  // MAP POSITION
  // =====================================================

  void _updateMapPosition() {
    try {
      mapController.move(
        LatLng(
          latitude,
          longitude,
        ),
        16,
      );
    } catch (_) {
      // The map may not yet be attached to the controller.
    }
  }

  // =====================================================
  // DISTANCE CALCULATION
  // =====================================================

  bool _hasValidCoordinates(
    double latitudeValue,
    double longitudeValue,
  ) {
    return latitudeValue.isFinite &&
        longitudeValue.isFinite &&
        latitudeValue >= -90 &&
        latitudeValue <= 90 &&
        longitudeValue >= -180 &&
        longitudeValue <= 180;
  }

  double _calculateDistanceMeters(
    double startLatitude,
    double startLongitude,
    double endLatitude,
    double endLongitude,
  ) {
    if (!startLatitude.isFinite ||
        !startLongitude.isFinite ||
        !endLatitude.isFinite ||
        !endLongitude.isFinite) {
      return 0;
    }

    return Geolocator
        .distanceBetween(
      startLatitude,
      startLongitude,
      endLatitude,
      endLongitude,
    );
  }

  // =====================================================
  // DISTANCE FROM VEHICLE
  // =====================================================

  double _distanceFromVehicle(
    Map<String, dynamic> vehicle,
  ) {
    final double? otherLatitude =
        _getVehicleLatitude(vehicle);

    final double? otherLongitude =
        _getVehicleLongitude(vehicle);

    // Always prefer a distance calculated on this device from the latest GPS
    // coordinates. Backend-provided distances can be stale, calculated from an
    // older position, or expressed with a different update timestamp.
    if (otherLatitude != null &&
        otherLongitude != null &&
        _hasValidCoordinates(latitude, longitude) &&
        _hasValidCoordinates(otherLatitude, otherLongitude)) {
      return _calculateDistanceMeters(
        latitude,
        longitude,
        otherLatitude,
        otherLongitude,
      );
    }

    // Fall back to the backend only when the other vehicle has not yet sent
    // usable coordinates.
    final double backendDistance =
        _toDouble(
      vehicle['distance'] ??
          vehicle['distanceMeters'] ??
          vehicle['distance_m'],
      fallback: double.infinity,
    );

    if (backendDistance.isFinite && backendDistance >= 0) {
      return backendDistance;
    }

    return double.infinity;
  }

  // Returns true only for vehicles within the 100 m display radius.
  bool _isWithinDisplayRadius(
    Map<String, dynamic> vehicle,
  ) {
    final double distance = _distanceFromVehicle(vehicle);

    return distance.isFinite &&
        distance <= _nearbyVehicleDisplayRadiusMeters;
  }

  // =====================================================
  // TRAFFIC DENSITY HANDLING
  // =====================================================

  void _updateTrafficDensity(
    Map<String, dynamic> density,
  ) {
    final String newDensity =
        density['level']
                ?.toString()
                .toUpperCase() ??
            density['density']
                ?.toString()
                .toUpperCase() ??
            trafficDensity;

    final int newVehicleCount =
        _toInt(
      density['vehicleCount'] ??
          density['count'] ??
          density['vehicles'],
      fallback:
          trafficVehicleCount,
    );

    final bool newCongestion =
        density['congestion'] ==
                true ||
            newDensity == 'HIGH' ||
            newDensity == 'HEAVY';

    final double newAverageSpeed =
        _toDouble(
      density['averageSpeed'] ??
          density['avgSpeed'],
      fallback:
          trafficAverageSpeed,
    );

    trafficDensity =
        newDensity;

    trafficVehicleCount =
        newVehicleCount;

    trafficCongestion =
        newCongestion;

    trafficAverageSpeed =
        newAverageSpeed;
  }
    // =====================================================
  // NEARBY VEHICLES HANDLER
  // =====================================================

  void _handleNearbyVehicles(
    List<dynamic> vehicles,
    Map<String, dynamic> density,
  ) {
    final List<dynamic> cleanedVehicles = [];

    for (final dynamic item in vehicles) {
      if (item is! Map) {
        continue;
      }

      final Map<String, dynamic> vehicle =
          Map<String, dynamic>.from(
        item,
      );

      final String id =
          _getVehicleId(
        vehicle,
      );

      // Never show our own vehicle as nearby.
      if (id.isNotEmpty &&
          id == vehicleId) {
        continue;
      }

      // Display and process only vehicles within 100 metres.
      if (!_isWithinDisplayRadius(vehicle)) {
        continue;
      }

      cleanedVehicles.add(
        vehicle,
      );
    }

    if (!mounted) {
      return;
    }

    _rearmCriticalAlertsFromNearbyVehicles(cleanedVehicles);

    setState(() {
      nearbyVehicles =
          cleanedVehicles;

      _updateTrafficDensity(
        density,
      );

      if (trafficVehicleCount <= 0) {
        trafficVehicleCount =
            cleanedVehicles.length;
      }
    });

    _evaluateNearbyThreats();
  }

  // =====================================================
  // LIVE MAP DATA HANDLER
  // =====================================================

  void _handleLiveMapData(
    List<dynamic> vehicles,
  ) {
    final List<dynamic> cleanedVehicles = [];

    for (final dynamic item in vehicles) {
      if (item is! Map) {
        continue;
      }

      final Map<String, dynamic> vehicle =
          Map<String, dynamic>.from(item);

      final String id = _getVehicleId(vehicle);

      // The current vehicle is drawn locally with its own GPS marker.
      if (id.isEmpty || id == vehicleId) {
        continue;
      }

      final double? lat = _getVehicleLatitude(vehicle);
      final double? lng = _getVehicleLongitude(vehicle);

      if (lat == null || lng == null) {
        continue;
      }

      cleanedVehicles.add(vehicle);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      liveMapVehicles = cleanedVehicles;
    });
  }

  // =====================================================
  // VEHICLE POSITION UPDATE
  // =====================================================

  void _handleVehiclePosition(
    Map<String, dynamic> data,
  ) {
    final String incomingId =
        _getVehicleId(
      data,
    );

    if (incomingId.isEmpty ||
        incomingId == vehicleId) {
      return;
    }

    // Remove vehicles that have moved outside the 100 m radius.
    if (!_isWithinDisplayRadius(data)) {
      final List<dynamic> filtered =
          nearbyVehicles.where((dynamic item) {
        if (item is! Map) {
          return false;
        }

        final Map<String, dynamic> vehicle =
            Map<String, dynamic>.from(item);

        return _getVehicleId(vehicle) != incomingId;
      }).toList();

      if (!mounted) {
        return;
      }

      _rearmCriticalAlertsFromNearbyVehicles(filtered);

      setState(() {
        nearbyVehicles = filtered;
      });

      _evaluateNearbyThreats();
      return;
    }

    final List<dynamic> updated =
        List<dynamic>.from(
      nearbyVehicles,
    );

    int existingIndex = -1;

    for (int i = 0;
        i < updated.length;
        i++) {
      final dynamic item =
          updated[i];

      if (item is Map) {
        final String existingId =
            _getVehicleId(
          Map<String, dynamic>.from(
            item,
          ),
        );

        if (existingId ==
            incomingId) {
          existingIndex = i;
          break;
        }
      }
    }

    if (existingIndex >= 0) {
      updated[existingIndex] =
          data;
    } else {
      updated.add(
        data,
      );
    }

    if (!mounted) {
      return;
    }

    _rearmCriticalAlertsFromNearbyVehicles(updated);

    final List<dynamic> updatedMap =
        List<dynamic>.from(
      liveMapVehicles,
    );

    final int mapIndex = updatedMap.indexWhere(
      (dynamic item) {
        if (item is! Map) {
          return false;
        }

        return _getVehicleId(
              Map<String, dynamic>.from(item),
            ) ==
            incomingId;
      },
    );

    if (mapIndex >= 0) {
      updatedMap[mapIndex] = data;
    } else {
      updatedMap.add(data);
    }

    setState(() {
      nearbyVehicles =
          updated;
      liveMapVehicles =
          updatedMap;
    });

    _evaluateNearbyThreats();
  }

  // =====================================================
  // VEHICLE REMOVED
  // =====================================================

  void _handleVehicleRemoved(
    String removedVehicleId,
  ) {
    if (removedVehicleId.isEmpty) {
      return;
    }

    _rearmCriticalAlertForVehicle(removedVehicleId);
    _shownVisualWarningKeys.removeWhere(
      (String key) => key.endsWith('-$removedVehicleId'),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      nearbyVehicles =
          nearbyVehicles.where(
        (
          dynamic item,
        ) {
          if (item is! Map) {
            return false;
          }

          final Map<String, dynamic>
              vehicle =
              Map<String, dynamic>.from(
            item,
          );

          return _getVehicleId(
                vehicle,
              ) !=
              removedVehicleId;
        },
      ).toList();

      liveMapVehicles =
          liveMapVehicles.where(
        (
          dynamic item,
        ) {
          if (item is! Map) {
            return false;
          }

          return _getVehicleId(
                Map<String, dynamic>.from(item),
              ) !=
              removedVehicleId;
        },
      ).toList();
    });

    if (_primaryThreatVehicleId ==
        removedVehicleId) {
      _clearPrimaryThreat();
      _setSafeIfNoThreat();
    }
  }

  // =====================================================
  // COLLISION WARNING HANDLER
  // =====================================================

  void _handleCollisionWarning(
    Map<String, dynamic> data,
  ) {
    final Map<String, dynamic>?
        extractedVehicle =
        _extractWarningVehicle(
      data,
    );

    String incomingStatus =
        _normalizeStatus(
      data['status'] ??
          data['riskLevel'] ??
          data['risk'] ??
          data['warningLevel'] ??
          data['level'],
    );

    // If the backend does not send a status but sends
    // collision information, treat it as HIGH.
    if (incomingStatus == 'SAFE' &&
        (data['collision'] == true ||
            data['collisionRisk'] ==
                true ||
            data['danger'] == true)) {
      incomingStatus = 'HIGH';
    }

    final String message =
        data['message']
                ?.toString()
                .trim()
                .isNotEmpty ==
            true
        ? data['message']
            .toString()
        : _buildWarningMessage(
            incomingStatus,
            extractedVehicle,
            data,
          );

    final String incomingVehicleId =
        _getVehicleId(
      extractedVehicle,
    );

    // Ignore collision events for our own vehicle.
    if (incomingVehicleId.isNotEmpty &&
        incomingVehicleId ==
            vehicleId) {
      return;
    }

    _clearPrimaryThreatIfExpired();

    // Remember any meaningful threat vehicle.
    if (incomingStatus != 'SAFE' &&
        incomingVehicleId.isNotEmpty) {
      _rememberPrimaryThreat(
        incomingVehicleId,
      );
    }

    // SAFE events should not immediately erase an active
    // threat from another recent vehicle.
    if (incomingStatus == 'SAFE' &&
        _primaryThreatVehicleId !=
            null &&
        incomingVehicleId.isNotEmpty &&
        incomingVehicleId !=
            _primaryThreatVehicleId) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      safetyStatus =
          incomingStatus;

      collisionMessage =
          message;

      warningVehicle =
          extractedVehicle;
    });

    if (incomingStatus == 'SAFE') {
      _resetAlertConfirmation();

      _setSafeIfNoThreat();
      return;
    }

    // EARLY warnings update the UI but should not produce
    // a loud emergency alarm.
    if (incomingStatus == 'EARLY') {

      _showVisualWarning(
        status:
            incomingStatus,
        message:
            message,
        vehicle:
            extractedVehicle,
      );

      return;
    }

    // MEDIUM updates the warning UI only. No sound or vibration is used.
    if (incomingStatus == 'MEDIUM') {

      awaitWarningAction(
        status:
            incomingStatus,
        message:
            message,
        vehicle:
            extractedVehicle,
        playSound:
            false,
      );

      return;
    }

    // HIGH warnings are visual-only. Sound and vibration are disabled.
    if (incomingStatus == 'HIGH') {
      final bool confirmed =
          _confirmHighThreat(
        incomingVehicleId,
      );

      if (!confirmed) {
        return;
      }

      final bool shouldPlay =
          _shouldPlayHighAlert(
        incomingVehicleId,
      );

      awaitWarningAction(
        status:
            incomingStatus,
        message:
            message,
        vehicle:
            extractedVehicle,
        playSound:
            shouldPlay,
      );

      return;
    }

    // CRITICAL sound + vibration are allowed only once, and only at 5 m or less.
    if (incomingStatus ==
        'CRITICAL') {
      final double criticalDistance =
          extractedVehicle == null
              ? _toDouble(
                  data['distance'],
                  fallback: double.infinity,
                )
              : _distanceFromVehicle(
                  extractedVehicle,
                );

      final bool shouldPlay =
          _shouldPlayCriticalAlert(
        incomingVehicleId,
        criticalDistance,
      );

      awaitWarningAction(
        status:
            incomingStatus,
        message:
            message,
        vehicle:
            extractedVehicle,
        playSound:
            shouldPlay,
      );
    }
  }

  // =====================================================
  // WARNING ACTION
  // =====================================================

  Future<void>
      awaitWarningAction({
    required String status,
    required String message,
    required Map<String, dynamic>?
        vehicle,
    required bool playSound,
  }) async {
    // Visual warnings can continue to update, but sound and vibration are
    // reserved for the single, gated CRITICAL event.
    _showVisualWarning(
      status: status,
      message: message,
      vehicle: vehicle,
    );

    if (_normalizeStatus(status) != 'CRITICAL' || !playSound) {
      return;
    }

    // The caller has already passed _shouldPlayCriticalAlert(), so this pair
    // can happen only once for the current danger episode.
    await playCollisionWarning();
    await vibrateForWarning('CRITICAL');
  }

  // =====================================================
  // BUILD WARNING MESSAGE
  // =====================================================

  String _buildWarningMessage(
    String status,
    Map<String, dynamic>? vehicle,
    Map<String, dynamic> data,
  ) {
    final String id =
        _getVehicleId(
      vehicle,
    );

    final double distance =
        _toDouble(
      data['distance'] ??
          vehicle?['distance'],
      fallback: -1,
    );

    final String vehicleName =
        id.isEmpty
            ? 'A nearby vehicle'
            : id;

    final String distanceText =
        distance >= 0
            ? ' (${distance.toStringAsFixed(1)} m away)'
            : '';

    switch (status) {
      case 'CRITICAL':
        return 'CRITICAL COLLISION WARNING: '
            '$vehicleName is dangerously close$distanceText.';

      case 'HIGH':
        return 'HIGH COLLISION RISK: '
            '$vehicleName is approaching$distanceText.';

      case 'MEDIUM':
        return 'CAUTION: '
            '$vehicleName may create a collision risk$distanceText.';

      case 'EARLY':
        return 'Vehicle detected nearby: '
            '$vehicleName$distanceText.';

      case 'SAFE':
      default:
        return 'No immediate collision risk.';
    }
  }

  // =====================================================
  // EVALUATE NEARBY VEHICLE THREATS
  // =====================================================

  void _evaluateNearbyThreats() {
    _clearPrimaryThreatIfExpired();

    if (nearbyVehicles.isEmpty) {
      _setSafeIfNoThreat();
      return;
    }

    Map<String, dynamic>? bestVehicle;

    String bestStatus =
        'SAFE';

    int bestPriority = 0;

    double bestDistance =
        double.infinity;

    for (final dynamic item
        in nearbyVehicles) {
      if (item is! Map) {
        continue;
      }

      final Map<String, dynamic>
          vehicle =
          Map<String, dynamic>.from(
        item,
      );

      final String id =
          _getVehicleId(
        vehicle,
      );

      if (id.isEmpty ||
          id == vehicleId) {
        continue;
      }

      final double distance =
          _distanceFromVehicle(
        vehicle,
      );

      final String vehicleStatus =
          _calculateLocalRiskStatus(
        vehicle,
        distance,
      );

      final int priority =
          _statusPriority(
        vehicleStatus,
      );

      final bool betterPriority =
          priority >
              bestPriority;

      final bool samePriorityCloser =
          priority ==
                  bestPriority &&
              distance <
                  bestDistance;

      if (betterPriority ||
          samePriorityCloser) {
        bestVehicle =
            vehicle;

        bestStatus =
            vehicleStatus;

        bestPriority =
            priority;

        bestDistance =
            distance;
      }
    }

    if (bestVehicle == null ||
        bestStatus == 'SAFE') {
      _setSafeIfNoThreat();
      return;
    }

    final String bestVehicleId =
        _getVehicleId(
      bestVehicle,
    );

    if (bestVehicleId.isNotEmpty) {
      _rememberPrimaryThreat(
        bestVehicleId,
      );
    }

    final String message =
        _buildLocalRiskMessage(
      bestStatus,
      bestVehicle,
      bestDistance,
    );

    // Do not overwrite a stronger backend CRITICAL/HIGH
    // warning with a weaker local estimate.
    final int currentPriority =
        _statusPriority(
      safetyStatus,
    );

    final int newPriority =
        _statusPriority(
      bestStatus,
    );

    if (currentPriority >
            newPriority &&
        _isPrimaryThreat(
          warningVehicle,
        )) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      safetyStatus =
          bestStatus;

      collisionMessage =
          message;

      warningVehicle =
          bestVehicle;
    });

    _processLocalThreatAlert(
      bestStatus,
      bestVehicle,
      message,
    );
  }

  // =====================================================
  // LOCAL THREAT ALERT PROCESSING
  // =====================================================

  void _processLocalThreatAlert(
    String status,
    Map<String, dynamic> vehicle,
    String message,
  ) {
    final String normalized =
        _normalizeStatus(
      status,
    );

    final String id =
        _getVehicleId(
      vehicle,
    );

    if (normalized == 'SAFE') {
      return;
    }

    if (normalized == 'EARLY') {

      _showVisualWarning(
        status:
            normalized,
        message:
            message,
        vehicle:
            vehicle,
      );

      return;
    }

    if (normalized == 'MEDIUM') {

      awaitWarningAction(
        status:
            normalized,
        message:
            message,
        vehicle:
            vehicle,
        playSound:
            false,
      );

      return;
    }

    if (normalized == 'HIGH') {
      final bool confirmed =
          _confirmHighThreat(
        id,
      );

      if (!confirmed) {
        return;
      }

      final bool shouldPlay =
          _shouldPlayHighAlert(
        id,
      );

      awaitWarningAction(
        status:
            normalized,
        message:
            message,
        vehicle:
            vehicle,
        playSound:
            shouldPlay,
      );

      return;
    }

    if (normalized ==
        'CRITICAL') {
      final bool shouldPlay =
          _shouldPlayCriticalAlert(
        id,
        _distanceFromVehicle(
          vehicle,
        ),
      );

      awaitWarningAction(
        status:
            normalized,
        message:
            message,
        vehicle:
            vehicle,
        playSound:
            shouldPlay,
      );
    }
  }
    // =====================================================
  // LOCAL RISK CALCULATION
  // =====================================================

  String _calculateLocalRiskStatus(
    Map<String, dynamic> vehicle,
    double distance,
  ) {
    if (!distance.isFinite ||
        distance == double.infinity) {
      return 'SAFE';
    }

    final double otherSpeed =
        _getVehicleSpeed(
      vehicle,
    );

    final bool otherBraking =
        vehicle['braking'] == true;

    // -----------------------------------------------------
    // Accuracy-aware thresholds
    // -----------------------------------------------------
    // When GPS accuracy is poor we raise the distances so
    // that noisy indoor fixes do not create false CRITICAL
    // or HIGH states.
    // -----------------------------------------------------
    final double accuracyPenalty =
        gpsAccuracyMeters > 25
            ? gpsAccuracyMeters * 0.6
            : 0.0;

    final double criticalLimit =
        _criticalDistanceMeters + accuracyPenalty;
    final double highLimit = 20.0 + accuracyPenalty;
    final double mediumLimit = 50.0 + accuracyPenalty;
    final double earlyLimit = 100.0 + accuracyPenalty;

    if (distance <= criticalLimit) {
      // Only allow CRITICAL when accuracy is good enough.
      if (gpsAccuracyMeters <= _maxAccuracyForCriticalAlert) {
        return 'CRITICAL';
      }
      return 'HIGH'; // degrade to HIGH when accuracy is bad
    }

    if (distance <= highLimit) {
      return 'HIGH';
    }

    if (distance <= mediumLimit) {
      return 'MEDIUM';
    }

    if (distance <= earlyLimit) {
      return 'EARLY';
    }

    // A faster approaching vehicle can receive an earlier
    // warning even when it is slightly farther away.
    if (speed >= 40 &&
        otherSpeed >= 40 &&
        distance <= 150 + accuracyPenalty) {
      return 'EARLY';
    }

    if (braking &&
        otherBraking &&
        distance <= 80 + accuracyPenalty) {
      return 'MEDIUM';
    }

    return 'SAFE';
  }

  // =====================================================
  // LOCAL RISK MESSAGE
  // =====================================================

  String _buildLocalRiskMessage(
    String status,
    Map<String, dynamic> vehicle,
    double distance,
  ) {
    final String id =
        _getVehicleId(
      vehicle,
    );

    final String name =
        id.isEmpty
            ? 'Nearby vehicle'
            : id;

    final String distanceText =
        distance.isFinite
            ? '${distance.toStringAsFixed(1)} m'
            : 'unknown distance';

    switch (
      _normalizeStatus(
        status,
      )
    ) {
      case 'CRITICAL':
        return 'CRITICAL COLLISION WARNING! '
            '$name is only $distanceText away. '
            'Take immediate action.';

      case 'HIGH':
        return 'HIGH COLLISION RISK! '
            '$name is $distanceText away. '
            'Slow down and be prepared to brake.';

      case 'MEDIUM':
        return 'CAUTION: $name is '
            '$distanceText away. '
            'Monitor the surrounding traffic.';

      case 'EARLY':
        return '$name detected at '
            '$distanceText. '
            'Vehicle is being monitored.';

      case 'SAFE':
      default:
        return 'No immediate collision risk.';
    }
  }

  // =====================================================
  // SAFE STATUS HANDLING
  // =====================================================

  void _setSafeIfNoThreat() {
    _clearPrimaryThreatIfExpired();

    // Do not immediately erase an active threat that is
    // still inside the hold period.
    if (_primaryThreatVehicleId != null) {
      return;
    }

    final bool alreadySafe =
        _normalizeStatus(
              safetyStatus,
            ) ==
            'SAFE';

    if (!mounted) {
      return;
    }

    if (!alreadySafe) {
      setState(() {
        safetyStatus = 'SAFE';

        collisionMessage =
            'No immediate collision risk';

        warningVehicle = null;
      });
    }

    // A new danger episode may show its visual warning again.
    _shownVisualWarningKeys.clear();
    _lastVisualWarningKey = null;
    _lastVisualWarningTime = null;

    _resetAlertConfirmation();
  }

  // =====================================================
  // GPS REFRESH
  // =====================================================

  Future<void> refreshGps() async {
    if (!mounted) {
      return;
    }

    setState(() {
      backendStatusMessage = 'Refreshing GPS...';
    });

    _gpsPollingTimer?.cancel();
    _gpsPollingTimer = null;
    _v2vSyncTimer?.cancel();
    _v2vSyncTimer = null;

    await gpsSubscription?.cancel();
    gpsSubscription = null;
    _gpsPollInProgress = false;
    gpsStarted = false;

    await allowLocation();

    if (!mounted) {
      return;
    }

    if (gpsConnected) {
      _sendVehicleUpdate();

      setState(() {
        backendStatusMessage = 'GPS refreshed';
      });
    }
  }

  // =====================================================
  // MANUAL REFRESH
  // =====================================================

  Future<void>
      refreshConnection() async {
    if (!locationAllowed) {
      await allowLocation();
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      backendStatusMessage =
          'Refreshing V2V connection...';
    });

    v2vService.disconnect();

    await Future.delayed(
      const Duration(
        milliseconds: 500,
      ),
    );

    await checkBackendConnection();
  }

  // =====================================================
  // VISUAL WARNING
  // =====================================================

  void _showVisualWarning({
    required String status,
    required String message,
    required Map<String, dynamic>?
        vehicle,
  }) {
    final String normalized =
        _normalizeStatus(
      status,
    );

    if (normalized == 'SAFE') {
      return;
    }

    final String id =
        _getVehicleId(
      vehicle,
    );

    final String warningKey =
        '$normalized-$id';

    final DateTime now =
        DateTime.now();

    if (_shownVisualWarningKeys.contains(warningKey)) {
      return;
    }

    if (_lastVisualWarningKey ==
            warningKey &&
        _lastVisualWarningTime !=
            null &&
        now.difference(
              _lastVisualWarningTime!,
            ) <
            _visualWarningCooldown) {
      return;
    }

    _shownVisualWarningKeys.add(warningKey);
    _lastVisualWarningKey = warningKey;
    _lastVisualWarningTime = now;

    // SnackBar always provides a visible warning even when
    // a dialog cannot be shown.
    _showSnackBar(
      message,
      _statusColor(
        normalized,
      ),
      duration: normalized ==
              'CRITICAL'
          ? const Duration(
              seconds: 5,
            )
          : const Duration(
              seconds: 3,
            ),
    );

    // HIGH remains a visual card/SnackBar warning. A full dialog is reserved
    // for a true CRITICAL event to avoid interrupting the user repeatedly.
    if (normalized != 'CRITICAL') {
      return;
    }

    _showEmergencyDialog(
      status: normalized,
      message: message,
      vehicle: vehicle,
    );
  }

  // =====================================================
  // EMERGENCY DIALOG
  // =====================================================

  void _showEmergencyDialog({
    required String status,
    required String message,
    required Map<String, dynamic>?
        vehicle,
  }) {
    if (!mounted ||
        _warningDialogVisible) {
      return;
    }

    _warningDialogVisible = true;

    final String id =
        _getVehicleId(
      vehicle,
    );

    final double distance =
        vehicle == null
            ? -1
            : _distanceFromVehicle(
                vehicle,
              );

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (
        BuildContext dialogContext,
      ) {
        return PopScope(
          canPop: true,
          child: AlertDialog(
            icon: Icon(
              status == 'CRITICAL'
                  ? Icons
                      .warning_amber_rounded
                  : Icons
                      .warning_rounded,
              size: 54,
              color: _statusColor(
                status,
              ),
            ),
            title: Text(
              status == 'CRITICAL'
                  ? 'COLLISION WARNING!'
                  : 'HIGH COLLISION RISK!',
              textAlign:
                  TextAlign.center,
              style: TextStyle(
                color: _statusColor(
                  status,
                ),
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            content: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                Text(
                  message,
                  textAlign:
                      TextAlign.center,
                  style:
                      const TextStyle(
                    fontSize: 16,
                    fontWeight:
                        FontWeight.w600,
                  ),
                ),
                const SizedBox(
                  height: 16,
                ),
                if (id.isNotEmpty)
                  _warningInfoRow(
                    Icons
                        .directions_car,
                    'Vehicle',
                    id,
                  ),
                if (distance.isFinite &&
                    distance >= 0)
                  _warningInfoRow(
                    Icons
                        .straighten,
                    'Distance',
                    '${distance.toStringAsFixed(1)} m',
                  ),
              ],
            ),
            actions: [
              if (status ==
                  'CRITICAL')
                TextButton(
                  onPressed: () {
                    Navigator.of(
                      dialogContext,
                    ).pop();

                    _warningDialogVisible =
                        false;
                  },
                  child: const Text(
                    'I UNDERSTAND',
                  ),
                ),
              if (status !=
                  'CRITICAL')
                FilledButton(
                  onPressed: () {
                    Navigator.of(
                      dialogContext,
                    ).pop();

                    _warningDialogVisible =
                        false;
                  },
                  child:
                      const Text(
                    'OK',
                  ),
                ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      _warningDialogVisible =
          false;
    });
  }

  // =====================================================
  // WARNING INFO ROW
  // =====================================================

  Widget _warningInfoRow(
    IconData icon,
    String label,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.only(
        bottom: 8,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
          ),
          const SizedBox(
            width: 10,
          ),
          Text(
            '$label: ',
            style:
                const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign:
                  TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // STATUS COLORS
  // =====================================================

  Color _statusColor(
    String status,
  ) {
    switch (
      _normalizeStatus(
        status,
      )
    ) {
      case 'CRITICAL':
        return Colors.red;

      case 'HIGH':
        return Colors.deepOrange;

      case 'MEDIUM':
        return Colors.orange;

      case 'EARLY':
        return Colors.amber.shade700;

      case 'SAFE':
      default:
        return Colors.green;
    }
  }

  // =====================================================
  // STATUS ICONS
  // =====================================================

  IconData _statusIcon(
    String status,
  ) {
    switch (
      _normalizeStatus(
        status,
      )
    ) {
      case 'CRITICAL':
        return Icons
            .warning_amber_rounded;

      case 'HIGH':
        return Icons
            .dangerous_rounded;

      case 'MEDIUM':
        return Icons
            .warning_rounded;

      case 'EARLY':
        return Icons
            .visibility_rounded;

      case 'SAFE':
      default:
        return Icons
            .verified_user_rounded;
    }
  }

  // =====================================================
  // STATUS DESCRIPTION
  // =====================================================

  String _statusDescription(
    String status,
  ) {
    switch (
      _normalizeStatus(
        status,
      )
    ) {
      case 'CRITICAL':
        return 'Immediate collision danger';

      case 'HIGH':
        return 'High collision risk detected';

      case 'MEDIUM':
        return 'Potential collision risk';

      case 'EARLY':
        return 'Nearby vehicle detected';

      case 'SAFE':
      default:
        return 'No immediate collision risk';
    }
  }

  // =====================================================
  // SNACKBAR
  // =====================================================

  void _showSnackBar(
    String message,
    Color color, {
    Duration duration =
        const Duration(
      seconds: 3,
    ),
  }) {
    if (!mounted) {
      return;
    }

    final ScaffoldMessengerState
        messenger =
        ScaffoldMessenger.of(
      context,
    );

    messenger.hideCurrentSnackBar();

    messenger.showSnackBar(
      SnackBar(
        duration: duration,
        behavior:
            SnackBarBehavior.floating,
        backgroundColor:
            color,
        content: Text(
          message,
          style:
              const TextStyle(
            color: Colors.white,
            fontWeight:
                FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // =====================================================
  // SIMULATE ONE VEHICLE
  // =====================================================

  Future<void>
      simulateVehicle() async {
    if (simulationLoading) {
      return;
    }

    setState(() {
      simulationLoading = true;
    });

    try {
      final Map<String, dynamic>
          result =
          await v2vService
              .simulateVehicle();

      if (!mounted) {
        return;
      }

      setState(() {
        simulationRunning = true;
      });

      final String message =
          result['message']
                  ?.toString() ??
              'Vehicle simulation started';

      _showSnackBar(
        message,
        Colors.blue,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      _showSnackBar(
        'Simulation error: $e',
        Colors.red,
      );
    } finally {
      if (mounted) {
        setState(() {
          simulationLoading =
              false;
        });
      }
    }
  }

  // =====================================================
  // STOP VEHICLE SIMULATION
  // =====================================================

  Future<void>
      stopVehicleSimulation() async {
    if (simulationLoading) {
      return;
    }

    setState(() {
      simulationLoading = true;
    });

    try {
      final Map<String, dynamic>
          result =
          await v2vService
              .stopSimulation();

      if (!mounted) {
        return;
      }

      setState(() {
        simulationRunning = false;
      });

      _showSnackBar(
        result['message']
                ?.toString() ??
            'Vehicle simulation stopped',
        Colors.green,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      _showSnackBar(
        'Could not stop simulation: $e',
        Colors.red,
      );
    } finally {
      if (mounted) {
        setState(() {
          simulationLoading =
              false;
        });
      }
    }
  }

  // =====================================================
  // SIMULATE TRAFFIC
  // =====================================================

  Future<void>
      simulateTraffic(
    int count,
  ) async {
    try {
      final Map<String, dynamic>
          result =
          await v2vService
              .simulateTraffic(
        count: count,
      );

      if (!mounted) {
        return;
      }

      _showSnackBar(
        result['message']
                ?.toString() ??
            '$count simulated vehicles started',
        Colors.blue,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      _showSnackBar(
        'Traffic simulation error: $e',
        Colors.red,
      );
    }
  }

  // =====================================================
  // STOP TRAFFIC SIMULATION
  // =====================================================

  Future<void>
      stopTrafficSimulation() async {
    try {
      final Map<String, dynamic>
          result =
          await v2vService
              .stopTrafficSimulation();

      if (!mounted) {
        return;
      }

      _showSnackBar(
        result['message']
                ?.toString() ??
            'Traffic simulation stopped',
        Colors.green,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      _showSnackBar(
        'Could not stop traffic simulation: $e',
        Colors.red,
      );
    }
  }
    // =====================================================
  // BUILD APP
  // =====================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final String normalizedStatus =
        _normalizeStatus(
      safetyStatus,
    );

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F7FF),
        appBar: AppBar(
          elevation: 0,
          backgroundColor: const Color(0xFFEEF2FF),
          surfaceTintColor: Colors.transparent,
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SMART V2V',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
              Text(
                'Vehicle-to-Vehicle Communication',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF5B6478),
                  fontWeight: FontWeight.normal,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh connection',
              onPressed:
                  backendChecking ? null : refreshConnection,
              icon: backendChecking
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Test warning',
              onPressed: testWarningSound,
              icon: const Icon(Icons.volume_up),
            ),
          ],
          bottom: const TabBar(
            // Keep all sections fixed on screen. This removes the empty
            // leading space and horizontal sliding of the tab bar.
            isScrollable: false,
            labelPadding: EdgeInsets.zero,
            tabs: [
              Tab(
                icon: Icon(Icons.dashboard_outlined),
                text: 'Overview',
              ),
              Tab(
                icon: Icon(Icons.directions_car_outlined),
                text: 'Vehicle',
              ),
              Tab(
                icon: Icon(Icons.insights_outlined),
                text: 'Intelligence',
              ),
              Tab(
                icon: Icon(Icons.tune_outlined),
                text: 'Controls',
              ),
            ],
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFF2F6FF),
                Color(0xFFF8F4FF),
                Color(0xFFF3FBF8),
              ],
            ),
          ),
          child: SafeArea(
            top: false,
            child: RefreshIndicator(
              onRefresh: refreshConnection,
              child: TabBarView(
                // Change sections only by tapping the tabs; disable
                // horizontal swipe/slide between pages.
                physics: NeverScrollableScrollPhysics(),
                children: [
                  ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildConnectionStatusCard(),
                      const SizedBox(height: 14),
                      _buildGpsStatusCard(),
                      const SizedBox(height: 14),
                      _buildSafetyStatusCard(normalizedStatus),
                      const SizedBox(height: 30),
                    ],
                  ),
                  ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildVehicleInfoCard(),
                      const SizedBox(height: 30),
                    ],
                  ),
                  ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildTrafficCard(),
                      const SizedBox(height: 14),
                      _buildNearbyVehiclesCard(),
                      const SizedBox(height: 14),
                      _buildMapCard(),
                      const SizedBox(height: 30),
                    ],
                  ),
                  ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildControlsCard(),
                      const SizedBox(height: 30),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // =====================================================
  // CONNECTION STATUS CARD
  // =====================================================

  Widget _buildConnectionStatusCard() {
    final bool v2vConnected =
        v2vService.isConnected;

    return Card(
      elevation: 2,
      shape:
          RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(
          18,
        ),
      ),
      child: Padding(
        padding:
            const EdgeInsets.all(
          16,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child:
                      _buildConnectionItem(
                    icon:
                        Icons.hub_rounded,
                    title: 'V2V',
                    value:
                        v2vConnected
                            ? 'CONNECTED'
                            : 'OFFLINE',
                    active:
                        v2vConnected,
                  ),
                ),
                Container(
                  width: 1,
                  height: 55,
                  color:
                      Colors.grey.shade300,
                ),
                Expanded(
                  child:
                      _buildConnectionItem(
                    icon: Icons.gps_fixed,
                    title: 'GPS',
                    value:
                        gpsConnected
                            ? 'ACTIVE'
                            : 'WAITING',
                    active:
                        gpsConnected,
                  ),
                ),
              ],
            ),
            const SizedBox(
              height: 12,
            ),
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.all(
                10,
              ),
              decoration:
                  BoxDecoration(
                color:
                    Colors.grey.shade100,
                borderRadius:
                    BorderRadius.circular(
                  10,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    backendChecking
                        ? Icons
                            .sync_rounded
                        : Icons
                            .info_outline_rounded,
                    size: 18,
                    color:
                        Colors.grey.shade700,
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                    child: Text(
                      backendStatusMessage,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors
                            .grey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionItem({
    required IconData icon,
    required String title,
    required String value,
    required bool active,
  }) {
    return Column(
      children: [
        Icon(
          icon,
          size: 28,
          color:
              active
                  ? Colors.green
                  : Colors.red,
        ),
        const SizedBox(
          height: 6,
        ),
        Text(
          title,
          style:
              const TextStyle(
            fontWeight:
                FontWeight.bold,
          ),
        ),
        const SizedBox(
          height: 3,
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            color:
                active
                    ? Colors.green
                    : Colors.red,
            fontWeight:
                FontWeight.bold,
          ),
        ),
      ],
    );
  }


  // =====================================================
  // GPS STATUS CARD
  // =====================================================

  String _gpsQualityLabel() {
    if (!gpsConnected || gpsAccuracyMeters >= 999) {
      return 'Waiting for GPS';
    }
    if (gpsAccuracyMeters <= 10) {
      return 'Excellent';
    }
    if (gpsAccuracyMeters <= 20) {
      return 'Good';
    }
    if (gpsAccuracyMeters <= 50) {
      return 'Weak';
    }
    return 'Poor';
  }

  Color _gpsQualityColor() {
    if (!gpsConnected || gpsAccuracyMeters >= 999) {
      return Colors.grey;
    }
    if (gpsAccuracyMeters <= 20) {
      return Colors.green;
    }
    if (gpsAccuracyMeters <= 50) {
      return Colors.orange;
    }
    return Colors.red;
  }

  String _lastGpsUpdateLabel() {
    if (lastGpsUpdate == null) {
      return 'No location fix yet';
    }

    final Duration age = DateTime.now().difference(lastGpsUpdate!);

    if (age.inSeconds < 5) {
      return 'Just now';
    }
    if (age.inSeconds < 60) {
      return '${age.inSeconds}s ago';
    }
    if (age.inMinutes < 60) {
      return '${age.inMinutes} min ago';
    }
    return '${age.inHours}h ago';
  }

  Widget _buildGpsStatusCard() {
    final Color qualityColor = _gpsQualityColor();
    final bool hasFix =
        gpsConnected && gpsAccuracyMeters.isFinite && gpsAccuracyMeters < 999;

    final String accuracyText = hasFix
        ? '±${gpsAccuracyMeters.toStringAsFixed(1)} m'
        : 'Waiting';

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: qualityColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.gps_fixed_rounded,
                    color: qualityColor,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'GPS Status',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: qualityColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _gpsQualityLabel().toUpperCase(),
                    style: TextStyle(
                      color: qualityColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildGpsMetric(
                    icon: Icons.my_location_rounded,
                    label: 'Accuracy',
                    value: accuracyText,
                    color: qualityColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildGpsMetric(
                    icon: Icons.schedule_rounded,
                    label: 'Last Update',
                    value: _lastGpsUpdateLabel(),
                    color: gpsConnected ? Colors.blue : Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildGpsMetric(
                    icon: Icons.north_rounded,
                    label: 'Latitude',
                    value: hasFix
                        ? latitude.toStringAsFixed(6)
                        : '--',
                    color: Colors.indigo,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildGpsMetric(
                    icon: Icons.east_rounded,
                    label: 'Longitude',
                    value: hasFix
                        ? longitude.toStringAsFixed(6)
                        : '--',
                    color: Colors.indigo,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: qualityColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    gpsConnected
                        ? Icons.check_circle_rounded
                        : Icons.info_outline_rounded,
                    color: qualityColor,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      gpsConnected
                          ? 'GPS is active. Lower accuracy values mean a more precise location.'
                          : 'Waiting for a reliable GPS location. Move outdoors if needed.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGpsMetric({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 7),
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // SAFETY STATUS CARD
  // =====================================================

  Widget _buildSafetyStatusCard(
    String status,
  ) {
    final Color color =
        _statusColor(
      status,
    );

    final IconData icon =
        _statusIcon(
      status,
    );

    final bool danger =
        _isDangerStatus(
      status,
    );

    return Card(
      elevation:
          danger ? 5 : 2,
      shape:
          RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(
          18,
        ),
        side: BorderSide(
          color: color.withValues(
            alpha: 0.45,
          ),
          width:
              danger ? 2 : 1,
        ),
      ),
      child: Container(
        width: double.infinity,
        padding:
            const EdgeInsets.all(
          18,
        ),
        decoration:
            BoxDecoration(
          borderRadius:
              BorderRadius.circular(
            18,
          ),
          color:
              color.withValues(
            alpha:
                danger ? 0.10 : 0.05,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size:
                  danger ? 48 : 40,
              color: color,
            ),
            const SizedBox(
              height: 8,
            ),
            Text(
              status == 'EARLY'
                  ? 'MONITORING'
                  : status,
              style: TextStyle(
                fontSize: 24,
                fontWeight:
                    FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(
              height: 6,
            ),
            Text(
              _statusDescription(
                status,
              ),
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.w600,
              ),
            ),
            const SizedBox(
              height: 12,
            ),
            Text(
              collisionMessage,
              textAlign:
                  TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color:
                    Colors.grey.shade800,
              ),
            ),
            if (warningVehicle !=
                null) ...[
              const SizedBox(
                height: 14,
              ),
              _buildThreatVehicleDetails(),
            ],
          ],
        ),
      ),
    );
  }

  // =====================================================
  // THREAT VEHICLE DETAILS
  // =====================================================

  Widget _buildThreatVehicleDetails() {
    final Map<String, dynamic>
        vehicle =
        warningVehicle!;

    final String id =
        _getVehicleId(
      vehicle,
    );

    final String type =
        _getVehicleType(
      vehicle,
    );

    final double distance =
        _distanceFromVehicle(
      vehicle,
    );

    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.all(
        12,
      ),
      decoration:
          BoxDecoration(
        color: Colors.white,
        borderRadius:
            BorderRadius.circular(
          12,
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons
                .directions_car_filled_rounded,
          ),
          const SizedBox(
            width: 10,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  id.isEmpty
                      ? 'Nearby Vehicle'
                      : id,
                  style:
                      const TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                Text(
                  type,
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
          if (distance.isFinite)
            Text(
              '${distance.toStringAsFixed(1)} m',
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  // =====================================================
  // MAP CARD
  // =====================================================

  Widget _buildMapCard() {
    final LatLng currentPosition =
        LatLng(
      latitude,
      longitude,
    );

    return Card(
      elevation: 2,
      clipBehavior:
          Clip.antiAlias,
      shape:
          RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(
          18,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(
              16,
              14,
              16,
              8,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.map_rounded,
                ),
                const SizedBox(
                  width: 8,
                ),
                const Text(
                  'Live Vehicle Map',
                  style:
                      TextStyle(
                    fontSize: 17,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '${liveMapVehicles.length} active',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 280,
            child: FlutterMap(
              mapController:
                  mapController,
              options:
                  MapOptions(
                initialCenter:
                    currentPosition,
                initialZoom: 16,
                minZoom: 3,
                maxZoom: 19,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName:
                      'com.example.v2v_app',
                ),
                MarkerLayer(
                  markers:
                      _buildMapMarkers(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // MAP MARKERS
  // =====================================================

  List<Marker> _buildMapMarkers() {
    final List<Marker> markers = [];

    markers.add(
      Marker(
        point: LatLng(
          latitude,
          longitude,
        ),
        width: 58,
        height: 58,
        child:
            _buildOwnVehicleMarker(),
      ),
    );

    for (final dynamic item
        in liveMapVehicles) {
      if (item is! Map) {
        continue;
      }

      final Map<String, dynamic>
          vehicle =
          Map<String, dynamic>.from(
        item,
      );

      final double? lat =
          _getVehicleLatitude(
        vehicle,
      );

      final double? lng =
          _getVehicleLongitude(
        vehicle,
      );

      if (lat == null ||
          lng == null) {
        continue;
      }

      final double distance =
          _distanceFromVehicle(
        vehicle,
      );

      final String status =
          _calculateLocalRiskStatus(
        vehicle,
        distance,
      );

      markers.add(
        Marker(
          point:
              LatLng(
            lat,
            lng,
          ),
          width: 52,
          height: 52,
          child:
              _buildNearbyVehicleMarker(
            vehicle,
            status,
          ),
        ),
      );
    }

    return markers;
  }

  Widget _buildOwnVehicleMarker() {
    return Stack(
      alignment:
          Alignment.center,
      children: [
        Container(
          width: 50,
          height: 50,
          decoration:
              BoxDecoration(
            color:
                Colors.blue.withValues(
              alpha: 0.22,
            ),
            shape:
                BoxShape.circle,
          ),
        ),
        const Icon(
          Icons
              .directions_bike_rounded,
          color:
              Colors.blue,
          size: 34,
        ),
      ],
    );
  }

  Widget _buildNearbyVehicleMarker(
    Map<String, dynamic> vehicle,
    String status,
  ) {
    final Color color =
        _statusColor(
      status,
    );

    final String type =
        _getVehicleType(
      vehicle,
    ).toLowerCase();

    final IconData icon =
        type.contains('bike') ||
                type.contains('motor')
            ? Icons
                .two_wheeler_rounded
            : Icons
                .directions_car_filled_rounded;

    return Stack(
      alignment:
          Alignment.center,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration:
              BoxDecoration(
            color:
                color.withValues(
              alpha: 0.22,
            ),
            shape:
                BoxShape.circle,
          ),
        ),
        Icon(
          icon,
          size: 30,
          color: color,
        ),
      ],
    );
  }
    // =====================================================
  // VEHICLE INFORMATION CARD
  // =====================================================

  Widget _buildVehicleInfoCard() {
    final String displayName =
        vehicleName.isEmpty ? 'My $vehicleType' : vehicleName;

    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Colors.indigo.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    _vehicleIcon(vehicleType),
                    color: Colors.indigo,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'My Vehicle',
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Edit Vehicle Details',
                  onPressed: _showVehicleSettingsDialog,
                  icon: const Icon(Icons.edit_rounded),
                ),
              ],
            ),

            const SizedBox(height: 20),

            Text(
              displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),

            const SizedBox(height: 6),

            Row(
              children: [
                Icon(
                  Icons.badge_outlined,
                  size: 17,
                  color: Colors.blueGrey,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    vehicleId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.blueGrey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.indigo.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    vehicleType,
                    style: const TextStyle(
                      color: Colors.indigo,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 18),
            const Divider(height: 1),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: _buildVehicleMetric(
                    icon: Icons.speed_rounded,
                    label: 'Speed',
                    value: '${speed.toStringAsFixed(1)} km/h',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildVehicleMetric(
                    icon: Icons.explore_rounded,
                    label: 'Direction',
                    value: '${direction.toStringAsFixed(1)}°',
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: _buildVehicleMetric(
                    icon: Icons.location_on_rounded,
                    label: 'GPS',
                    value:
                        '${latitude.toStringAsFixed(4)}, '
                        '${longitude.toStringAsFixed(4)}',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildVehicleMetric(
                    icon: braking
                        ? Icons.warning_rounded
                        : Icons.check_circle_rounded,
                    label: 'Braking',
                    value: braking ? 'YES' : 'NO',
                    valueColor:
                        braking ? Colors.orange : Colors.green,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 18),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _showVehicleSettingsDialog,
                icon: const Icon(Icons.edit_rounded),
                label: const Text('Edit Vehicle Details'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVehicleMetric({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 22,
            color: Colors.blueGrey,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.blueGrey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _vehicleIcon(String type) {
    switch (type.toLowerCase()) {
      case 'bike':
        return Icons.two_wheeler_rounded;
      case 'bus':
        return Icons.directions_bus_rounded;
      case 'truck':
        return Icons.local_shipping_rounded;
      case 'ambulance':
        return Icons.emergency_rounded;
      case 'car':
      default:
        return Icons.directions_car_filled_rounded;
    }
  }


  // =====================================================
  // GENERIC INFORMATION ROW
  // =====================================================

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 21,
          color: Colors.blueGrey,
        ),

        const SizedBox(width: 10),

        Text(
          '$label:',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
          ),
        ),

        const Spacer(),

        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: valueColor,
            ),
          ),
        ),
      ],
    );
  }

  // =====================================================
  // TRAFFIC CARD
  // =====================================================

  Widget _buildTrafficCard() {
    final String density =
        trafficDensity.isEmpty
            ? 'LIGHT'
            : trafficDensity;

    final Color densityColor =
        _trafficDensityColor(
      density,
    );

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.traffic_rounded,
                ),
                SizedBox(width: 8),
                Text(
                  'Traffic Intelligence',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: _buildTrafficMetric(
                    label: 'Density',
                    value: density,
                    color: densityColor,
                    icon:
                        Icons
                            .bar_chart_rounded,
                  ),
                ),

                const SizedBox(width: 10),

                Expanded(
                  child: _buildTrafficMetric(
                    label: 'Vehicles',
                    value:
                        trafficVehicleCount
                            .toString(),
                    color: Colors.blue,
                    icon:
                        Icons
                            .directions_car_filled_rounded,
                  ),
                ),

                const SizedBox(width: 10),

                Expanded(
                  child: _buildTrafficMetric(
                    label: 'Avg Speed',
                    value:
                        '${trafficAverageSpeed.toStringAsFixed(0)}',
                    color: Colors.green,
                    icon:
                        Icons.speed_rounded,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius:
                    BorderRadius.circular(12),
                color:
                    trafficCongestion
                        ? Colors.orange
                            .withValues(
                            alpha: 0.12,
                          )
                        : Colors.green
                            .withValues(
                            alpha: 0.10,
                          ),
              ),
              child: Row(
                children: [
                  Icon(
                    trafficCongestion
                        ? Icons.warning_rounded
                        : Icons.check_circle_rounded,
                    color:
                        trafficCongestion
                            ? Colors.orange
                            : Colors.green,
                  ),

                  const SizedBox(width: 10),

                  Expanded(
                    child: Text(
                      trafficCongestion
                          ? 'Traffic congestion detected'
                          : 'Traffic flow is normal',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color:
                            trafficCongestion
                                ? Colors.orange.shade800
                                : Colors.green.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // TRAFFIC METRIC
  // =====================================================

  Widget _buildTrafficMetric({
    required String label,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding:
          const EdgeInsets.symmetric(
        vertical: 12,
        horizontal: 8,
      ),
      decoration: BoxDecoration(
        color: color.withValues(
          alpha: 0.08,
        ),
        borderRadius:
            BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: color,
          ),

          const SizedBox(height: 6),

          Text(
            value,
            overflow:
                TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),

          const SizedBox(height: 4),

          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color:
                  Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // TRAFFIC DENSITY COLOR
  // =====================================================

  Color _trafficDensityColor(
    String density,
  ) {
    final String value =
        density.toUpperCase();

    if (value == 'HEAVY' ||
        value == 'HIGH') {
      return Colors.red;
    }

    if (value == 'MEDIUM' ||
        value == 'MODERATE') {
      return Colors.orange;
    }

    return Colors.green;
  }

  // =====================================================
  // NEARBY VEHICLES CARD
  // =====================================================

  Widget _buildNearbyVehiclesCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.radar_rounded,
                ),

                const SizedBox(width: 8),

                const Text(
                  'Nearby Vehicles',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const Spacer(),

                Container(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue
                        .withValues(
                      alpha: 0.10,
                    ),
                    borderRadius:
                        BorderRadius.circular(
                      20,
                    ),
                  ),
                  child: Text(
                    nearbyVehicles.length
                        .toString(),
                    style: const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            if (nearbyVehicles.isEmpty)
              _buildNoVehiclesView()
            else
              ...nearbyVehicles.map(
                (
                  dynamic item,
                ) {
                  if (item is! Map) {
                    return const SizedBox();
                  }

                  final Map<String, dynamic>
                      vehicle =
                      Map<String, dynamic>.from(
                    item,
                  );

                  return Padding(
                    padding:
                        const EdgeInsets.only(
                      bottom: 10,
                    ),
                    child:
                        _buildNearbyVehicleTile(
                      vehicle,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // NO VEHICLES VIEW
  // =====================================================

  Widget _buildNoVehiclesView() {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(
        vertical: 28,
      ),
      decoration: BoxDecoration(
        color: Colors.grey
            .withValues(
          alpha: 0.07,
        ),
        borderRadius:
            BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(
            Icons.radar_rounded,
            size: 42,
            color:
                Colors.grey.shade500,
          ),

          const SizedBox(height: 8),

          Text(
            'No nearby vehicles detected',
            style: TextStyle(
              color:
                  Colors.grey.shade700,
              fontWeight:
                  FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // NEARBY VEHICLE TILE
  // =====================================================

  Widget _buildNearbyVehicleTile(
    Map<String, dynamic> vehicle,
  ) {
    final String id =
        _getVehicleId(
      vehicle,
    );

    final String type =
        _getVehicleType(
      vehicle,
    );

    final double vehicleSpeed =
        _getVehicleSpeed(
      vehicle,
    );

    final double distance =
        _distanceFromVehicle(
      vehicle,
    );

    final String riskStatus =
        _calculateLocalRiskStatus(
      vehicle,
      distance,
    );

    final Color color =
        _statusColor(
      riskStatus,
    );

    final bool primary =
        _isPrimaryThreat(
      vehicle,
    );

    final IconData vehicleIcon =
        type.toLowerCase().contains(
              'bike',
            ) ||
            type.toLowerCase().contains(
              'motor',
            )
        ? Icons.two_wheeler_rounded
        : Icons
            .directions_car_filled_rounded;

    return Container(
      padding:
          const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: primary
            ? color.withValues(
                alpha: 0.13,
              )
            : Colors.grey.withValues(
                alpha: 0.06,
              ),
        borderRadius:
            BorderRadius.circular(14),
        border: Border.all(
          color: primary
              ? color
              : Colors.transparent,
          width: primary ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration:
                BoxDecoration(
              color: color.withValues(
                alpha: 0.14,
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(
              vehicleIcon,
              color: color,
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  id.isEmpty
                      ? 'Unknown Vehicle'
                      : id,
                  style: const TextStyle(
                    fontWeight:
                        FontWeight.bold,
                    fontSize: 16,
                  ),
                ),

                const SizedBox(height: 3),

                Text(
                  '$type • '
                  '${vehicleSpeed.toStringAsFixed(0)} km/h',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        Colors.grey.shade700,
                  ),
                ),

                const SizedBox(height: 8),

                Container(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration:
                      BoxDecoration(
                    color:
                        color.withValues(
                      alpha: 0.12,
                    ),
                    borderRadius:
                        BorderRadius.circular(
                      8,
                    ),
                  ),
                  child: Text(
                    riskStatus == 'EARLY'
                        ? 'MONITORING'
                        : riskStatus,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight:
                          FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 10),

          Column(
            crossAxisAlignment:
                CrossAxisAlignment.end,
            children: [
              Text(
                distance.isFinite
                    ? '${distance.toStringAsFixed(1)} m'
                    : '--',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight:
                      FontWeight.bold,
                  color: color,
                ),
              ),

              const SizedBox(height: 4),

              Text(
                'Distance',
                style: TextStyle(
                  fontSize: 10,
                  color:
                      Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // =====================================================
  // CONTROLS CARD
  // =====================================================

  Widget _buildControlsCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.tune_rounded,
                ),

                SizedBox(width: 8),

                Text(
                  'Testing & Simulation',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed:
                    simulationLoading
                        ? null
                        : simulationRunning
                            ? stopVehicleSimulation
                            : simulateVehicle,
                icon: simulationLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(
                        simulationRunning
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                      ),
                label: Text(
                  simulationRunning
                      ? 'STOP SIMULATED VEHICLE'
                      : 'SIMULATE VEHICLE',
                ),
                style:
                    ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(
                    vertical: 15,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        simulateTraffic(
                      3,
                    ),
                    icon: const Icon(
                      Icons
                          .traffic_rounded,
                    ),
                    label: const Text(
                      'SIMULATE 3',
                    ),
                  ),
                ),

                const SizedBox(width: 10),

                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        stopTrafficSimulation,
                    icon: const Icon(
                      Icons.stop_rounded,
                    ),
                    label: const Text(
                      'STOP TRAFFIC',
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed:
                    testWarningSound,
                icon: const Icon(
                  Icons.volume_up_rounded,
                ),
                label: const Text(
                  'TEST COLLISION ALERT',
                ),
              ),
            ),

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: refreshGps,
                icon: const Icon(Icons.my_location_rounded),
                label: const Text('REFRESH GPS'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
              ),
            ),

            const SizedBox(height: 10),

            Text(
              'For testing collision alerts, simulated '
              'vehicles can be used when indoor GPS is '
              'not accurate enough.',
              style: TextStyle(
                fontSize: 11,
                color:
                    Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

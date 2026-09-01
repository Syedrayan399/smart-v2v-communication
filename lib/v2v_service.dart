import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;

/// V2V Socket.IO service.
///
/// Supports:
/// - Wi-Fi / local network backend
/// - Internet / ngrok HTTPS backend
/// - Automatic Socket.IO reconnection
/// - Vehicle re-registration after reconnect
/// - Optional shared-secret authentication
/// - Nearby vehicle events
/// - Collision warning events
/// - Vehicle position events
/// - Simulation HTTP APIs
class V2VService {
  IO.Socket? _socket;

  late final String _baseUrl;

  String? _vehicleId;
  String? _vehicleType;

  double? _latitude;
  double? _longitude;

  double _speed = 0;
  double _direction = 0;
  bool _braking = false;

  bool _disposed = false;
  bool _isConnecting = false;

  V2VService() {
    _baseUrl = _resolveBaseUrl();

    print('🌐 ========================================');
    print('🌐 V2V SERVICE INITIALIZED');
    print('🌐 Server URL: $_baseUrl');
    print('🌐 Connection mode: $connectionMode');
    print('🌐 ========================================');
  }

  // ============================================================
  // SERVER URL
  // ============================================================

  String _resolveBaseUrl() {
    const configuredUrl = String.fromEnvironment(
      'V2V_SERVER_URL',
      defaultValue: '',
    );

    String url = configuredUrl.trim();

    if (url.isEmpty) {
      throw StateError(
        'V2V_SERVER_URL is not configured.\n\n'
        'For Wi-Fi/local network:\n'
        '--dart-define=V2V_SERVER_URL=http://YOUR_PC_IP:3000\n\n'
        'For Internet/ngrok:\n'
        '--dart-define=V2V_SERVER_URL=https://YOUR-NGROK-URL.ngrok-free.app',
      );
    }

    if (!url.startsWith('http://') &&
        !url.startsWith('https://')) {
      url = 'https://$url';
    }

    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    return url;
  }

  // ============================================================
  // AUTHENTICATION
  // ============================================================

  String get _authToken {
    const token = String.fromEnvironment(
      'V2V_SHARED_SECRET',
      defaultValue: '',
    );

    return token.trim();
  }

  // ============================================================
  // PUBLIC PROPERTIES
  // ============================================================

  String get baseUrl => _baseUrl;

  bool get usesInternetBackend {
    return _baseUrl.startsWith('https://');
  }

  bool get usesLocalNetworkBackend {
    return _baseUrl.startsWith('http://');
  }

  String get connectionMode {
    if (usesInternetBackend) {
      return 'INTERNET / HTTPS / WSS';
    }

    return 'WI-FI / LOCAL NETWORK';
  }

  bool get isConnected {
    return _socket?.connected ?? false;
  }

  // ============================================================
  // CALLBACKS
  // ============================================================

  Function(List<dynamic>, Map<String, dynamic>)?
      onNearbyVehicles;

  Function(Map<String, dynamic>)?
      onCollisionWarning;

  Function(Map<String, dynamic>)?
      onVehiclePosition;

  Function(String)?
      onVehicleRemoved;

  Function()?
      onConnected;

  Function()?
      onDisconnected;

  Function(String)?
      onRegistrationSuccess;

  Function(String)?
      onConnectionError;

  Function(String)?
      onRegistrationError;

  // ============================================================
  // CONNECT
  // ============================================================

  void connect({
    required String vehicleId,
    required String vehicleType,
    required double latitude,
    required double longitude,
  }) {
    _disposed = false;

    _vehicleId = vehicleId;
    _vehicleType = vehicleType;
    _latitude = latitude;
    _longitude = longitude;

    print('🔌 ========================================');
    print('🔌 CONNECTING V2V');
    print('🌐 URL: $_baseUrl');
    print('🚗 Vehicle ID: $vehicleId');
    print('🚙 Vehicle Type: $vehicleType');
    print('📍 Latitude: $latitude');
    print('📍 Longitude: $longitude');
    print('🔌 Mode: $connectionMode');
    print('🔌 ========================================');

    final existingSocket = _socket;

    // Prevent duplicate active connections.
    if (_isConnecting) {
      print('ℹ️ Socket is already connecting.');
      return;
    }

    if (existingSocket != null && existingSocket.connected) {
      print('ℹ️ Socket is already connected.');

      // Update latest location and make sure backend receives it.
      updateVehicle(
        vehicleId: vehicleId,
        latitude: latitude,
        longitude: longitude,
        speed: _speed,
        direction: _direction,
        braking: _braking,
      );

      return;
    }

    _isConnecting = true;

    _disposeCurrentSocket();

    final hasToken = _authToken.isNotEmpty;

    final builder = IO.OptionBuilder()
        .setTransports([
          'websocket',
          'polling',
        ])
        .disableAutoConnect()
        .enableForceNew()
        .enableReconnection()
        .setReconnectionAttempts(999999)
        .setReconnectionDelay(1000)
        .setReconnectionDelayMax(5000)
        .setTimeout(15000);

    if (hasToken) {
      builder.setQuery({
        'token': _authToken,
      });

      builder.setAuth({
        'token': _authToken,
      });

      print('🔐 V2V shared secret configured.');
    } else {
      print('🔓 No V2V shared secret configured.');
    }

    final socket = IO.io(
      _baseUrl,
      builder.build(),
    );

    _socket = socket;

    // ==========================================================
    // CONNECT
    // ==========================================================

    socket.onConnect((_) {
      if (!identical(socket, _socket) || _disposed) {
        return;
      }

      _isConnecting = false;

      print('✅ ========================================');
      print('✅ V2V SOCKET CONNECTED');
      print('✅ Socket ID: ${socket.id}');
      print('🌐 Server: $_baseUrl');
      print('✅ ========================================');

      developer.log(
        'V2V socket connected: ${socket.id}',
        name: 'V2VService',
      );

      // Always register again after a successful connection
      // or reconnection.
      _registerCurrentVehicle();

      onConnected?.call();
    });

    // ==========================================================
    // DISCONNECT
    // ==========================================================

    socket.onDisconnect((data) {
      if (!identical(socket, _socket)) {
        return;
      }

      _isConnecting = false;

      print('⚠️ V2V SOCKET DISCONNECTED');
      print('Reason: $data');

      developer.log(
        'V2V socket disconnected: $data',
        name: 'V2VService',
      );

      if (!_disposed) {
        onDisconnected?.call();
      }
    });

    // ==========================================================
    // CONNECT ERROR
    // ==========================================================

    socket.onConnectError((data) {
      if (!identical(socket, _socket) || _disposed) {
        return;
      }

      _isConnecting = false;

      final message = data.toString();

      print('❌ V2V CONNECTION ERROR');
      print(message);

      developer.log(
        'V2V connection error: $message',
        name: 'V2VService',
        error: data,
      );

      onConnectionError?.call(message);
    });

    // ==========================================================
    // RECONNECT EVENTS
    // ==========================================================

    socket.onReconnectAttempt((data) {
      print('🔄 Reconnection attempt: $data');
    });

    socket.onReconnectError((data) {
      print('⚠️ Reconnection error: $data');
    });

    socket.onReconnectFailed((data) {
      print('❌ Reconnection failed: $data');
    });

    socket.onReconnect((data) {
      print('✅ Socket reconnected after $data attempts.');

      if (!_disposed && identical(socket, _socket)) {
        _registerCurrentVehicle();
      }
    });

    // ==========================================================
    // GENERAL ERROR
    // ==========================================================

    socket.onError((data) {
      if (!identical(socket, _socket) || _disposed) {
        return;
      }

      print('⚠️ SOCKET ERROR: $data');

      developer.log(
        'V2V socket error: $data',
        name: 'V2VService',
        error: data,
      );
    });

    // ==========================================================
    // REGISTRATION SUCCESS
    // ==========================================================

    socket.on(
      'registrationSuccess',
      (data) {
        if (!identical(socket, _socket) || _disposed) {
          return;
        }

        if (data is Map &&
            data['vehicleId'] != null) {
          final id =
              data['vehicleId'].toString();

          print(
            '✅ VEHICLE REGISTERED SUCCESSFULLY: $id',
          );

          onRegistrationSuccess?.call(id);
        }
      },
    );

    // ==========================================================
    // REGISTRATION ERROR
    // ==========================================================

    socket.on(
      'registrationError',
      (data) {
        if (!identical(socket, _socket) || _disposed) {
          return;
        }

        String message;

        if (data is Map &&
            data['message'] != null) {
          message =
              data['message'].toString();
        } else {
          message = data.toString();
        }

        print(
          '❌ VEHICLE REGISTRATION ERROR: $message',
        );

        onRegistrationError?.call(
          message,
        );
      },
    );

    // ==========================================================
    // VEHICLE REPLACED
    // ==========================================================

    socket.on(
      'vehicleReplaced',
      (data) {
        print(
          '⚠️ This vehicle connection was replaced: $data',
        );
      },
    );

    // ==========================================================
    // NEARBY VEHICLES
    // ==========================================================

    socket.on(
      'nearbyVehicles',
      (data) {
        if (!identical(socket, _socket) ||
            _disposed ||
            data is! Map) {
          return;
        }

        final rawVehicles =
            data['vehicles'];

        if (rawVehicles is! List) {
          return;
        }

        final vehicles =
            List<dynamic>.from(
          rawVehicles,
        );

        Map<String, dynamic>
            trafficDensity = {};

        if (data['trafficDensity'] is Map) {
          trafficDensity =
              Map<String, dynamic>.from(
            data['trafficDensity'] as Map,
          );
        }

        onNearbyVehicles?.call(
          vehicles,
          trafficDensity,
        );
      },
    );

    // ==========================================================
    // COLLISION WARNING
    // ==========================================================

    socket.on(
      'collisionWarning',
      (data) {
        if (!identical(socket, _socket) ||
            _disposed ||
            data is! Map) {
          return;
        }

        onCollisionWarning?.call(
          Map<String, dynamic>.from(
            data,
          ),
        );
      },
    );

    // ==========================================================
    // VEHICLE POSITION
    // ==========================================================

    socket.on(
      'vehiclePosition',
      (data) {
        if (!identical(socket, _socket) ||
            _disposed ||
            data is! Map) {
          return;
        }

        onVehiclePosition?.call(
          Map<String, dynamic>.from(
            data,
          ),
        );
      },
    );

    // ==========================================================
    // VEHICLE REMOVED
    // ==========================================================

    socket.on(
      'vehicleRemoved',
      (data) {
        if (!identical(socket, _socket) ||
            _disposed ||
            data is! Map) {
          return;
        }

        final vehicleId =
            data['vehicleId'];

        if (vehicleId != null) {
          onVehicleRemoved?.call(
            vehicleId.toString(),
          );
        }
      },
    );

    // ==========================================================
    // START CONNECTION
    // ==========================================================

    socket.connect();

    print(
      '⏳ V2V socket connection started...',
    );
  }

  // ============================================================
  // REGISTER VEHICLE
  // ============================================================

  void _registerCurrentVehicle() {
    final socket = _socket;

    final vehicleId = _vehicleId;
    final vehicleType = _vehicleType;

    final latitude = _latitude;
    final longitude = _longitude;

    if (socket == null ||
        !socket.connected ||
        _disposed) {
      print(
        '⚠️ Cannot register: socket is not connected.',
      );
      return;
    }

    if (vehicleId == null ||
        vehicleType == null ||
        latitude == null ||
        longitude == null) {
      print(
        '⚠️ Cannot register: vehicle information is incomplete.',
      );
      return;
    }

    final payload = {
      'vehicleId': vehicleId,
      'type': vehicleType,
      'latitude': latitude,
      'longitude': longitude,
      'speed': _speed,
      'direction': _direction,
      'braking': _braking,
    };

    print(
      '📤 REGISTERING VEHICLE: $vehicleId',
    );

    socket.emit(
      'registerVehicle',
      payload,
    );
  }

  // ============================================================
  // UPDATE VEHICLE
  // ============================================================

  void updateVehicle({
    required String vehicleId,
    required double latitude,
    required double longitude,
    required double speed,
    required double direction,
    required bool braking,
  }) {
    _vehicleId = vehicleId;
    _latitude = latitude;
    _longitude = longitude;
    _speed = speed;
    _direction = direction;
    _braking = braking;

    final socket = _socket;

    if (socket == null ||
        !socket.connected ||
        _disposed) {
      return;
    }

    socket.emit(
      'vehicleUpdate',
      {
        'vehicleId': vehicleId,
        'latitude': latitude,
        'longitude': longitude,
        'speed': speed,
        'direction': direction,
        'braking': braking,
      },
    );
  }

  // ============================================================
  // HTTP AUTH HEADERS
  // ============================================================

  Map<String, String> _authHeaders({
    Map<String, String>? additionalHeaders,
  }) {
    final headers =
        <String, String>{};

    if (additionalHeaders != null) {
      headers.addAll(
        additionalHeaders,
      );
    }

    final token = _authToken;

    if (token.isNotEmpty) {
      headers['x-v2v-token'] =
          token;

      headers['Authorization'] =
          'Bearer $token';
    }

    return headers;
  }

  // ============================================================
  // BACKEND STATUS
  // ============================================================

  Future<bool> checkBackend() async {
    try {
      final response = await _get(
        '/api/status',
        timeout: const Duration(
          seconds: 8,
        ),
      );

      return response.statusCode >= 200 &&
          response.statusCode < 300;
    } catch (error) {
      print(
        '⚠️ Backend check failed: $error',
      );

      return false;
    }
  }

  Future<Map<String, dynamic>>
      getBackendStatus() async {
    final response = await _get(
      '/api/status',
      timeout: const Duration(
        seconds: 8,
      ),
    );

    return _decodeResponse(
      response,
    );
  }

  // ============================================================
  // SINGLE VEHICLE SIMULATION
  // ============================================================

  Future<Map<String, dynamic>>
      simulateVehicle() async {
    final response = await _post(
      '/api/simulate-vehicle',
      timeout: const Duration(
        seconds: 12,
      ),
    );

    return _decodeResponse(
      response,
    );
  }

  Future<Map<String, dynamic>>
      stopSimulation() async {
    final response = await _delete(
      '/api/simulate-vehicle',
      timeout: const Duration(
        seconds: 10,
      ),
    );

    return _decodeResponse(
      response,
    );
  }

  // ============================================================
  // TRAFFIC SIMULATION
  // ============================================================

  Future<Map<String, dynamic>>
      simulateTraffic({
    required int count,
  }) async {
    if (count < 1) {
      throw Exception(
        'Traffic vehicle count must be at least 1.',
      );
    }

    final response = await _post(
      '/api/simulate-traffic',
      headers: {
        'Content-Type':
            'application/json',
      },
      body: jsonEncode({
        'count': count,
      }),
      timeout: const Duration(
        seconds: 15,
      ),
    );

    return _decodeResponse(
      response,
    );
  }

  Future<Map<String, dynamic>>
      stopTrafficSimulation() async {
    final response = await _delete(
      '/api/simulate-traffic',
      timeout: const Duration(
        seconds: 10,
      ),
    );

    return _decodeResponse(
      response,
    );
  }

  // ============================================================
  // STOP ALL SIMULATIONS
  // ============================================================

  Future<void>
      stopAllSimulations() async {
    try {
      final response = await _delete(
        '/api/stop-all-simulations',
        timeout: const Duration(
          seconds: 12,
        ),
      );

      _decodeResponse(
        response,
      );
    } catch (error) {
      print(
        '⚠️ stopAllSimulations failed: $error',
      );

      // Fallback for older backend versions.
      try {
        await stopSimulation();
      } catch (_) {}

      try {
        await stopTrafficSimulation();
      } catch (_) {}
    }
  }

  // ============================================================
  // HTTP GET
  // ============================================================

  Future<http.Response> _get(
    String path, {
    required Duration timeout,
  }) {
    return http
        .get(
          Uri.parse(
            '$_baseUrl$path',
          ),
          headers: _authHeaders(),
        )
        .timeout(timeout);
  }

  // ============================================================
  // HTTP POST
  // ============================================================

  Future<http.Response> _post(
    String path, {
    Map<String, String>? headers,
    Object? body,
    required Duration timeout,
  }) {
    return http
        .post(
          Uri.parse(
            '$_baseUrl$path',
          ),
          headers: _authHeaders(
            additionalHeaders: headers,
          ),
          body: body,
        )
        .timeout(timeout);
  }

  // ============================================================
  // HTTP DELETE
  // ============================================================

  Future<http.Response> _delete(
    String path, {
    required Duration timeout,
  }) {
    return http
        .delete(
          Uri.parse(
            '$_baseUrl$path',
          ),
          headers: _authHeaders(),
        )
        .timeout(timeout);
  }

  // ============================================================
  // RESPONSE DECODER
  // ============================================================

  Map<String, dynamic>
      _decodeResponse(
    http.Response response,
  ) {
    Map<String, dynamic> body = {};

    try {
      if (response.body.isNotEmpty) {
        final decoded =
            jsonDecode(
          response.body,
        );

        if (decoded is Map) {
          body =
              Map<String, dynamic>.from(
            decoded,
          );
        }
      }
    } catch (_) {
      if (response.statusCode >= 400) {
        throw Exception(
          'Backend returned invalid response: '
          '${response.body}',
        );
      }
    }

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      throw Exception(
        body['message']
                ?.toString() ??
            'Backend request failed '
                '(${response.statusCode})',
      );
    }

    return body;
  }

  // ============================================================
  // DISCONNECT
  // ============================================================

  void disconnect() {
    _isConnecting = false;
    _disposeCurrentSocket();
  }

  void _disposeCurrentSocket() {
    final socket = _socket;

    if (socket == null) {
      return;
    }

    _socket = null;

    try {
      socket.clearListeners();

      if (socket.connected) {
        socket.disconnect();
      }

      socket.dispose();
    } catch (error) {
      developer.log(
        'V2V disconnect error',
        name: 'V2VService',
        error: error,
      );
    }
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  void dispose() {
    _disposed = true;
    _isConnecting = false;

    disconnect();
  }
}
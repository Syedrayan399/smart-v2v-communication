const express = require("express");
const http = require("http");
const { Server } = require("socket.io");

const app = express();

const server = http.createServer(app);

// =====================================================
// CONFIGURATION
// =====================================================

const PORT = Number(
  process.env.PORT || 3000
);

// IMPORTANT:
//
// This is NOT your ngrok authtoken.
//
// Set this only if you want V2V authentication.
//
// Windows PowerShell example:
//
// $env:V2V_SHARED_SECRET="my_secret"
// node backend/server.js
//
// Leave empty to disable authentication for local testing.

const V2V_SHARED_SECRET =
  (
    process.env.V2V_SHARED_SECRET ||
    ""
  ).trim();

// =====================================================
// V2V DISTANCE SETTINGS
// =====================================================

// Vehicles are detected and displayed in
// Nearby Vehicles when they are within
// 100 meters.

const DETECTION_RADIUS_METERS =
  100;

// A proximity / collision warning is triggered
// only when another vehicle is 5 meters or closer.

const WARNING_RADIUS_METERS =
  5;

// A vehicle is considered stale when it has not
// sent a GPS update within this time.

const VEHICLE_STALE_AFTER_MS =
  15000;

const appCorsHeaders = {
  "Access-Control-Allow-Origin":
    "*",

  "Access-Control-Allow-Methods":
    "GET,POST,DELETE,OPTIONS",

  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, x-v2v-token",
};

app.use(
  express.json({
    limit: "1mb",
  })
);

app.use(
  (
    request,
    response,
    next
  ) => {
    response.set(
      appCorsHeaders
    );

    if (
      request.method ===
      "OPTIONS"
    ) {
      return response.sendStatus(
        204
      );
    }

    next();
  }
);

// =====================================================
// SOCKET.IO
// =====================================================

const io = new Server(
  server,
  {
    cors: {
      origin: "*",

      methods: [
        "GET",
        "POST",
        "DELETE",
        "OPTIONS",
      ],

      allowedHeaders: [
        "Content-Type",
        "Authorization",
        "x-v2v-token",
      ],
    },

    transports: [
      "polling",
      "websocket",
    ],

    allowUpgrades: true,

    pingInterval:
      10000,

    pingTimeout:
      30000,

    allowEIO3: true,
  }
);

// =====================================================
// VEHICLE STORAGE
// =====================================================

// Stores all connected and simulated vehicles.

const vehicles =
  new Map();

// =====================================================
// ONE-TIME WARNING TRACKING
// =====================================================

// Stores vehicle pairs that have already received
// a warning while they remain inside the
// 5 meter warning radius.
//
// Example:
//
// CAR001::BIKE002
//
// The IDs are sorted so:
//
// CAR001 + BIKE002
//
// and:
//
// BIKE002 + CAR001
//
// always produce the same pair key.

const activeWarningPairs =
  new Set();

// Create a consistent key for two vehicles.

function warningPairKey(
  firstVehicleId,
  secondVehicleId
) {
  return [
    String(
      firstVehicleId
    ),

    String(
      secondVehicleId
    ),
  ]
    .sort()
    .join(
      "::"
    );
}

// Remove every warning state associated
// with a vehicle.
//
// This is used when a vehicle disconnects,
// is deleted, or otherwise removed.

function clearWarningPairsForVehicle(
  vehicleId
) {
  const id =
    String(
      vehicleId
    );

  for (
    const key
    of activeWarningPairs
  ) {
    const pair =
      key.split(
        "::"
      );

    if (
      pair[0] === id ||
      pair[1] === id
    ) {
      activeWarningPairs.delete(
        key
      );
    }
  }
}

let singleSimulationTimer =
  null;

let trafficSimulationTimer =
  null;

let singleSimulationVehicleId =
  null;

let trafficSimulationIds =
  [];

let simulationActive =
  false;

// =====================================================
// ROOT
// =====================================================

app.get(
  "/",
  (
    _request,
    response
  ) => {
    response.json({
      project:
        "SMART V2V COMMUNICATION",

      status:
        "Backend Running",

      service:
        "V2V Socket.IO",

      detectionRadius:
        DETECTION_RADIUS_METERS,

      warningRadius:
        WARNING_RADIUS_METERS,
    });
  }
);

// =====================================================
// HTTP AUTH
// =====================================================

function getHttpToken(
  request
) {
  const customToken =
    request.headers[
      "x-v2v-token"
    ];

  if (
    typeof customToken ===
      "string" &&
    customToken.trim()
  ) {
    return customToken.trim();
  }

  const authorization =
    request.headers.authorization;

  if (
    typeof authorization ===
      "string" &&
    authorization.startsWith(
      "Bearer "
    )
  ) {
    return authorization
      .substring(
        "Bearer ".length
      )
      .trim();
  }

  return "";
}

function requireHttpAuth(
  request,
  response,
  next
) {
  // Authentication is optional.

  if (
    !V2V_SHARED_SECRET
  ) {
    return next();
  }

  const token =
    getHttpToken(
      request
    );

  if (
    token !==
    V2V_SHARED_SECRET
  ) {
    return response
      .status(401)
      .json({
        success: false,

        message:
          "Unauthorized",
      });
  }

  next();
}

// =====================================================
// SOCKET AUTH
// =====================================================

io.use(
  (
    socket,
    next
  ) => {
    // Authentication is optional.

    if (
      !V2V_SHARED_SECRET
    ) {
      return next();
    }

    const queryToken =
      socket.handshake.query
        ?.token;

    const authToken =
      socket.handshake.auth
        ?.token;

    const token =
      typeof authToken ===
        "string" &&
      authToken.trim()
        ? authToken.trim()
        : typeof queryToken ===
            "string"
        ? queryToken.trim()
        : "";

    if (
      token !==
      V2V_SHARED_SECRET
    ) {
      console.warn(
        "SOCKET AUTH REJECTED:",
        socket.id,
        socket.handshake.address
      );

      return next(
        new Error(
          "unauthorized"
        )
      );
    }

    next();
  }
);

// =====================================================
// NUMBER HELPER
// =====================================================

function numberValue(
  value,
  fallback = 0
) {
  const parsed =
    Number(
      value
    );

  return Number.isFinite(
    parsed
  )
    ? parsed
    : fallback;
}

// =====================================================
// VEHICLE STATUS
// =====================================================

function normalizeVehicleStatus(
  status
) {
  const value =
    String(
      status ||
      "ACTIVE"
    )
      .trim()
      .toUpperCase();

  const allowedStatuses = [
    "ACTIVE",
    "PARKED",
    "STOPPED",
    "OFFLINE",
    "EMERGENCY",
  ];

  return allowedStatuses.includes(
    value
  )
    ? value
    : "ACTIVE";
}

// =====================================================
// GPS / VEHICLE ACTIVITY
// =====================================================

function isVehicleStale(
  vehicle
) {
  const lastUpdate =
    numberValue(
      vehicle.lastUpdate,
      0
    );

  if (
    !lastUpdate
  ) {
    return true;
  }

  return (
    Date.now() -
      lastUpdate >
    VEHICLE_STALE_AFTER_MS
  );
}

function getVehicleStatus(
  vehicle
) {
  if (
    vehicle.status ===
    "EMERGENCY"
  ) {
    return "EMERGENCY";
  }

  if (
    isVehicleStale(
      vehicle
    )
  ) {
    return "OFFLINE";
  }

  return normalizeVehicleStatus(
    vehicle.status
  );
}

function isVehicleAvailableForDetection(
  vehicle
) {
  if (
    !vehicle
  ) {
    return false;
  }

  if (
    vehicle.simulated
  ) {
    return true;
  }

  const status =
    getVehicleStatus(
      vehicle
    );

  return (
    status !==
    "OFFLINE"
  );
}

// =====================================================
// COORDINATE VALIDATION
// =====================================================

function isValidCoordinate(
  latitude,
  longitude
) {
  return (
    Number.isFinite(
      latitude
    ) &&
    Number.isFinite(
      longitude
    ) &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180
  );
}

// =====================================================
// DISTANCE CALCULATION
// =====================================================

function calculateDistanceMeters(
  lat1,
  lon1,
  lat2,
  lon2
) {
  const earthRadius =
    6371000;

  const toRadians =
    (
      value
    ) =>
      (
        value *
        Math.PI
      ) /
      180;

  const latitudeDifference =
    toRadians(
      lat2 -
        lat1
    );

  const longitudeDifference =
    toRadians(
      lon2 -
        lon1
    );

  const a =
    Math.sin(
      latitudeDifference /
        2
    ) **
      2 +
    Math.cos(
      toRadians(
        lat1
      )
    ) *
      Math.cos(
        toRadians(
          lat2
        )
      ) *
      Math.sin(
        longitudeDifference /
          2
      ) **
        2;

  const c =
    2 *
    Math.atan2(
      Math.sqrt(
        a
      ),
      Math.sqrt(
        1 - a
      )
    );

  return (
    earthRadius *
    c
  );
}
// =====================================================
// VEHICLE GPS DATA
// =====================================================

function buildVehicleGpsData(
  vehicle
) {
  return {
    vehicleId:
      vehicle.vehicleId,

    id:
      vehicle.vehicleId,

    name:
      vehicle.name ||
      vehicle.vehicleId,

    type:
      vehicle.type ||
      "vehicle",

    status:
      getVehicleStatus(
        vehicle
      ),

    latitude:
      vehicle.latitude,

    longitude:
      vehicle.longitude,

    speed:
      numberValue(
        vehicle.speed
      ),

    direction:
      numberValue(
        vehicle.direction
      ),

    braking:
      vehicle.braking ===
      true,

    gpsAccuracy:
      numberValue(
        vehicle.gpsAccuracy,
        0
      ),

    gpsTimestamp:
      numberValue(
        vehicle.gpsTimestamp,
        vehicle.lastUpdate
      ),

    lastUpdate:
      vehicle.lastUpdate,

    stale:
      isVehicleStale(
        vehicle
      ),

    simulated:
      vehicle.simulated ===
      true,
  };
}

// =====================================================
// TRAFFIC DENSITY
// =====================================================

function calculateTrafficDensity(
  vehicleList
) {
  const count =
    vehicleList.length;

  let averageSpeed =
    0;

  if (
    count > 0
  ) {
    const totalSpeed =
      vehicleList.reduce(
        (
          total,
          vehicle
        ) =>
          total +
          numberValue(
            vehicle.speed
          ),
        0
      );

    averageSpeed =
      totalSpeed /
      count;
  }

  let density =
    "LIGHT";

  let congestion =
    false;

  if (
    count < 10
  ) {
    density =
      "LIGHT";
  } else if (
    count < 15
  ) {
    density =
      "MODERATE";

    congestion =
      averageSpeed <
      15;
  } else {
    density =
      "HEAVY";

    congestion =
      true;
  }

  return {
    density,

    vehicleCount:
      count,

    averageSpeed:
      Number(
        averageSpeed.toFixed(
          1
        )
      ),

    congestion,
  };
}

// =====================================================
// BUILD NEARBY VEHICLES
// =====================================================

function buildNearbyVehicleData(
  ownVehicle
) {
  const nearbyVehicles =
    [];

  // Do not calculate nearby vehicles
  // for an offline / stale real vehicle.

  if (
    !isVehicleAvailableForDetection(
      ownVehicle
    )
  ) {
    return nearbyVehicles;
  }

  for (
    const vehicle
    of vehicles.values()
  ) {
    // Ignore own vehicle.

    if (
      vehicle.vehicleId ===
      ownVehicle.vehicleId
    ) {
      continue;
    }

    // Ignore stale / offline vehicles.

    if (
      !isVehicleAvailableForDetection(
        vehicle
      )
    ) {
      continue;
    }

    const distance =
      calculateDistanceMeters(
        ownVehicle.latitude,
        ownVehicle.longitude,
        vehicle.latitude,
        vehicle.longitude
      );

    // Only include vehicles inside
    // the 100 meter detection radius.

    if (
      distance >
      DETECTION_RADIUS_METERS
    ) {
      continue;
    }

    const insideWarningRadius =
      distance <=
      WARNING_RADIUS_METERS;

    nearbyVehicles.push({
      ...buildVehicleGpsData(
        vehicle
      ),

      distance:
        Number(
          distance.toFixed(
            1
          )
        ),

      withinDetectionRadius:
        true,

      withinWarningRadius:
        insideWarningRadius,

      warningRadius:
        WARNING_RADIUS_METERS,

      detectionRadius:
        DETECTION_RADIUS_METERS,
    });
  }

  // Nearest vehicle first.

  nearbyVehicles.sort(
    (
      first,
      second
    ) =>
      first.distance -
      second.distance
  );

  return nearbyVehicles;
}

// =====================================================
// COLLISION RISK
// =====================================================

function calculateCollisionRisk(
  ownVehicle,
  nearbyVehicle
) {
  const distance =
    calculateDistanceMeters(
      ownVehicle.latitude,
      ownVehicle.longitude,
      nearbyVehicle.latitude,
      nearbyVehicle.longitude
    );

  const ownSpeed =
    numberValue(
      ownVehicle.speed
    );

  const nearbySpeed =
    numberValue(
      nearbyVehicle.speed
    );

  const speedDifference =
    Math.abs(
      nearbySpeed -
      ownSpeed
    );

  const nearbyBraking =
    nearbyVehicle.braking ===
    true;

  let risk =
    "SAFE";

  // A warning is only eligible inside
  // the 5 meter warning radius.

  if (
    distance <=
    WARNING_RADIUS_METERS
  ) {
    // Critical risk when the vehicle
    // is very close and moving.

    if (
      nearbySpeed >= 3
    ) {
      risk =
        "CRITICAL";
    }

    // If the vehicle is stationary but
    // within 5 meters, still treat it
    // as an immediate proximity risk.

    else {
      risk =
        "EARLY";
    }
  }

  // Braking inside the warning radius
  // increases the danger level.

  if (
    nearbyBraking &&
    distance <=
      WARNING_RADIUS_METERS &&
    risk ===
      "EARLY"
  ) {
    risk =
      "MEDIUM";
  }

  return {
    risk,

    distance:
      Number(
        distance.toFixed(
          1
        )
      ),

    ownSpeed,

    nearbySpeed,

    nearbyBraking,

    withinWarningRadius:
      distance <=
      WARNING_RADIUS_METERS,

    withinDetectionRadius:
      distance <=
      DETECTION_RADIUS_METERS,
  };
}

// =====================================================
// RISK PRIORITY
// =====================================================

function riskPriority(
  risk
) {
  switch (
    risk
  ) {
    case "CRITICAL":
      return 5;

    case "HIGH":
      return 4;

    case "MEDIUM":
      return 3;

    case "EARLY":
      return 2;

    default:
      return 0;
  }
}

// =====================================================
// FIND PRIMARY THREAT
// =====================================================

function findPrimaryThreat(
  ownVehicle,
  nearbyVehicles
) {
  let primaryThreat =
    null;

  for (
    const vehicle
    of nearbyVehicles
  ) {
    const result =
      calculateCollisionRisk(
        ownVehicle,
        vehicle
      );

    const candidate = {
      ...vehicle,

      risk:
        result.risk,

      distance:
        result.distance,

      withinWarningRadius:
        result.withinWarningRadius,

      withinDetectionRadius:
        result.withinDetectionRadius,
    };

    if (
      primaryThreat ===
      null
    ) {
      primaryThreat =
        candidate;

      continue;
    }

    const candidatePriority =
      riskPriority(
        candidate.risk
      );

    const existingPriority =
      riskPriority(
        primaryThreat.risk
      );

    // Higher risk wins.

    if (
      candidatePriority >
      existingPriority
    ) {
      primaryThreat =
        candidate;

      continue;
    }

    // If risk is equal,
    // choose the nearest vehicle.

    if (
      candidatePriority ===
        existingPriority &&
      candidate.distance <
        primaryThreat.distance
    ) {
      primaryThreat =
        candidate;
    }
  }

  return primaryThreat;
}

// =====================================================
// WARNING MESSAGE
// =====================================================

function createWarningMessage(
  vehicle
) {
  const risk =
    vehicle.risk;

  const distance =
    numberValue(
      vehicle.distance
    ).toFixed(
      1
    );

  const vehicleName =
    vehicle.name ||
    vehicle.vehicleId;

  if (
    risk ===
    "CRITICAL"
  ) {
    return (
      "Critical proximity warning. " +
      vehicleName +
      " is " +
      distance +
      " m away."
    );
  }

  if (
    risk ===
    "HIGH"
  ) {
    return (
      "High collision risk detected. " +
      vehicleName +
      " is " +
      distance +
      " m away."
    );
  }

  if (
    risk ===
    "MEDIUM"
  ) {
    return (
      "Collision risk detected. " +
      vehicleName +
      " requires attention."
    );
  }

  if (
    risk ===
    "EARLY"
  ) {
    return (
      "Vehicle inside 5 meter warning radius: " +
      vehicleName +
      " is " +
      distance +
      " m away."
    );
  }

  return (
    "No immediate collision risk"
  );
}
// =====================================================
// LIVE MAP DATA
// =====================================================

function buildLiveMapData(
  receiverVehicle = null
) {
  const mapVehicles =
    [];

  for (
    const vehicle
    of vehicles.values()
  ) {
    // Do not show stale / offline real
    // vehicles on the active live map.

    if (
      !isVehicleAvailableForDetection(
        vehicle
      )
    ) {
      continue;
    }

    let distanceFromReceiver =
      null;

    let withinDetectionRadius =
      false;

    let withinWarningRadius =
      false;

    if (
      receiverVehicle &&
      vehicle.vehicleId !==
        receiverVehicle.vehicleId
    ) {
      distanceFromReceiver =
        calculateDistanceMeters(
          receiverVehicle.latitude,
          receiverVehicle.longitude,
          vehicle.latitude,
          vehicle.longitude
        );

      withinDetectionRadius =
        distanceFromReceiver <=
        DETECTION_RADIUS_METERS;

      withinWarningRadius =
        distanceFromReceiver <=
        WARNING_RADIUS_METERS;
    }

    mapVehicles.push({
      ...buildVehicleGpsData(
        vehicle
      ),

      isCurrentVehicle:
        receiverVehicle
          ? vehicle.vehicleId ===
            receiverVehicle.vehicleId
          : false,

      distanceFromCurrentVehicle:
        distanceFromReceiver === null
          ? null
          : Number(
              distanceFromReceiver.toFixed(
                1
              )
            ),

      withinDetectionRadius,

      withinWarningRadius,
    });
  }

  return mapVehicles;
}

// =====================================================
// SEND VEHICLE DATA
// =====================================================

function broadcastVehicleData() {
  const allVehicles =
    Array.from(
      vehicles.values()
    );

  for (
    const ownVehicle
    of allVehicles
  ) {
    // Only send private vehicle intelligence
    // to connected real vehicles.

    if (
      !ownVehicle.socketId
    ) {
      continue;
    }

    // Skip vehicles that are offline.

    if (
      !isVehicleAvailableForDetection(
        ownVehicle
      )
    ) {
      continue;
    }

    const nearbyVehicles =
      buildNearbyVehicleData(
        ownVehicle
      );

    const trafficDensity =
      calculateTrafficDensity(
        nearbyVehicles
      );

    // -----------------------------------------------
    // NEARBY VEHICLES EVENT
    // -----------------------------------------------

    io.to(
      ownVehicle.socketId
    ).emit(
      "nearbyVehicles",
      {
        radius:
          DETECTION_RADIUS_METERS,

        detectionRadius:
          DETECTION_RADIUS_METERS,

        warningRadius:
          WARNING_RADIUS_METERS,

        vehicleCount:
          nearbyVehicles.length,

        vehicles:
          nearbyVehicles,

        trafficDensity,

        timestamp:
          Date.now(),
      }
    );

    // -----------------------------------------------
    // RE-ARM WARNING PAIRS
    // -----------------------------------------------

    // If two vehicles move outside the 5 meter
    // warning radius, their warning pair is removed.
    // They can trigger a new warning if they later
    // come within 5 meters again.

    for (
      const pairKey
      of activeWarningPairs
    ) {
      const pair =
        pairKey.split(
          "::"
        );

      // Only inspect warning pairs that belong
      // to the current receiver vehicle.

      if (
        pair[0] !==
          ownVehicle.vehicleId &&
        pair[1] !==
          ownVehicle.vehicleId
      ) {
        continue;
      }

      const otherVehicleId =
        pair[0] ===
          ownVehicle.vehicleId
          ? pair[1]
          : pair[0];

      const otherVehicle =
        vehicles.get(
          otherVehicleId
        );

      // Remove the pair if the other vehicle
      // no longer exists.

      if (
        !otherVehicle
      ) {
        activeWarningPairs.delete(
          pairKey
        );

        continue;
      }

      const currentDistance =
        calculateDistanceMeters(
          ownVehicle.latitude,
          ownVehicle.longitude,
          otherVehicle.latitude,
          otherVehicle.longitude
        );

      // Re-arm warning after vehicles separate
      // beyond 5 meters.

      if (
        currentDistance >
        WARNING_RADIUS_METERS
      ) {
        activeWarningPairs.delete(
          pairKey
        );
      }
    }

    // -----------------------------------------------
    // COLLISION / WARNING EVENT
    // -----------------------------------------------

    const primaryThreat =
      findPrimaryThreat(
        ownVehicle,
        nearbyVehicles
      );

    // No vehicle inside detection radius.

    if (
      !primaryThreat
    ) {
      io.to(
        ownVehicle.socketId
      ).emit(
        "collisionWarning",
        {
          warning:
            false,

          level:
            "SAFE",

          risk:
            "SAFE",

          message:
            "No immediate collision risk",

          vehicle:
            null,

          vehicleId:
            null,

          distance:
            null,

          warningRadius:
            WARNING_RADIUS_METERS,

          detectionRadius:
            DETECTION_RADIUS_METERS,

          trafficDensity,

          timestamp:
            Date.now(),
        }
      );

      continue;
    }

    // Create a unique pair key.

    const pairKey =
      warningPairKey(
        ownVehicle.vehicleId,
        primaryThreat.vehicleId
      );

    const insideWarningRadius =
      primaryThreat.withinWarningRadius ===
      true;

    const warningAlreadyTriggered =
      activeWarningPairs.has(
        pairKey
      );

    // A warning can trigger only when:
    //
    // 1. Vehicle is within 5 meters.
    // 2. This vehicle pair has not already
    //    received a warning during the current
    //    close encounter.

    const shouldTriggerWarning =
      insideWarningRadius &&
      !warningAlreadyTriggered;

    // Store the pair immediately when the
    // first warning is triggered.

    if (
      shouldTriggerWarning
    ) {
      activeWarningPairs.add(
        pairKey
      );
    }

    io.to(
      ownVehicle.socketId
    ).emit(
      "collisionWarning",
      {
        // True only ONCE while this pair remains
        // inside the 5 meter warning zone.

        warning:
          shouldTriggerWarning,

        level:
          primaryThreat.risk,

        risk:
          primaryThreat.risk,

        vehicle:
          primaryThreat,

        vehicleId:
          primaryThreat.vehicleId,

        id:
          primaryThreat.vehicleId,

        vehicleName:
          primaryThreat.name ||
          primaryThreat.vehicleId,

        distance:
          primaryThreat.distance,

        speed:
          primaryThreat.speed,

        braking:
          primaryThreat.braking ===
          true,

        withinWarningRadius:
          insideWarningRadius,

        warningRadius:
          WARNING_RADIUS_METERS,

        detectionRadius:
          DETECTION_RADIUS_METERS,

        // Lets the Flutter app know whether
        // this pair was already warned.

        warningTriggeredOnce:
          warningAlreadyTriggered,

        message:
          shouldTriggerWarning
            ? createWarningMessage(
                primaryThreat
              )
            : insideWarningRadius
            ? "Vehicle remains inside warning radius."
            : "Vehicle detected. No warning triggered.",

        trafficDensity,

        timestamp:
          Date.now(),
      }
    );
  }
}

// =====================================================
// SEND VEHICLE POSITIONS
// =====================================================

function broadcastPositions() {
  const allVehicles =
    Array.from(
      vehicles.values()
    );

  for (
    const receiver
    of allVehicles
  ) {
    // Only send positions to connected
    // real vehicles.

    if (
      !receiver.socketId
    ) {
      continue;
    }

    if (
      !isVehicleAvailableForDetection(
        receiver
      )
    ) {
      continue;
    }

    for (
      const vehicle
      of allVehicles
    ) {
      // Don't send the receiver's own position
      // as another vehicle.

      if (
        vehicle.vehicleId ===
        receiver.vehicleId
      ) {
        continue;
      }

      if (
        !isVehicleAvailableForDetection(
          vehicle
        )
      ) {
        continue;
      }

      const distance =
        calculateDistanceMeters(
          receiver.latitude,
          receiver.longitude,
          vehicle.latitude,
          vehicle.longitude
        );

      io.to(
        receiver.socketId
      ).emit(
        "vehiclePosition",
        {
          ...buildVehicleGpsData(
            vehicle
          ),

          distance:
            Number(
              distance.toFixed(
                1
              )
            ),

          withinDetectionRadius:
            distance <=
            DETECTION_RADIUS_METERS,

          withinWarningRadius:
            distance <=
            WARNING_RADIUS_METERS,

          detectionRadius:
            DETECTION_RADIUS_METERS,

          warningRadius:
            WARNING_RADIUS_METERS,

          timestamp:
            Date.now(),
        }
      );
    }
  }
}

// =====================================================
// SEND LIVE MAP DATA
// =====================================================

function broadcastLiveMapData() {
  const allVehicles =
    Array.from(
      vehicles.values()
    );

  for (
    const receiver
    of allVehicles
  ) {
    // Live map data is sent only to
    // connected real devices.

    if (
      !receiver.socketId
    ) {
      continue;
    }

    if (
      !isVehicleAvailableForDetection(
        receiver
      )
    ) {
      continue;
    }

    const mapVehicles =
      buildLiveMapData(
        receiver
      );

    const nearbyVehicles =
      buildNearbyVehicleData(
        receiver
      );

    io.to(
      receiver.socketId
    ).emit(
      "liveMapData",
      {
        currentVehicleId:
          receiver.vehicleId,

        detectionRadius:
          DETECTION_RADIUS_METERS,

        warningRadius:
          WARNING_RADIUS_METERS,

        vehicleCount:
          mapVehicles.length,

        nearbyVehicleCount:
          nearbyVehicles.length,

        vehicles:
          mapVehicles,

        timestamp:
          Date.now(),
      }
    );
  }
}

// =====================================================
// UPDATE ALL CLIENTS
// =====================================================

function updateAllClients() {
  // Nearby vehicle intelligence.

  broadcastVehicleData();

  // Individual real-time vehicle updates.

  broadcastPositions();

  // Complete live map vehicle data.

  broadcastLiveMapData();
}

// =====================================================
// REMOVE VEHICLE
// =====================================================

function removeVehicle(
  vehicleId
) {
  const vehicle =
    vehicles.get(
      vehicleId
    );

  if (
    !vehicle
  ) {
    return false;
  }

  // Clear one-time warning history for
  // this vehicle before removing it.

  clearWarningPairsForVehicle(
    vehicleId
  );

  vehicles.delete(
    vehicleId
  );

  io.emit(
    "vehicleRemoved",
    {
      vehicleId,

      timestamp:
        Date.now(),
    }
  );

  // Refresh nearby vehicles and map
  // immediately after removal.

  updateAllClients();

  return true;
}
// =====================================================
// STOP SINGLE SIMULATION
// =====================================================

function stopSingleSimulation() {
  if (
    singleSimulationTimer
  ) {
    clearInterval(
      singleSimulationTimer
    );

    singleSimulationTimer =
      null;
  }

  if (
    singleSimulationVehicleId
  ) {
    removeVehicle(
      singleSimulationVehicleId
    );

    singleSimulationVehicleId =
      null;
  }

  simulationActive =
    trafficSimulationTimer !==
    null;
}

// =====================================================
// STOP TRAFFIC SIMULATION
// =====================================================

function stopTrafficSimulation() {
  if (
    trafficSimulationTimer
  ) {
    clearInterval(
      trafficSimulationTimer
    );

    trafficSimulationTimer =
      null;
  }

  for (
    const vehicleId
    of trafficSimulationIds
  ) {
    removeVehicle(
      vehicleId
    );
  }

  trafficSimulationIds =
    [];

  simulationActive =
    singleSimulationTimer !==
    null;
}

// =====================================================
// STOP ALL SIMULATIONS
// =====================================================

function stopAllSimulations() {
  stopSingleSimulation();

  stopTrafficSimulation();

  simulationActive =
    false;

  updateAllClients();
}

// =====================================================
// START SINGLE SIMULATION
// =====================================================

function startSingleSimulation() {
  stopSingleSimulation();

  const realVehicles =
    Array.from(
      vehicles.values()
    ).filter(
      (vehicle) =>
        !vehicle.simulated
    );

  if (
    realVehicles.length ===
    0
  ) {
    throw new Error(
      "Connect the Flutter vehicle before starting simulation."
    );
  }

  const targetVehicle =
    realVehicles[0];

  const simulatedVehicleId =
    "BIKE002";

  singleSimulationVehicleId =
    simulatedVehicleId;

  const simulatedVehicle = {
    vehicleId:
      simulatedVehicleId,

    id:
      simulatedVehicleId,

    name:
      "Simulated Bike",

    type:
      "motorcycle",

    status:
      "ACTIVE",

    latitude:
      targetVehicle.latitude +
      0.00012,

    longitude:
      targetVehicle.longitude,

    speed:
      35,

    direction:
      180,

    braking:
      false,

    gpsAccuracy:
      3,

    gpsTimestamp:
      Date.now(),

    lastUpdate:
      Date.now(),

    simulated:
      true,

    socketId:
      null,
  };

  vehicles.set(
    simulatedVehicleId,
    simulatedVehicle
  );

  let step =
    0;

  singleSimulationTimer =
    setInterval(
      () => {
        const vehicle =
          vehicles.get(
            simulatedVehicleId
          );

        const target =
          vehicles.get(
            targetVehicle.vehicleId
          );

        if (
          !vehicle ||
          !target
        ) {
          stopSingleSimulation();

          return;
        }

        step++;

        // Move the simulated vehicle
        // gradually toward the real vehicle.

        vehicle.latitude =
          vehicle.latitude -
          0.000006;

        if (
          step < 20
        ) {
          vehicle.speed =
            20;

          vehicle.braking =
            false;
        } else if (
          step < 35
        ) {
          vehicle.speed =
            35;

          vehicle.braking =
            false;
        } else if (
          step < 45
        ) {
          vehicle.speed =
            45;

          vehicle.braking =
            false;
        } else {
          vehicle.speed =
            50;

          vehicle.braking =
            step % 8 ===
            0;
        }

        vehicle.gpsTimestamp =
          Date.now();

        vehicle.lastUpdate =
          Date.now();

        vehicles.set(
          simulatedVehicleId,
          vehicle
        );

        updateAllClients();
      },
      1000
    );

  simulationActive =
    true;

  updateAllClients();

  return {
    success:
      true,

    message:
      "Nearby vehicle simulation started.",

    vehicleId:
      simulatedVehicleId,
  };
}

// =====================================================
// CREATE TRAFFIC VEHICLE
// =====================================================

function createTrafficVehicle(
  targetVehicle,
  index,
  total
) {
  const angle =
    (
      index /
      total
    ) *
    Math.PI *
    2;

  const radius =
    0.00008 +
    Math.random() *
      0.00035;

  const latitudeOffset =
    Math.cos(
      angle
    ) *
    radius;

  const longitudeOffset =
    Math.sin(
      angle
    ) *
    radius;

  const vehicleId =
    `SIM_TRAFFIC_${index + 1}`;

  return {
    vehicleId,

    id:
      vehicleId,

    name:
      `Traffic Vehicle ${index + 1}`,

    type:
      "car",

    status:
      "ACTIVE",

    latitude:
      targetVehicle.latitude +
      latitudeOffset,

    longitude:
      targetVehicle.longitude +
      longitudeOffset,

    speed:
      8 +
      Math.random() *
        30,

    direction:
      Math.random() *
      360,

    braking:
      false,

    gpsAccuracy:
      5,

    gpsTimestamp:
      Date.now(),

    lastUpdate:
      Date.now(),

    simulated:
      true,

    socketId:
      null,
  };
}

// =====================================================
// START TRAFFIC SIMULATION
// =====================================================

function startTrafficSimulation(
  requestedCount
) {
  stopTrafficSimulation();

  const realVehicles =
    Array.from(
      vehicles.values()
    ).filter(
      (vehicle) =>
        !vehicle.simulated
    );

  if (
    realVehicles.length ===
    0
  ) {
    throw new Error(
      "Connect the Flutter vehicle before starting traffic simulation."
    );
  }

  const targetVehicle =
    realVehicles[0];

  let count =
    Number(
      requestedCount
    );

  if (
    !Number.isFinite(
      count
    )
  ) {
    count =
      5;
  }

  count =
    Math.max(
      1,
      Math.min(
        20,
        Math.round(
          count
        )
      )
    );

  for (
    let index =
      0;

    index <
    count;

    index++
  ) {
    const vehicle =
      createTrafficVehicle(
        targetVehicle,
        index,
        count
      );

    vehicles.set(
      vehicle.vehicleId,
      vehicle
    );

    trafficSimulationIds.push(
      vehicle.vehicleId
    );
  }

  trafficSimulationTimer =
    setInterval(
      () => {
        for (
          const vehicleId
          of trafficSimulationIds
        ) {
          const vehicle =
            vehicles.get(
              vehicleId
            );

          if (
            !vehicle
          ) {
            continue;
          }

          const movement =
            vehicle.speed *
            0.00000015;

          const radians =
            (
              vehicle.direction *
              Math.PI
            ) /
            180;

          vehicle.latitude +=
            Math.cos(
              radians
            ) *
            movement;

          vehicle.longitude +=
            Math.sin(
              radians
            ) *
            movement;

          if (
            Math.random() <
            0.08
          ) {
            vehicle.braking =
              true;

            vehicle.speed =
              Math.max(
                0,
                vehicle.speed -
                  8
              );
          } else {
            vehicle.braking =
              false;

            vehicle.speed =
              Math.max(
                3,
                Math.min(
                  45,
                  vehicle.speed +
                    (
                      Math.random() -
                      0.5
                    ) *
                      4
                )
              );
          }

          vehicle.gpsTimestamp =
            Date.now();

          vehicle.lastUpdate =
            Date.now();

          vehicles.set(
            vehicleId,
            vehicle
          );
        }

        updateAllClients();
      },
      1000
    );

  simulationActive =
    true;

  updateAllClients();

  return {
    success:
      true,

    message:
      `Traffic simulation started with ${count} vehicles.`,

    count,
  };
}
// =====================================================
// SERVER STATUS API
// =====================================================

app.get(
  "/status",
  (
    _request,
    response
  ) => {
    const vehicleList =
      Array.from(
        vehicles.values()
      );

    const activeVehicles =
      vehicleList.filter(
        (
          vehicle
        ) =>
          isVehicleAvailableForDetection(
            vehicle
          )
      );

    const simulatedVehicles =
      vehicleList.filter(
        (
          vehicle
        ) =>
          vehicle.simulated ===
          true
      );

    response.json({
      success:
        true,

      project:
        "SMART V2V COMMUNICATION",

      status:
        "RUNNING",

      totalVehicles:
        vehicleList.length,

      activeVehicles:
        activeVehicles.length,

      simulatedVehicles:
        simulatedVehicles.length,

      simulationActive,

      detectionRadius:
        DETECTION_RADIUS_METERS,

      warningRadius:
        WARNING_RADIUS_METERS,

      timestamp:
        Date.now(),
    });
  }
);

// =====================================================
// GET ALL VEHICLES
// =====================================================

app.get(
  "/vehicles",
  requireHttpAuth,
  (
    _request,
    response
  ) => {
    const vehicleList =
      Array.from(
        vehicles.values()
      )
        .filter(
          (
            vehicle
          ) =>
            isVehicleAvailableForDetection(
              vehicle
            )
        )
        .map(
          (
            vehicle
          ) =>
            buildVehicleGpsData(
              vehicle
            )
        );

    response.json({
      success:
        true,

      vehicleCount:
        vehicleList.length,

      detectionRadius:
        DETECTION_RADIUS_METERS,

      warningRadius:
        WARNING_RADIUS_METERS,

      vehicles:
        vehicleList,

      timestamp:
        Date.now(),
    });
  }
);

// =====================================================
// GET LIVE MAP DATA
// =====================================================

app.get(
  "/live-map",
  requireHttpAuth,
  (
    request,
    response
  ) => {
    const vehicleId =
      String(
        request.query
          .vehicleId ||
        ""
      ).trim();

    let receiverVehicle =
      null;

    if (
      vehicleId
    ) {
      receiverVehicle =
        vehicles.get(
          vehicleId
        ) ||
        null;
    }

    const mapVehicles =
      buildLiveMapData(
        receiverVehicle
      );

    response.json({
      success:
        true,

      currentVehicleId:
        receiverVehicle
          ? receiverVehicle.vehicleId
          : null,

      detectionRadius:
        DETECTION_RADIUS_METERS,

      warningRadius:
        WARNING_RADIUS_METERS,

      vehicleCount:
        mapVehicles.length,

      vehicles:
        mapVehicles,

      timestamp:
        Date.now(),
    });
  }
);

// =====================================================
// START SINGLE VEHICLE SIMULATION API
// =====================================================

app.post(
  "/simulation/start",
  requireHttpAuth,
  (
    _request,
    response
  ) => {
    try {
      const result =
        startSingleSimulation();

      response.json(
        result
      );
    } catch (
      error
    ) {
      response
        .status(400)
        .json({
          success:
            false,

          message:
            error.message,
        });
    }
  }
);

// =====================================================
// STOP SINGLE VEHICLE SIMULATION API
// =====================================================

app.post(
  "/simulation/stop",
  requireHttpAuth,
  (
    _request,
    response
  ) => {
    stopSingleSimulation();

    response.json({
      success:
        true,

      message:
        "Nearby vehicle simulation stopped.",
    });
  }
);

// =====================================================
// START TRAFFIC SIMULATION API
// =====================================================

app.post(
  "/traffic/start",
  requireHttpAuth,
  (
    request,
    response
  ) => {
    try {
      const count =
        request.body
          ?.count;

      const result =
        startTrafficSimulation(
          count
        );

      response.json(
        result
      );
    } catch (
      error
    ) {
      response
        .status(400)
        .json({
          success:
            false,

          message:
            error.message,
        });
    }
  }
);

// =====================================================
// STOP TRAFFIC SIMULATION API
// =====================================================

app.post(
  "/traffic/stop",
  requireHttpAuth,
  (
    _request,
    response
  ) => {
    stopTrafficSimulation();

    response.json({
      success:
        true,

      message:
        "Traffic simulation stopped.",
    });
  }
);

// =====================================================
// STOP ALL SIMULATIONS API
// =====================================================

app.post(
  "/simulation/stop-all",
  requireHttpAuth,
  (
    _request,
    response
  ) => {
    stopAllSimulations();

    response.json({
      success:
        true,

      message:
        "All simulations stopped.",
    });
  }
);

// =====================================================
// DELETE VEHICLE API
// =====================================================

app.delete(
  "/vehicles/:vehicleId",
  requireHttpAuth,
  (
    request,
    response
  ) => {
    const vehicleId =
      String(
        request.params
          .vehicleId ||
        ""
      ).trim();

    if (
      !vehicleId
    ) {
      return response
        .status(400)
        .json({
          success:
            false,

          message:
            "Vehicle ID is required.",
        });
    }

    const removed =
      removeVehicle(
        vehicleId
      );

    if (
      !removed
    ) {
      return response
        .status(404)
        .json({
          success:
            false,

          message:
            "Vehicle not found.",
        });
    }

    response.json({
      success:
        true,

      message:
        "Vehicle removed successfully.",

      vehicleId,
    });
  }
);

// =====================================================
// SOCKET CONNECTION
// =====================================================

io.on(
  "connection",
  (
    socket
  ) => {
    console.log(
      "VEHICLE SOCKET CONNECTED:",
      socket.id
    );

    // -----------------------------------------------
    // VEHICLE REGISTER
    // -----------------------------------------------

    socket.on(
      "registerVehicle",
      (
        rawData = {},
        acknowledgement
      ) => {
        try {
          const vehicleId =
            String(
              rawData.vehicleId ||
              rawData.id ||
              ""
            ).trim();

          const latitude =
            numberValue(
              rawData.latitude,
              NaN
            );

          const longitude =
            numberValue(
              rawData.longitude,
              NaN
            );

          if (
            !vehicleId
          ) {
            throw new Error(
              "Vehicle ID is required."
            );
          }

          if (
            !isValidCoordinate(
              latitude,
              longitude
            )
          ) {
            throw new Error(
              "Valid latitude and longitude are required."
            );
          }

          // If this ID was previously connected
          // on another socket, clear the old
          // warning state before updating.

          clearWarningPairsForVehicle(
            vehicleId
          );

          const vehicle = {
            vehicleId,

            id:
              vehicleId,

            name:
              String(
                rawData.name ||
                rawData.vehicleName ||
                vehicleId
              ).trim(),

            type:
              String(
                rawData.type ||
                rawData.vehicleType ||
                "vehicle"
              ).trim(),

            status:
              normalizeVehicleStatus(
                rawData.status
              ),

            latitude,

            longitude,

            speed:
              numberValue(
                rawData.speed
              ),

            direction:
              numberValue(
                rawData.direction
              ),

            braking:
              rawData.braking ===
              true,

            gpsAccuracy:
              numberValue(
                rawData.gpsAccuracy,
                0
              ),

            gpsTimestamp:
              numberValue(
                rawData.gpsTimestamp,
                Date.now()
              ),

            lastUpdate:
              Date.now(),

            simulated:
              false,

            socketId:
              socket.id,
          };

          vehicles.set(
            vehicleId,
            vehicle
          );

          socket.data.vehicleId =
            vehicleId;

          console.log(
            "VEHICLE REGISTERED:",
            vehicleId,
            vehicle.name,
            vehicle.latitude,
            vehicle.longitude
          );

          const responseData = {
            success:
              true,

            message:
              "Vehicle registered successfully.",

            vehicle:
              buildVehicleGpsData(
                vehicle
              ),

            detectionRadius:
              DETECTION_RADIUS_METERS,

            warningRadius:
              WARNING_RADIUS_METERS,

            timestamp:
              Date.now(),
          };

          socket.emit(
            "vehicleRegistered",
            responseData
          );

          if (
            typeof acknowledgement ===
            "function"
          ) {
            acknowledgement(
              responseData
            );
          }

          updateAllClients();
        } catch (
          error
        ) {
          const errorData = {
            success:
              false,

            message:
              error.message,
          };

          socket.emit(
            "vehicleRegistrationError",
            errorData
          );

          if (
            typeof acknowledgement ===
            "function"
          ) {
            acknowledgement(
              errorData
            );
          }
        }
      }
    );
        // -----------------------------------------------
    // LIVE GPS / VEHICLE UPDATE
    // -----------------------------------------------

    socket.on(
      "updateVehicle",
      (
        rawData = {},
        acknowledgement
      ) => {
        try {
          const vehicleId =
            String(
              rawData.vehicleId ||
              rawData.id ||
              socket.data.vehicleId ||
              ""
            ).trim();

          if (
            !vehicleId
          ) {
            throw new Error(
              "Vehicle is not registered."
            );
          }

          const existingVehicle =
            vehicles.get(
              vehicleId
            );

          if (
            !existingVehicle
          ) {
            throw new Error(
              "Vehicle not found. Register first."
            );
          }

          const latitude =
            rawData.latitude !==
            undefined
              ? numberValue(
                  rawData.latitude,
                  NaN
                )
              : existingVehicle.latitude;

          const longitude =
            rawData.longitude !==
            undefined
              ? numberValue(
                  rawData.longitude,
                  NaN
                )
              : existingVehicle.longitude;

          if (
            !isValidCoordinate(
              latitude,
              longitude
            )
          ) {
            throw new Error(
              "Valid latitude and longitude are required."
            );
          }

          const updatedVehicle = {
            ...existingVehicle,

            socketId:
              socket.id,

            latitude,

            longitude,

            speed:
              rawData.speed !==
              undefined
                ? numberValue(
                    rawData.speed
                  )
                : existingVehicle.speed,

            direction:
              rawData.direction !==
              undefined
                ? numberValue(
                    rawData.direction
                  )
                : existingVehicle.direction,

            braking:
              rawData.braking !==
              undefined
                ? rawData.braking ===
                  true
                : existingVehicle.braking,

            gpsAccuracy:
              rawData.gpsAccuracy !==
              undefined
                ? numberValue(
                    rawData.gpsAccuracy,
                    existingVehicle.gpsAccuracy
                  )
                : existingVehicle.gpsAccuracy,

            gpsTimestamp:
              rawData.gpsTimestamp !==
              undefined
                ? numberValue(
                    rawData.gpsTimestamp,
                    Date.now()
                  )
                : Date.now(),

            status:
              rawData.status !==
              undefined
                ? normalizeVehicleStatus(
                    rawData.status
                  )
                : existingVehicle.status,

            lastUpdate:
              Date.now(),
          };

          // Optional vehicle name update.

          if (
            rawData.name !==
              undefined ||
            rawData.vehicleName !==
              undefined
          ) {
            updatedVehicle.name =
              String(
                rawData.name ||
                rawData.vehicleName ||
                existingVehicle.name
              ).trim();
          }

          // Optional vehicle type update.

          if (
            rawData.type !==
              undefined ||
            rawData.vehicleType !==
              undefined
          ) {
            updatedVehicle.type =
              String(
                rawData.type ||
                rawData.vehicleType ||
                existingVehicle.type
              ).trim();
          }

          vehicles.set(
            vehicleId,
            updatedVehicle
          );

          socket.data.vehicleId =
            vehicleId;

          const responseData = {
            success:
              true,

            vehicle:
              buildVehicleGpsData(
                updatedVehicle
              ),

            detectionRadius:
              DETECTION_RADIUS_METERS,

            warningRadius:
              WARNING_RADIUS_METERS,

            timestamp:
              Date.now(),
          };

          socket.emit(
            "vehicleUpdated",
            responseData
          );

          if (
            typeof acknowledgement ===
            "function"
          ) {
            acknowledgement(
              responseData
            );
          }

          // Immediately refresh nearby vehicle,
          // warning, and live map data.

          updateAllClients();
        } catch (
          error
        ) {
          const errorData = {
            success:
              false,

            message:
              error.message,
          };

          socket.emit(
            "vehicleUpdateError",
            errorData
          );

          if (
            typeof acknowledgement ===
            "function"
          ) {
            acknowledgement(
              errorData
            );
          }
        }
      }
    );

    // -----------------------------------------------
    // UPDATE VEHICLE STATUS
    // -----------------------------------------------

    socket.on(
      "updateVehicleStatus",
      (
        rawData = {},
        acknowledgement
      ) => {
        try {
          const vehicleId =
            String(
              rawData.vehicleId ||
              rawData.id ||
              socket.data.vehicleId ||
              ""
            ).trim();

          if (
            !vehicleId
          ) {
            throw new Error(
              "Vehicle is not registered."
            );
          }

          const vehicle =
            vehicles.get(
              vehicleId
            );

          if (
            !vehicle
          ) {
            throw new Error(
              "Vehicle not found."
            );
          }

          vehicle.status =
            normalizeVehicleStatus(
              rawData.status
            );

          vehicle.lastUpdate =
            Date.now();

          vehicle.socketId =
            socket.id;

          vehicles.set(
            vehicleId,
            vehicle
          );

          const responseData = {
            success:
              true,

            vehicleId,

            status:
              vehicle.status,

            timestamp:
              Date.now(),
          };

          socket.emit(
            "vehicleStatusUpdated",
            responseData
          );

          if (
            typeof acknowledgement ===
            "function"
          ) {
            acknowledgement(
              responseData
            );
          }

          updateAllClients();
        } catch (
          error
        ) {
          const errorData = {
            success:
              false,

            message:
              error.message,
          };

          socket.emit(
            "vehicleStatusError",
            errorData
          );

          if (
            typeof acknowledgement ===
            "function"
          ) {
            acknowledgement(
              errorData
            );
          }
        }
      }
    );

    // -----------------------------------------------
    // REQUEST LIVE MAP DATA
    // -----------------------------------------------

    socket.on(
      "requestLiveMapData",
      (
        _rawData = {},
        acknowledgement
      ) => {
        const vehicleId =
          socket.data.vehicleId;

        const receiverVehicle =
          vehicleId
            ? vehicles.get(
                vehicleId
              )
            : null;

        const mapVehicles =
          buildLiveMapData(
            receiverVehicle
          );

        const responseData = {
          currentVehicleId:
            receiverVehicle
              ? receiverVehicle.vehicleId
              : null,

          detectionRadius:
            DETECTION_RADIUS_METERS,

          warningRadius:
            WARNING_RADIUS_METERS,

          vehicleCount:
            mapVehicles.length,

          vehicles:
            mapVehicles,

          timestamp:
            Date.now(),
        };

        socket.emit(
          "liveMapData",
          responseData
        );

        if (
          typeof acknowledgement ===
          "function"
        ) {
          acknowledgement(
            responseData
          );
        }
      }
    );

    // -----------------------------------------------
    // REQUEST NEARBY VEHICLES
    // -----------------------------------------------

    socket.on(
      "requestNearbyVehicles",
      (
        _rawData = {},
        acknowledgement
      ) => {
        const vehicleId =
          socket.data.vehicleId;

        const ownVehicle =
          vehicleId
            ? vehicles.get(
                vehicleId
              )
            : null;

        if (
          !ownVehicle
        ) {
          const errorData = {
            success:
              false,

            message:
              "Vehicle not registered.",
          };

          socket.emit(
            "nearbyVehicles",
            {
              radius:
                DETECTION_RADIUS_METERS,

              detectionRadius:
                DETECTION_RADIUS_METERS,

              warningRadius:
                WARNING_RADIUS_METERS,

              vehicleCount:
                0,

              vehicles:
                [],

              timestamp:
                Date.now(),
            }
          );

          if (
            typeof acknowledgement ===
            "function"
          ) {
            acknowledgement(
              errorData
            );
          }

          return;
        }

        const nearbyVehicles =
          buildNearbyVehicleData(
            ownVehicle
          );

        const trafficDensity =
          calculateTrafficDensity(
            nearbyVehicles
          );

        const responseData = {
          success:
            true,

          radius:
            DETECTION_RADIUS_METERS,

          detectionRadius:
            DETECTION_RADIUS_METERS,

          warningRadius:
            WARNING_RADIUS_METERS,

          vehicleCount:
            nearbyVehicles.length,

          vehicles:
            nearbyVehicles,

          trafficDensity,

          timestamp:
            Date.now(),
        };

        socket.emit(
          "nearbyVehicles",
          responseData
        );

        if (
          typeof acknowledgement ===
          "function"
        ) {
          acknowledgement(
            responseData
          );
        }
      }
    );

    // -----------------------------------------------
    // DISCONNECT
    // -----------------------------------------------

    socket.on(
      "disconnect",
      (
        reason
      ) => {
        const vehicleId =
          socket.data.vehicleId;

        console.log(
          "VEHICLE SOCKET DISCONNECTED:",
          socket.id,
          "REASON:",
          reason
        );

        if (
          vehicleId
        ) {
          const vehicle =
            vehicles.get(
              vehicleId
            );

          // Remove the vehicle only if this socket
          // is still the active socket for that ID.

          if (
            vehicle &&
            vehicle.socketId ===
              socket.id
          ) {
            // Clear all one-time warning pairs
            // involving this vehicle.

            clearWarningPairsForVehicle(
              vehicleId
            );

            vehicles.delete(
              vehicleId
            );

            io.emit(
              "vehicleRemoved",
              {
                vehicleId,

                timestamp:
                  Date.now(),
              }
            );

            updateAllClients();
          }
        }
      }
    );
  }
);
// =====================================================
// PERIODIC VEHICLE CLEANUP
// =====================================================

// Check for stale vehicles periodically.
//
// Simulated vehicles are kept active because they
// update themselves. Real vehicles that stop sending
// GPS data are marked OFFLINE by getVehicleStatus().
//
// This periodic update refreshes all connected clients
// so offline vehicles disappear from nearby detection
// and live map data.

setInterval(
  () => {
    updateAllClients();
  },
  3000
);

// =====================================================
// SERVER START
// =====================================================

server.listen(
  PORT,
  () => {
    console.log(
      "========================================"
    );

    console.log(
      "SMART V2V BACKEND RUNNING"
    );

    console.log(
      `PORT: ${PORT}`
    );

    console.log(
      `DETECTION RADIUS: ${DETECTION_RADIUS_METERS} meters`
    );

    console.log(
      `WARNING RADIUS: ${WARNING_RADIUS_METERS} meters`
    );

    console.log(
      `AUTHENTICATION: ${
        V2V_SHARED_SECRET
          ? "ENABLED"
          : "DISABLED"
      }`
    );

    console.log(
      "========================================"
    );
  }
);

// =====================================================
// GRACEFUL SHUTDOWN
// =====================================================

function gracefulShutdown(
  signal
) {
  console.log(
    `Received ${signal}. Shutting down V2V server...`
  );

  // Stop all running simulation timers.

  if (
    singleSimulationTimer
  ) {
    clearInterval(
      singleSimulationTimer
    );

    singleSimulationTimer =
      null;
  }

  if (
    trafficSimulationTimer
  ) {
    clearInterval(
      trafficSimulationTimer
    );

    trafficSimulationTimer =
      null;
  }

  // Clear simulation state.

  trafficSimulationIds =
    [];

  singleSimulationVehicleId =
    null;

  simulationActive =
    false;

  // Clear warning tracking.

  activeWarningPairs.clear();

  // Close Socket.IO first.

  io.close(
    () => {
      console.log(
        "Socket.IO closed."
      );

      // Then close HTTP server.

      server.close(
        () => {
          console.log(
            "HTTP server closed."
          );

          process.exit(
            0
          );
        }
      );
    }
  );

  // Force exit if graceful shutdown takes
  // too long.

  setTimeout(
    () => {
      console.error(
        "Forced server shutdown."
      );

      process.exit(
        1
      );
    },
    10000
  ).unref();
}

process.on(
  "SIGTERM",
  () =>
    gracefulShutdown(
      "SIGTERM"
    )
);

process.on(
  "SIGINT",
  () =>
    gracefulShutdown(
      "SIGINT"
    )
);
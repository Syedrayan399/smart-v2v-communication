const express = require("express");
const http = require("http");
const { Server } = require("socket.io");

const app = express();
const server = http.createServer(app);

// =====================================================
// CONFIGURATION
// =====================================================

const PORT = Number(process.env.PORT || 3000);

// IMPORTANT:
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
  (process.env.V2V_SHARED_SECRET || "").trim();

// Maximum distance for showing another vehicle
// in the Nearby Vehicles section.
const DETECTION_RADIUS_METERS = 100;

// Distance used for warning / danger detection.
const WARNING_RADIUS_METERS = 5;

// A vehicle is considered stale when it has not
// sent a GPS update within this time.
const VEHICLE_STALE_AFTER_MS = 15000;

const appCorsHeaders = {
  "Access-Control-Allow-Origin": "*",
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

app.use((request, response, next) => {
  response.set(appCorsHeaders);

  if (request.method === "OPTIONS") {
    return response.sendStatus(204);
  }

  next();
});

// =====================================================
// SOCKET.IO
// =====================================================

const io = new Server(server, {
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

  pingInterval: 10000,

  pingTimeout: 30000,

  allowEIO3: true,
});

// =====================================================
// VEHICLE STORAGE
// =====================================================

// Stores all connected and simulated vehicles.
const vehicles = new Map();

let singleSimulationTimer = null;

let trafficSimulationTimer = null;

let singleSimulationVehicleId = null;

let trafficSimulationIds = [];

let simulationActive = false;

// =====================================================
// ROOT
// =====================================================

app.get("/", (_request, response) => {
  response.json({
    project: "SMART V2V COMMUNICATION",

    status: "Backend Running",

    service: "V2V Socket.IO",

    detectionRadius:
      DETECTION_RADIUS_METERS,

    warningRadius:
      WARNING_RADIUS_METERS,
  });
});

// =====================================================
// HTTP AUTH
// =====================================================

function getHttpToken(request) {
  const customToken =
    request.headers["x-v2v-token"];

  if (
    typeof customToken === "string" &&
    customToken.trim()
  ) {
    return customToken.trim();
  }

  const authorization =
    request.headers.authorization;

  if (
    typeof authorization === "string" &&
    authorization.startsWith("Bearer ")
  ) {
    return authorization
      .substring("Bearer ".length)
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

  if (!V2V_SHARED_SECRET) {
    return next();
  }

  const token =
    getHttpToken(request);

  if (
    token !==
    V2V_SHARED_SECRET
  ) {
    return response.status(401).json({
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

io.use((socket, next) => {
  // Authentication is optional.

  if (!V2V_SHARED_SECRET) {
    return next();
  }

  const queryToken =
    socket.handshake.query?.token;

  const authToken =
    socket.handshake.auth?.token;

  const token =
    typeof authToken === "string" &&
    authToken.trim()
      ? authToken.trim()
      : typeof queryToken === "string"
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
      new Error("unauthorized")
    );
  }

  next();
});

// =====================================================
// NUMBER HELPER
// =====================================================

function numberValue(
  value,
  fallback = 0
) {
  const parsed =
    Number(value);

  return Number.isFinite(parsed)
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
      status || "ACTIVE"
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

  if (!lastUpdate) {
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
    isVehicleStale(vehicle)
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
  if (!vehicle) {
    return false;
  }

  if (vehicle.simulated) {
    return true;
  }

  const status =
    getVehicleStatus(vehicle);

  return (
    status !== "OFFLINE"
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
    Number.isFinite(latitude) &&
    Number.isFinite(longitude) &&
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
    (value) =>
      (value * Math.PI) /
      180;

  const latitudeDifference =
    toRadians(
      lat2 - lat1
    );

  const longitudeDifference =
    toRadians(
      lon2 - lon1
    );

  const a =
    Math.sin(
      latitudeDifference / 2
    ) **
      2 +
    Math.cos(
      toRadians(lat1)
    ) *
      Math.cos(
        toRadians(lat2)
      ) *
      Math.sin(
        longitudeDifference / 2
      ) **
        2;

  const c =
    2 *
    Math.atan2(
      Math.sqrt(a),
      Math.sqrt(1 - a)
    );

  return (
    earthRadius * c
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
      getVehicleStatus(vehicle),

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
      isVehicleStale(vehicle),

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

  let averageSpeed = 0;

  if (count > 0) {
    const totalSpeed =
      vehicleList.reduce(
        (total, vehicle) =>
          total +
          numberValue(
            vehicle.speed
          ),
        0
      );

    averageSpeed =
      totalSpeed / count;
  }

  let density = "LIGHT";

  let congestion =
    false;

  if (count < 10) {
    density = "LIGHT";
  } else if (count < 15) {
    density = "MODERATE";

    congestion =
      averageSpeed < 15;
  } else {
    density = "HEAVY";

    congestion =
      true;
  }

  return {
    density,

    vehicleCount:
      count,

    averageSpeed:
      Number(
        averageSpeed.toFixed(1)
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
  const nearbyVehicles = [];

  // Do not calculate nearby vehicles for
  // an offline / stale real vehicle.
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
    // the detection radius.
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
          distance.toFixed(1)
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
    (first, second) =>
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

  // Critical risk.
  if (
    distance <= 5 &&
    nearbySpeed >= 3
  ) {
    risk =
      "CRITICAL";
  }

  // High risk.
  else if (
    distance <= 15 &&
    nearbySpeed >= 3
  ) {
    risk =
      "HIGH";
  }

  // Medium risk.
  else if (
    distance <= 30 &&
    speedDifference >= 8
  ) {
    risk =
      "MEDIUM";
  }

  // Vehicle is inside warning radius.
  else if (
    distance <=
    WARNING_RADIUS_METERS
  ) {
    risk =
      "EARLY";
  }

  // Braking vehicle near the user.
  if (
    nearbyBraking &&
    distance <=
      WARNING_RADIUS_METERS &&
    risk === "EARLY"
  ) {
    risk =
      "MEDIUM";
  }

  return {
    risk,

    distance:
      Number(
        distance.toFixed(1)
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
  switch (risk) {
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

    // Higher risk always wins.
    if (
      candidatePriority >
      existingPriority
    ) {
      primaryThreat =
        candidate;

      continue;
    }

    // If the risk level is equal,
    // select the nearest vehicle.
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
    ).toFixed(1);

  const vehicleName =
    vehicle.name ||
    vehicle.vehicleId;

  if (
    risk === "CRITICAL"
  ) {
    return (
      "Critical collision risk detected. " +
      vehicleName +
      " is " +
      distance +
      " m away."
    );
  }

  if (
    risk === "HIGH"
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
    risk === "MEDIUM"
  ) {
    return (
      "Collision risk detected. " +
      vehicleName +
      " requires attention."
    );
  }

  if (
    risk === "EARLY"
  ) {
    return (
      "Vehicle inside warning radius: " +
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
  const mapVehicles = [];

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
    // COLLISION / WARNING EVENT
    // -----------------------------------------------

    const primaryThreat =
      findPrimaryThreat(
        ownVehicle,
        nearbyVehicles
      );

    // No nearby threat.
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

    const risk =
      primaryThreat.risk;

    io.to(
      ownVehicle.socketId
    ).emit(
      "collisionWarning",
      {
        // Strong warning only for
        // HIGH and CRITICAL situations.
        warning:
          risk === "CRITICAL" ||
          risk === "HIGH",

        level:
          risk,

        risk,

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
          primaryThreat.withinWarningRadius ===
          true,

        warningRadius:
          WARNING_RADIUS_METERS,

        detectionRadius:
          DETECTION_RADIUS_METERS,

        message:
          createWarningMessage(
            primaryThreat
          ),

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
              distance.toFixed(1)
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

  if (!vehicle) {
    return false;
  }

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

  updateAllClients();
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

  trafficSimulationIds = [];

  simulationActive =
    singleSimulationTimer !==
    null;

  updateAllClients();
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
        !vehicle.simulated &&
        isVehicleAvailableForDetection(
          vehicle
        )
    );

  if (
    realVehicles.length === 0
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

  const now =
    Date.now();

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

    // Simulated GPS metadata.
    gpsAccuracy:
      3,

    gpsTimestamp:
      now,

    lastUpdate:
      now,

    simulated:
      true,

    socketId:
      null,
  };

  vehicles.set(
    simulatedVehicleId,
    simulatedVehicle
  );

  let step = 0;

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

        // Move simulated vehicle
        // toward the real vehicle.
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
            step % 8 === 0;
        }

        // Update simulated GPS metadata.
        vehicle.gpsTimestamp =
          Date.now();

        vehicle.lastUpdate =
          Date.now();

        vehicle.status =
          "ACTIVE";

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

    vehicleName:
      "Simulated Bike",

    status:
      "ACTIVE",
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
    (index / total) *
    Math.PI *
    2;

  const radius =
    0.00008 +
    Math.random() *
    0.00035;

  const latitudeOffset =
    Math.cos(angle) *
    radius;

  const longitudeOffset =
    Math.sin(angle) *
    radius;

  const vehicleId =
    `SIM_TRAFFIC_${index + 1}`;

  const now =
    Date.now();

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
      3,

    gpsTimestamp:
      now,

    lastUpdate:
      now,

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
        !vehicle.simulated &&
        isVehicleAvailableForDetection(
          vehicle
        )
    );

  if (
    realVehicles.length === 0
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
        Math.round(count)
      )
    );

  for (
    let index = 0;
    index < count;
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

          if (!vehicle) {
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

          // Keep simulated vehicle
          // GPS data fresh.
          vehicle.gpsTimestamp =
            Date.now();

          vehicle.lastUpdate =
            Date.now();

          vehicle.status =
            "ACTIVE";

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

    status:
      "ACTIVE",
  };
}
// =====================================================
// STATUS API
// =====================================================

app.get(
  "/api/status",
  requireHttpAuth,
  (_request, response) => {
    const allVehicles =
      Array.from(
        vehicles.values()
      );

    const connectedVehicles =
      allVehicles.filter(
        (vehicle) =>
          !vehicle.simulated &&
          vehicle.socketId &&
          !isVehicleStale(vehicle)
      );

    const simulatedVehicles =
      allVehicles.filter(
        (vehicle) =>
          vehicle.simulated ===
          true
      );

    response.json({
      project:
        "SMART V2V COMMUNICATION",

      status:
        "Backend Running",

      connectedVehicles:
        connectedVehicles.length,

      simulatedVehicles:
        simulatedVehicles.length,

      totalVehicles:
        allVehicles.length,

      vehicleIds:
        allVehicles.map(
          (vehicle) =>
            vehicle.vehicleId
        ),

      simulationActive,

      detectionRadius:
        DETECTION_RADIUS_METERS,

      warningRadius:
        WARNING_RADIUS_METERS,

      vehicleStaleAfter:
        VEHICLE_STALE_AFTER_MS,

      timestamp:
        Date.now(),
    });
  }
);

// =====================================================
// LIVE MAP API
// =====================================================
//
// Returns the current live GPS information
// for all active vehicles.
//
// This API can also be used by a web dashboard
// or for testing the backend.
//
// Socket.IO "liveMapData" should be used by
// Flutter for continuous real-time updates.
// =====================================================

app.get(
  "/api/live-map",
  requireHttpAuth,
  (_request, response) => {
    const allVehicles =
      Array.from(
        vehicles.values()
      );
    const activeVehicles =
      allVehicles.filter(
        (vehicle) =>
          isVehicleAvailableForDetection(
            vehicle
          )
      );

    response.json({
      success:
        true,

      detectionRadius:
        DETECTION_RADIUS_METERS,

      warningRadius:
        WARNING_RADIUS_METERS,

      vehicleCount:
        activeVehicles.length,

      vehicles:
        buildLiveMapData(),

      timestamp:
        Date.now(),
    });
  }
);

// =====================================================
// VEHICLES API
// =====================================================
//
// Returns all vehicles with complete
// live status and GPS information.
// =====================================================

app.get(
  "/api/vehicles",
  requireHttpAuth,
  (_request, response) => {
    const vehicleData =
      Array.from(
        vehicles.values()
      ).map(
        (vehicle) =>
          buildVehicleGpsData(
            vehicle
          )
      );

    response.json({
      success:
        true,

      totalVehicles:
        vehicleData.length,

      detectionRadius:
        DETECTION_RADIUS_METERS,

      warningRadius:
        WARNING_RADIUS_METERS,

      vehicles:
        vehicleData,

      timestamp:
        Date.now(),
    });
  }
);

// =====================================================
// SIMULATE SINGLE VEHICLE
// =====================================================

app.post(
  "/api/simulate-vehicle",
  requireHttpAuth,
  (_request, response) => {
    try {
      const result =
        startSingleSimulation();

      response.json(
        result
      );
    } catch (error) {
      response.status(400).json({
        success:
          false,

        message:
          error.message ||
          "Unable to start vehicle simulation.",
      });
    }
  }
);

// =====================================================
// STOP SINGLE SIMULATION
// =====================================================

app.delete(
  "/api/simulate-vehicle",
  requireHttpAuth,
  (_request, response) => {
    stopSingleSimulation();

    updateAllClients();

    response.json({
      success:
        true,

      message:
        "Nearby vehicle simulation stopped.",

      timestamp:
        Date.now(),
    });
  }
);

// =====================================================
// START TRAFFIC SIMULATION
// =====================================================

app.post(
  "/api/simulate-traffic",
  requireHttpAuth,
  (request, response) => {
    try {
      const count =
        request.body?.count ??
        5;

      const result =
        startTrafficSimulation(
          count
        );

      response.json(
        result
      );
    } catch (error) {
      response.status(400).json({
        success:
          false,

        message:
          error.message ||
          "Unable to start traffic simulation.",
      });
    }
  }
);

// =====================================================
// STOP TRAFFIC SIMULATION
// =====================================================

app.delete(
  "/api/simulate-traffic",
  requireHttpAuth,
  (_request, response) => {
    stopTrafficSimulation();

    updateAllClients();

    response.json({
      success:
        true,

      message:
        "Traffic simulation stopped.",

      timestamp:
        Date.now(),
    });
  }
);

// =====================================================
// STOP ALL SIMULATIONS
// =====================================================

app.delete(
  "/api/stop-all-simulations",
  requireHttpAuth,
  (_request, response) => {
    stopAllSimulations();

    response.json({
      success:
        true,

      message:
        "All simulations stopped.",

      timestamp:
        Date.now(),
    });
  }
);
// =====================================================
// SOCKET.IO ERROR LOGGING
// =====================================================

io.engine.on(
  "connection_error",
  (error) => {
    console.error(
      "SOCKET.IO CONNECTION ERROR:",
      {
        code:
          error.code,

        message:
          error.message,

        context:
          error.context,
      }
    );
  }
);

// =====================================================
// SOCKET CONNECTION
// =====================================================

io.on(
  "connection",
  (socket) => {
    console.log(
      "🔌 V2V CLIENT CONNECTED:",
      socket.id
    );

    // -------------------------------------------------
    // REGISTER VEHICLE
    // -------------------------------------------------

    socket.on(
      "registerVehicle",
      (data) => {
        const vehicleId =
          data?.vehicleId
            ?.toString()
            .trim();

        if (!vehicleId) {
          socket.emit(
            "registrationError",
            {
              message:
                "Missing vehicleId",
            }
          );

          return;
        }

        const latitude =
          numberValue(
            data.latitude,
            NaN
          );

        const longitude =
          numberValue(
            data.longitude,
            NaN
          );

        if (
          !isValidCoordinate(
            latitude,
            longitude
          )
        ) {
          socket.emit(
            "registrationError",
            {
              message:
                "Invalid coordinates",
            }
          );

          return;
        }

        const previousVehicle =
          vehicles.get(
            vehicleId
          );

        // If the same vehicle reconnects,
        // replace the old socket.
        if (
          previousVehicle &&
          previousVehicle.socketId &&
          previousVehicle.socketId !==
            socket.id
        ) {
          const oldSocket =
            io.sockets.sockets.get(
              previousVehicle.socketId
            );

          if (
            oldSocket &&
            oldSocket.connected
          ) {
            oldSocket.emit(
              "vehicleReplaced",
              {
                vehicleId,

                timestamp:
                  Date.now(),
              }
            );
          }
        }

        const now =
          Date.now();

        const vehicle = {
          vehicleId,

          id:
            vehicleId,

          // Vehicle name selected by user.
          name:
            data.name ||
            data.vehicleName ||
            vehicleId,

          // Vehicle type selected by user.
          type:
            data.type ||
            "vehicle",

          // ACTIVE, PARKED, STOPPED,
          // OFFLINE or EMERGENCY.
          status:
            normalizeVehicleStatus(
              data.status
            ),

          latitude,

          longitude,

          speed:
            numberValue(
              data.speed
            ),

          direction:
            numberValue(
              data.direction
            ),

          braking:
            data.braking ===
            true,

          // GPS accuracy in meters.
          gpsAccuracy:
            numberValue(
              data.gpsAccuracy,
              0
            ),

          // GPS timestamp supplied by
          // the Flutter device.
          gpsTimestamp:
            numberValue(
              data.gpsTimestamp,
              now
            ),

          socketId:
            socket.id,

          simulated:
            false,

          lastUpdate:
            now,
        };

        vehicles.set(
          vehicleId,
          vehicle
        );

        console.log(
          "✅ VEHICLE REGISTERED:",
          {
            vehicleId,
            name:
              vehicle.name,
            type:
              vehicle.type,
            status:
              vehicle.status,
            socketId:
              socket.id,
          }
        );

        socket.emit(
          "registrationSuccess",
          {
            success:
              true,

            vehicleId,

            name:
              vehicle.name,

            type:
              vehicle.type,

            status:
              getVehicleStatus(
                vehicle
              ),

            detectionRadius:
              DETECTION_RADIUS_METERS,

            warningRadius:
              WARNING_RADIUS_METERS,

            timestamp:
              now,
          }
        );

        // Immediately update all devices.
        updateAllClients();
      }
    );

    // -------------------------------------------------
    // VEHICLE UPDATE
    // -------------------------------------------------

    socket.on(
      "vehicleUpdate",
      (data) => {
        const vehicleId =
          data?.vehicleId
            ?.toString()
            .trim();

        if (!vehicleId) {
          return;
        }

        const vehicle =
          vehicles.get(
            vehicleId
          );

        if (!vehicle) {
          return;
        }

        // Prevent another socket from
        // updating someone else's vehicle.
        if (
          vehicle.socketId !==
          socket.id
        ) {
          console.warn(
            "REJECTED vehicleUpdate: socket mismatch",
            vehicleId
          );

          return;
        }

        const latitude =
          numberValue(
            data.latitude,
            vehicle.latitude
          );

        const longitude =
          numberValue(
            data.longitude,
            vehicle.longitude
          );

        if (
          !isValidCoordinate(
            latitude,
            longitude
          )
        ) {
          return;
        }

        const now =
          Date.now();

        // ---------------------------------------------
        // LIVE GPS UPDATE
        // ---------------------------------------------

        vehicle.latitude =
          latitude;

        vehicle.longitude =
          longitude;

        // ---------------------------------------------
        // VEHICLE INFORMATION UPDATE
        // ---------------------------------------------

        if (
          data.name !== undefined ||
          data.vehicleName !== undefined
        ) {
          const updatedName =
            data.name ||
            data.vehicleName;

          if (
            typeof updatedName ===
              "string" &&
            updatedName.trim()
          ) {
            vehicle.name =
              updatedName.trim();
          }
        }

        if (
          data.type !== undefined
        ) {
          const updatedType =
            String(
              data.type
            ).trim();

          if (updatedType) {
            vehicle.type =
              updatedType;
          }
        }

        if (
          data.status !== undefined
        ) {
          vehicle.status =
            normalizeVehicleStatus(
              data.status
            );
        }

        // ---------------------------------------------
        // SPEED / DIRECTION / BRAKING
        // ---------------------------------------------

        vehicle.speed =
          numberValue(
            data.speed,
            vehicle.speed
          );

        vehicle.direction =
          numberValue(
            data.direction,
            vehicle.direction
          );

        vehicle.braking =
          data.braking ===
          true;

        // ---------------------------------------------
        // GPS ACCURACY
        // ---------------------------------------------

        if (
          data.gpsAccuracy !==
          undefined
        ) {
          vehicle.gpsAccuracy =
            numberValue(
              data.gpsAccuracy,
              vehicle.gpsAccuracy
            );
        }

        // ---------------------------------------------
        // GPS TIMESTAMP
        // ---------------------------------------------

        vehicle.gpsTimestamp =
          numberValue(
            data.gpsTimestamp,
            now
          );

        // Backend update timestamp.
        vehicle.lastUpdate =
          now;

        vehicles.set(
          vehicleId,
          vehicle
        );

        // Send the new GPS data to
        // all connected vehicles.
        updateAllClients();
      }
    );

    // -------------------------------------------------
    // VEHICLE STATUS UPDATE
    // -------------------------------------------------
    //
    // Flutter can send this event when only the
    // vehicle status changes without a full GPS update.
    // -------------------------------------------------

    socket.on(
      "vehicleStatusUpdate",
      (data) => {
        const vehicleId =
          data?.vehicleId
            ?.toString()
            .trim();

        if (!vehicleId) {
          return;
        }

        const vehicle =
          vehicles.get(
            vehicleId
          );

        if (!vehicle) {
          return;
        }

        if (
          vehicle.socketId !==
          socket.id
        ) {
          return;
        }

        if (
          data.status !==
          undefined
        ) {
          vehicle.status =
            normalizeVehicleStatus(
              data.status
            );
        }

        vehicle.lastUpdate =
          Date.now();

        vehicles.set(
          vehicleId,
          vehicle
        );

        updateAllClients();
      }
    );

    // -------------------------------------------------
    // REQUEST LIVE MAP DATA
    // -------------------------------------------------
    //
    // Flutter can request an immediate map refresh.
    // -------------------------------------------------

    socket.on(
      "requestLiveMapData",
      () => {
        let receiverVehicle =
          null;

        for (
          const vehicle
          of vehicles.values()
        ) {
          if (
            vehicle.socketId ===
            socket.id
          ) {
            receiverVehicle =
              vehicle;

            break;
          }
        }

        if (!receiverVehicle) {
          return;
        }

        const mapVehicles =
          buildLiveMapData(
            receiverVehicle
          );

        const nearbyVehicles =
          buildNearbyVehicleData(
            receiverVehicle
          );

        socket.emit(
          "liveMapData",
          {
            currentVehicleId:
              receiverVehicle.vehicleId,

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
    );

    // -------------------------------------------------
    // DISCONNECT
    // -------------------------------------------------

    socket.on(
      "disconnect",
      () => {
        console.log(
          "⚠️ V2V CLIENT DISCONNECTED:",
          socket.id
        );

        let removedVehicleId =
          null;

        for (
          const [
            vehicleId,
            vehicle,
          ]
          of vehicles.entries()
        ) {
          if (
            vehicle.socketId ===
            socket.id
          ) {
            removedVehicleId =
              vehicleId;

            vehicles.delete(
              vehicleId
            );

            break;
          }
        }

        if (
          removedVehicleId
        ) {
          io.emit(
            "vehicleRemoved",
            {
              vehicleId:
                removedVehicleId,

              timestamp:
                Date.now(),
            }
          );
        }

        // Refresh nearby vehicles and
        // the live map immediately.
        updateAllClients();
      }
    );
  }
);

// =====================================================
// START SERVER
// =====================================================

server.listen(
  PORT,
  "0.0.0.0",
  () => {
    console.log(
      "================================"
    );

    console.log(
      "SMART V2V BACKEND RUNNING"
    );

    console.log(
      `PORT: ${PORT}`
    );

    console.log(
      `LOCAL NETWORK: http://YOUR_PC_IP:${PORT}`
    );

    console.log(
      `DETECTION RADIUS: ${DETECTION_RADIUS_METERS} meters`
    );

    console.log(
      `WARNING RADIUS: ${WARNING_RADIUS_METERS} meters`
    );

    console.log(
      `VEHICLE STALE AFTER: ${VEHICLE_STALE_AFTER_MS} ms`
    );

    console.log(
      V2V_SHARED_SECRET
        ? "AUTH: shared-secret enabled"
        : "AUTH: disabled"
    );

    console.log(
      "================================"
    );
  }
);
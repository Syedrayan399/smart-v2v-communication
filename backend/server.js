const express = require("express");
const http = require("http");
const { Server } = require("socket.io");
const admin = require("firebase-admin/app");

const app = express();
const server = http.createServer(app);

// =====================================================
// CONFIGURATION
// =====================================================

const PORT = Number(process.env.PORT || 3000);

// Firebase Admin credentials MUST be supplied through
// the environment.
//
// NEVER commit a Firebase service-account JSON file
// to GitHub.
const FIREBASE_SERVICE_ACCOUNT_JSON =
  (process.env.FIREBASE_SERVICE_ACCOUNT_JSON || "").trim();

if (!FIREBASE_SERVICE_ACCOUNT_JSON) {
  throw new Error(
    "FIREBASE_SERVICE_ACCOUNT_JSON is not configured. " +
      "Set the Firebase Admin service-account JSON in the environment."
  );
}

let firebaseServiceAccount;

try {
  firebaseServiceAccount = JSON.parse(
    FIREBASE_SERVICE_ACCOUNT_JSON
  );
} catch (error) {
  throw new Error(
    "FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON: " +
      error.message
  );
}

const { initializeApp, cert } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");

initializeApp({
  credential: cert(firebaseServiceAccount),
});

const firebaseAuth = getAuth();


const DETECTION_RADIUS_METERS = 200;

// =====================================================
// CORS
// =====================================================

const appCorsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods":
    "GET,POST,DELETE,OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization",
};

app.use(express.json({ limit: "1mb" }));

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
  });
});

// =====================================================
// FIREBASE HTTP AUTHENTICATION
// =====================================================

function getBearerToken(request) {
  const authorization =
    request.headers.authorization;

  if (
    typeof authorization !== "string" ||
    !authorization.startsWith("Bearer ")
  ) {
    return "";
  }

  return authorization
    .substring("Bearer ".length)
    .trim();
}

async function requireHttpAuth(
  request,
  response,
  next
) {
  try {
    const token =
      getBearerToken(request);

    if (!token) {
      return response.status(401).json({
        success: false,
        message:
          "Missing Firebase ID token",
      });
    }

    request.user =
      await firebaseAuth.verifyIdToken(
        token
      );

    next();
  } catch (error) {
    console.warn(
      "HTTP AUTH REJECTED:",
      error.code ||
        error.message
    );

    return response.status(401).json({
      success: false,
      message: "Unauthorized",
    });
  }
}

// =====================================================
// SOCKET FIREBASE AUTHENTICATION
// =====================================================

io.use(async (socket, next) => {
  try {
    const token =
      socket.handshake.auth?.token;

    if (
      typeof token !== "string" ||
      !token.trim()
    ) {
      return next(
        new Error("unauthorized")
      );
    }

    const decodedToken =
      await firebaseAuth.verifyIdToken(
        token.trim()
      );

    socket.user =
      decodedToken;

    socket.uid =
      decodedToken.uid;

    next();
  } catch (error) {
    console.warn(
      "SOCKET AUTH REJECTED:",
      error.code ||
        error.message
    );

    next(
      new Error("unauthorized")
    );
  }
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
      (value * Math.PI) / 180;

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
  let congestion = false;

  if (count < 10) {
    density = "LIGHT";
  } else if (count < 15) {
    density = "MODERATE";

    congestion =
      averageSpeed < 15;
  } else {
    density = "HEAVY";
    congestion = true;
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

  let risk = "SAFE";

  if (
    distance <= 5 &&
    nearbySpeed >= 3
  ) {
    risk = "CRITICAL";
  } else if (
    distance <= 15 &&
    nearbySpeed >= 3
  ) {
    risk = "HIGH";
  } else if (
    distance <= 30 &&
    speedDifference >= 8
  ) {
    risk = "MEDIUM";
  } else if (
    distance <= 50
  ) {
    risk = "EARLY";
  }

  if (
    nearbyBraking &&
    distance <= 20 &&
    risk === "EARLY"
  ) {
    risk = "MEDIUM";
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
// BUILD NEARBY VEHICLES
// =====================================================

function buildNearbyVehicleData(
  ownVehicle
) {
  const nearbyVehicles = [];

  for (
    const vehicle
    of vehicles.values()
  ) {
    if (
      vehicle.vehicleId ===
      ownVehicle.vehicleId
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

    if (
      distance >
      DETECTION_RADIUS_METERS
    ) {
      continue;
    }

    // Never expose Firebase UID or
    // internal socket ID to clients.
    const {
      ownerUid: _ownerUid,
      socketId: _socketId,
      ...publicVehicle
    } = vehicle;

    nearbyVehicles.push({
      ...publicVehicle,

      id:
        vehicle.vehicleId,

      distance:
        Number(
          distance.toFixed(1)
        ),
    });
  }

  return nearbyVehicles;
}

// =====================================================
// FIND PRIMARY THREAT
// =====================================================

function findPrimaryThreat(
  ownVehicle,
  nearbyVehicles
) {
  let primaryThreat = null;

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

    if (
      candidatePriority >
      existingPriority
    ) {
      primaryThreat =
        candidate;

      continue;
    }

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

  if (
    risk === "CRITICAL"
  ) {
    return (
      "Critical collision risk detected. " +
      "Vehicle " +
      vehicle.vehicleId +
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
      "Vehicle " +
      vehicle.vehicleId +
      " is approaching."
    );
  }

  if (
    risk === "MEDIUM"
  ) {
    return (
      "Medium collision risk. " +
      "Vehicle " +
      vehicle.vehicleId +
      " requires attention."
    );
  }

  return (
    "Nearby vehicle detected: " +
    vehicle.vehicleId
  );
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
    if (
      !ownVehicle.socketId
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

    io.to(
      ownVehicle.socketId
    ).emit(
      "nearbyVehicles",
      {
        radius:
          DETECTION_RADIUS_METERS,

        vehicles:
          nearbyVehicles,

        trafficDensity,
      }
    );

    const primaryThreat =
      findPrimaryThreat(
        ownVehicle,
        nearbyVehicles
      );

    if (
      !primaryThreat
    ) {
      io.to(
        ownVehicle.socketId
      ).emit(
        "collisionWarning",
        {
          warning: false,

          level: "SAFE",

          risk: "SAFE",

          message:
            "No immediate collision risk",

          trafficDensity,
        }
      );

      continue;
    }

    const risk =
      primaryThreat.risk;

    if (
      risk === "CRITICAL" ||
      risk === "HIGH" ||
      risk === "MEDIUM" ||
      risk === "EARLY"
    ) {
      io.to(
        ownVehicle.socketId
      ).emit(
        "collisionWarning",
        {
          warning:
            risk === "CRITICAL" ||
            risk === "HIGH",

          level: risk,

          risk,

          vehicle:
            primaryThreat,

          vehicleId:
            primaryThreat.vehicleId,

          id:
            primaryThreat.vehicleId,

          distance:
            primaryThreat.distance,

          speed:
            primaryThreat.speed,

          braking:
            primaryThreat.braking ===
            true,

          message:
            createWarningMessage(
              primaryThreat
            ),

          trafficDensity,
        }
      );
    }
  }
}

// =====================================================
// SEND POSITIONS
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
    if (
      !receiver.socketId
    ) {
      continue;
    }

    for (
      const vehicle
      of allVehicles
    ) {
      if (
        vehicle.vehicleId ===
        receiver.vehicleId
      ) {
        continue;
      }

      io.to(
        receiver.socketId
      ).emit(
        "vehiclePosition",
        {
          vehicleId:
            vehicle.vehicleId,

          id:
            vehicle.vehicleId,

          type:
            vehicle.type,

          latitude:
            vehicle.latitude,

          longitude:
            vehicle.longitude,

          speed:
            vehicle.speed,

          direction:
            vehicle.direction,

          braking:
            vehicle.braking ===
            true,

          simulated:
            vehicle.simulated ===
            true,
        }
      );
    }
  }
}

// =====================================================
// UPDATE ALL CLIENTS
// =====================================================

function updateAllClients() {
  broadcastVehicleData();
  broadcastPositions();
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
    }
  );

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

  trafficSimulationIds = [];

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

  const simulatedVehicle = {
    vehicleId:
      simulatedVehicleId,

    id:
      simulatedVehicleId,

    type:
      "motorcycle",

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

        vehicle.latitude =
          vehicle.latitude -
          0.000006;

        if (
          step < 20
        ) {
          vehicle.speed = 20;
          vehicle.braking = false;
        } else if (
          step < 35
        ) {
          vehicle.speed = 35;
          vehicle.braking = false;
        } else if (
          step < 45
        ) {
          vehicle.speed = 45;
          vehicle.braking = false;
        } else {
          vehicle.speed = 50;

          vehicle.braking =
            step % 8 === 0;
        }

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

  return {
    vehicleId,

    id:
      vehicleId,

    type:
      "car",

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
    count = 5;
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
            (vehicle.direction *
              Math.PI) /
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
                vehicle.speed - 8
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
// STATUS API
// =====================================================

app.get(
  "/api/status",
  requireHttpAuth,
  (_request, response) => {
    const connectedVehicles =
      Array.from(
        vehicles.values()
      ).filter(
        (vehicle) =>
          !vehicle.simulated
      ).length;

    response.json({
      project:
        "SMART V2V COMMUNICATION",

      status:
        "Backend Running",

      connectedVehicles,

      vehicleIds:
        Array.from(
          vehicles.keys()
        ),

      simulationActive,

      detectionRadius:
        DETECTION_RADIUS_METERS,
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
          error.message,
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
          error.message,
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
      socket.id,
      "UID:",
      socket.uid
    );

    // =================================================
    // REFRESH FIREBASE AUTH TOKEN
    // =================================================

    socket.on(
      "refreshAuth",
      async (data) => {
        try {
          const token =
            data?.token;

          if (
            typeof token !==
              "string" ||
            !token.trim()
          ) {
            throw new Error(
              "Missing Firebase ID token"
            );
          }

          const decodedToken =
            await firebaseAuth.verifyIdToken(
              token.trim()
            );

          if (
            decodedToken.uid !==
            socket.uid
          ) {
            throw new Error(
              "Firebase user changed"
            );
          }

          socket.user =
            decodedToken;

          socket.emit(
            "authRefreshSuccess"
          );
        } catch (error) {
          console.warn(
            "SOCKET AUTH REFRESH REJECTED:",
            error.code ||
              error.message
          );

          socket.disconnect(
            true
          );
        }
      }
    );

    // =================================================
    // REGISTER VEHICLE
    // =================================================

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

        // Prevent another Firebase user from
        // claiming an existing vehicle ID.
        if (
          previousVehicle &&
          previousVehicle.ownerUid &&
          previousVehicle.ownerUid !==
            socket.uid
        ) {
          socket.emit(
            "registrationError",
            {
              message:
                "Vehicle ID is already registered to another user.",
            }
          );

          return;
        }

        // If the same vehicle reconnects,
        // replace its old socket.
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
              }
            );
          }
        }

        const vehicle = {
          ownerUid:
            socket.uid,

          vehicleId,

          id:
            vehicleId,

          type:
            data.type ||
            "vehicle",

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

          gpsAccuracy:
            numberValue(
              data.gpsAccuracy,
              Infinity
            ),

          gpsTimestamp:
            numberValue(
              data.gpsTimestamp,
              Date.now()
            ),

          socketId:
            socket.id,

          simulated:
            false,

          lastUpdate:
            Date.now(),
        };

        vehicles.set(
          vehicleId,
          vehicle
        );

        console.log(
          "✅ VEHICLE REGISTERED:",
          vehicleId,
          socket.id
        );

        socket.emit(
          "registrationSuccess",
          {
            vehicleId,
          }
        );

        updateAllClients();
      }
    );

    // =================================================
    // VEHICLE UPDATE
    // =================================================

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

        // Both Firebase ownership AND socket
        // ownership must match.
        if (
          vehicle.ownerUid !==
            socket.uid ||
          vehicle.socketId !==
            socket.id
        ) {
          console.warn(
            "REJECTED vehicleUpdate: ownership/socket mismatch",
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

        vehicle.latitude =
          latitude;

        vehicle.longitude =
          longitude;

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

        vehicle.gpsAccuracy =
          numberValue(
            data.gpsAccuracy,
            vehicle.gpsAccuracy
          );

        vehicle.gpsTimestamp =
          numberValue(
            data.gpsTimestamp,
            Date.now()
          );

        vehicle.lastUpdate =
          Date.now();

        vehicles.set(
          vehicleId,
          vehicle
        );

        updateAllClients();
      }
    );

    // =================================================
    // VEHICLE STATUS UPDATE
    // =================================================

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
          vehicle.ownerUid !==
            socket.uid ||
          vehicle.socketId !==
            socket.id
        ) {
          return;
        }

        if (
          typeof data.status ===
          "string"
        ) {
          vehicle.status =
            data.status;
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

    // =================================================
    // DISCONNECT
    // =================================================

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
            }
          );
        }

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
      "AUTH: Firebase ID token required"
    );

    console.log(
      "================================"
    );
  }
);
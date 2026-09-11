const admin = require("firebase-admin");
const functions = require("firebase-functions/v1");
const {logger} = require("firebase-functions");
const {randomUUID} = require("node:crypto");
const {spawn} = require("node:child_process");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");

admin.initializeApp();

const CALL_TYPE = "incoming_class_call";
const MAX_MULTICAST_TOKENS = 500;
const STORAGE_BUCKET = "scholars-c23e4.firebasestorage.app";
const CLOUDFLARE_REALTIME_BASE_URL = "https://rtc.live.cloudflare.com/v1";
const CLOUDFLARE_REALTIME_APP_ID_SECRET = "CLOUDFLARE_REALTIME_APP_ID";
const CLOUDFLARE_REALTIME_APP_SECRET = "CLOUDFLARE_REALTIME_APP_SECRET";
const SFU_MAX_STUDENT_VIEWERS = 12;
const SFU_REQUEST_TIMEOUT_MS = 15000;

function requireCallableAuth(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Sign in before joining a live class."
    );
  }
}

function requireSfuString(value, name, pattern, maxLength = 256) {
  const normalized = typeof value === "string" ? value.trim() : "";
  if (
    !normalized ||
    normalized.length > maxLength ||
    (pattern && !pattern.test(normalized))
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `${name} is invalid.`
    );
  }
  return normalized;
}

function requireSessionDescription(value, expectedType) {
  if (
    !value ||
    typeof value !== "object" ||
    typeof value.sdp !== "string" ||
    value.sdp.length === 0 ||
    value.sdp.length > 1000000 ||
    value.type !== expectedType
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `A valid SDP ${expectedType} is required.`
    );
  }
  return {sdp: value.sdp, type: expectedType};
}

function cloudflareRealtimeCredentials() {
  const appId = String(process.env[CLOUDFLARE_REALTIME_APP_ID_SECRET] || "")
    .trim();
  const appSecret = String(process.env[CLOUDFLARE_REALTIME_APP_SECRET] || "")
    .trim();
  if (!appId || !appSecret) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Cloudflare Realtime SFU is not configured."
    );
  }
  return {appId, appSecret};
}

async function callCloudflareRealtime(pathname, method, body) {
  const {appId, appSecret} = cloudflareRealtimeCredentials();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), SFU_REQUEST_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(
      `${CLOUDFLARE_REALTIME_BASE_URL}/apps/` +
        `${encodeURIComponent(appId)}${pathname}`,
      {
        method,
        headers: {
          Authorization: `Bearer ${appSecret}`,
          "content-type": "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
      }
    );
  } catch (error) {
    logger.error("Cloudflare Realtime request failed.", {pathname, error});
    throw new functions.https.HttpsError(
      "unavailable",
      controller.signal.aborted
        ? "Cloudflare Realtime timed out."
        : "Cloudflare Realtime is unavailable."
    );
  } finally {
    clearTimeout(timeout);
  }

  let payload = {};
  try {
    payload = await response.json();
  } catch (_) {
    // The error below intentionally avoids returning upstream response text.
  }
  if (
    !response.ok ||
    (payload && (payload.errorCode || payload.errorDescription))
  ) {
    logger.error("Cloudflare Realtime rejected a request.", {
      pathname,
      status: response.status,
      errorCode: payload && payload.errorCode,
    });
    throw new functions.https.HttpsError(
      response.status === 429 ? "resource-exhausted" : "unavailable",
      "Cloudflare Realtime could not complete the media request."
    );
  }
  return payload;
}

async function requireCurrentSfuParticipant(data) {
  const classId = requireSfuString(
    data && data.classId,
    "classId",
    /^[A-Za-z0-9_-]+$/,
    128
  );
  const participantId = requireSfuString(
    data && data.participantId,
    "participantId",
    /^[A-Za-z0-9_-]+$/,
    160
  );
  const connectionId = requireSfuString(
    data && data.connectionId,
    "connectionId",
    /^[A-Za-z0-9_-]+$/,
    160
  );
  const liveClassRef = admin.database().ref(`live_classes/${classId}`);
  const [classSnapshot, participantSnapshot] = await Promise.all([
    liveClassRef.once("value"),
    liveClassRef.child(`participants/${participantId}`).once("value"),
  ]);
  const liveClass = classSnapshot.val() || {};
  const participant = participantSnapshot.val() || {};
  if (
    liveClass.is_live !== true &&
    participant.role !== "teacher"
  ) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "This class is not live."
    );
  }
  if (
    (participant.role !== "teacher" && participant.role !== "student") ||
    String(participant.connection_id || "") !== connectionId
  ) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "The live class participant session is not current."
    );
  }
  return {
    classId,
    participantId,
    connectionId,
    role: participant.role,
    liveClassRef,
  };
}

async function requireCurrentSfuSession(data) {
  const participant = await requireCurrentSfuParticipant(data);
  const sessionRef = participant.liveClassRef.child(
    `sfu/sessions/${participant.participantId}`
  );
  const snapshot = await sessionRef.once("value");
  const session = snapshot.val() || {};
  if (
    String(session.connection_id || "") !== participant.connectionId ||
    !session.producer_session_id ||
    !session.consumer_session_id
  ) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "The Cloudflare media session must be created again."
    );
  }
  return {...participant, sessionRef, session};
}

async function createCloudflareSfuSession(data) {
  const participant = await requireCurrentSfuParticipant(data);
  const [producer, consumer] = await Promise.all([
    callCloudflareRealtime("/sessions/new", "POST"),
    callCloudflareRealtime("/sessions/new", "POST"),
  ]);
  if (!producer.sessionId || !consumer.sessionId) {
    throw new functions.https.HttpsError(
      "unavailable",
      "Cloudflare did not return media session identifiers."
    );
  }
  await participant.liveClassRef
    .child(`sfu/sessions/${participant.participantId}`)
    .set({
      connection_id: participant.connectionId,
      role: participant.role,
      producer_session_id: producer.sessionId,
      consumer_session_id: consumer.sessionId,
      created_at: admin.database.ServerValue.TIMESTAMP,
    });
  return {
    producerSessionId: producer.sessionId,
    consumerSessionId: consumer.sessionId,
  };
}

async function publishCloudflareSfuTracks(data) {
  const current = await requireCurrentSfuSession(data);
  const sessionDescription = requireSessionDescription(
    data.sessionDescription,
    "offer"
  );
  const tracks = Array.isArray(data.tracks) ? data.tracks : [];
  const seenKinds = new Set();
  const requested = tracks.map((track) => {
    const kind = track && track.kind;
    if (
      (kind !== "audio" && kind !== "video") ||
      seenKinds.has(kind)
    ) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Publish at most one audio and one video track."
      );
    }
    seenKinds.add(kind);
    return {
      kind,
      mid: requireSfuString(track.mid, "mid", /^[A-Za-z0-9._:-]+$/, 64),
      trackName: `${kind}-${randomUUID()}`,
    };
  });
  if (requested.length === 0 || requested.length > 2) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "One or two local media tracks are required."
    );
  }
  const result = await callCloudflareRealtime(
    `/sessions/${encodeURIComponent(current.session.producer_session_id)}` +
      "/tracks/new",
    "POST",
    {
      sessionDescription,
      tracks: requested.map(({mid, trackName}) => ({
        location: "local",
        mid,
        trackName,
      })),
    }
  );
  if (
    result.requiresImmediateRenegotiation === true ||
    !result.sessionDescription ||
    result.sessionDescription.type !== "answer"
  ) {
    throw new functions.https.HttpsError(
      "unavailable",
      "Cloudflare returned an invalid publishing negotiation."
    );
  }
  const responseTracks = new Map(
    (result.tracks || []).map((track) => [track.trackName, track])
  );
  const publications = {};
  for (const track of requested) {
    const responseTrack = responseTracks.get(track.trackName) || {};
    publications[track.kind] = {
      participant_id: current.participantId,
      role: current.role,
      kind: track.kind,
      mid: String(responseTrack.mid || track.mid),
      session_id: current.session.producer_session_id,
      track_name: track.trackName,
      connection_id: current.connectionId,
      published_at: admin.database.ServerValue.TIMESTAMP,
    };
  }
  await current.sessionRef.update({publications});
  return {
    sessionDescription: result.sessionDescription,
    tracks: requested.map((track) => ({kind: track.kind, mid: track.mid})),
  };
}

function selectSfuPublications(allSessions, activeParticipants, current) {
  const candidates = Object.entries(allSessions || {})
    .filter(([participantId, value]) => {
      const presence = activeParticipants && activeParticipants[participantId];
      return participantId !== current.participantId &&
        value &&
        value.connection_id &&
        value.publications &&
        presence &&
        String(presence.connection_id || "") === String(value.connection_id);
    })
    .map(([participantId, value]) => ({participantId, ...value}));
  candidates.sort((left, right) => {
    if (left.role === "teacher" && right.role !== "teacher") return -1;
    if (right.role === "teacher" && left.role !== "teacher") return 1;
    return left.participantId.localeCompare(right.participantId);
  });
  const selected = current.role === "teacher"
    ? candidates
    : candidates.slice(0, SFU_MAX_STUDENT_VIEWERS);
  return selected.flatMap((session) =>
    Object.values(session.publications || {})
      .filter((track) =>
        track &&
        (track.kind === "audio" || track.kind === "video") &&
        track.session_id &&
        track.track_name
      )
      .map((track) => ({
        key: `${session.participantId}:${track.kind}`,
        kind: track.kind,
        participantId: session.participantId,
        role: session.role,
        sessionId: track.session_id,
        trackName: track.track_name,
      }))
  );
}

async function subscribeCloudflareSfuTracks(data) {
  const current = await requireCurrentSfuSession(data);
  const [sessionsSnapshot, participantsSnapshot] = await Promise.all([
    current.liveClassRef.child("sfu/sessions").once("value"),
    current.liveClassRef.child("participants").once("value"),
  ]);
  const desired = selectSfuPublications(
    sessionsSnapshot.val(),
    participantsSnapshot.val(),
    current
  );
  const existing = current.session.subscriptions || {};
  const desiredByKey = new Map(desired.map((track) => [track.key, track]));
  const desiredKeys = new Set(desired.map((track) => track.key));
  const stale = Object.values(existing).filter((track) => {
    if (!track || !track.mid) return false;
    const replacement = desiredByKey.get(track.key);
    return !desiredKeys.has(track.key) ||
      replacement.sessionId !== track.sessionId ||
      replacement.trackName !== track.trackName;
  });
  if (stale.length > 0) {
    await callCloudflareRealtime(
      `/sessions/${encodeURIComponent(current.session.consumer_session_id)}` +
        "/tracks/close",
      "PUT",
      {force: true, tracks: stale.map((track) => ({mid: track.mid}))}
    );
  }

  const currentByKey = new Map(
    Object.values(existing)
      .filter(Boolean)
      .map((track) => [track.key, track])
  );
  const add = desired.filter((track) => {
    const old = currentByKey.get(track.key);
    return !old ||
      old.sessionId !== track.sessionId ||
      old.trackName !== track.trackName;
  });
  let result = {requiresImmediateRenegotiation: false, tracks: []};
  if (add.length > 0) {
    result = await callCloudflareRealtime(
      `/sessions/${encodeURIComponent(current.session.consumer_session_id)}` +
        "/tracks/new",
      "POST",
      {
        tracks: add.map((track) => ({
          location: "remote",
          sessionId: track.sessionId,
          trackName: track.trackName,
        })),
      }
    );
  }
  const responseByName = new Map(
    (result.tracks || []).map((track) => [track.trackName, track])
  );
  const subscriptions = desired.map((track) => {
    const old = currentByKey.get(track.key);
    const responseTrack = responseByName.get(track.trackName);
    return {...track, mid: String(responseTrack && responseTrack.mid || old && old.mid || "")};
  });
  if (subscriptions.some((track) => !track.mid)) {
    throw new functions.https.HttpsError(
      "unavailable",
      "Cloudflare did not identify a subscribed media track."
    );
  }
  const stored = {};
  subscriptions.forEach((track, index) => {
    stored[String(index)] = track;
  });
  await current.sessionRef.child("subscriptions").set(
    Object.keys(stored).length === 0 ? null : stored
  );
  return {
    requiresImmediateRenegotiation:
      result.requiresImmediateRenegotiation === true,
    sessionDescription: result.sessionDescription || null,
    subscriptions,
  };
}

async function renegotiateCloudflareSfu(data) {
  const current = await requireCurrentSfuSession(data);
  const sessionDescription = requireSessionDescription(
    data.sessionDescription,
    "answer"
  );
  await callCloudflareRealtime(
    `/sessions/${encodeURIComponent(current.session.consumer_session_id)}` +
      "/renegotiate",
    "PUT",
    {sessionDescription}
  );
  return {ok: true};
}

async function closeCloudflareSfu(data) {
  const current = await requireCurrentSfuSession(data);
  const publications = Object.values(current.session.publications || {});
  const subscriptions = Object.values(current.session.subscriptions || {});
  await Promise.allSettled([
    publications.length === 0 ? Promise.resolve() : callCloudflareRealtime(
      `/sessions/${encodeURIComponent(current.session.producer_session_id)}` +
        "/tracks/close",
      "PUT",
      {force: true, tracks: publications.map((track) => ({mid: track.mid}))}
    ),
    subscriptions.length === 0 ? Promise.resolve() : callCloudflareRealtime(
      `/sessions/${encodeURIComponent(current.session.consumer_session_id)}` +
        "/tracks/close",
      "PUT",
      {force: true, tracks: subscriptions.map((track) => ({mid: track.mid}))}
    ),
  ]);
  await current.sessionRef.remove();
  return {ok: true};
}

exports.cloudflareSfu = functions
  .region("asia-south1")
  .runWith({
    timeoutSeconds: 60,
    memory: "256MB",
    secrets: [
      CLOUDFLARE_REALTIME_APP_ID_SECRET,
      CLOUDFLARE_REALTIME_APP_SECRET,
    ],
  })
  .https.onCall(async (data, context) => {
    requireCallableAuth(context);
    const action = requireSfuString(
      data && data.action,
      "action",
      /^(create|publish|subscribe|renegotiate|close)$/,
      24
    );
    switch (action) {
      case "create":
        return createCloudflareSfuSession(data);
      case "publish":
        return publishCloudflareSfuTracks(data);
      case "subscribe":
        return subscribeCloudflareSfuTracks(data);
      case "renegotiate":
        return renegotiateCloudflareSfu(data);
      case "close":
        return closeCloudflareSfu(data);
      default:
        throw new functions.https.HttpsError(
          "invalid-argument",
          "Unsupported Cloudflare SFU action."
        );
    }
  });

function runFfmpeg(args) {
  return new Promise((resolve, reject) => {
    // Load lazily so Firebase can discover the other exported functions even
    // before a fresh local `npm install`; Cloud Build installs it for runtime.
    const ffmpegPath = require("ffmpeg-static");
    const process = spawn(ffmpegPath, args, {windowsHide: true});
    let stderr = "";

    process.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
      // Keep function logs and memory bounded if ffmpeg is unusually noisy.
      if (stderr.length > 32000) {
        stderr = stderr.slice(-32000);
      }
    });
    process.on("error", reject);
    process.on("close", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(`ffmpeg exited with code ${code}: ${stderr}`));
    });
  });
}

async function findRecordedClass(classId, storagePath) {
  const snapshot = await admin
    .database()
    .ref(`recorded_classes/${classId}`)
    .orderByChild("storage_path")
    .equalTo(storagePath)
    .once("value");

  let match = null;
  snapshot.forEach((child) => {
    match ||= child.ref;
    return match !== null;
  });
  return match;
}

/**
 * Converts browser recordings into seekable H.264/AAC fast-start MP4 files.
 * Browser-created MP4 can be fragmented and report a zero duration to Android
 * even while it plays, so MP4 inputs are normalized as well as WebM inputs.
 * The source object is retained as a recoverable original.
 */
async function makeRecordedClassCompatible(
  object,
  initialRecordedClassRef = null
) {
  const bucketName = object.bucket || STORAGE_BUCKET;
  const sourcePath = object.name || "";
  const match = sourcePath.match(
    /^recorded_classes\/([^/]+)\/(.+)\.(webm|mp4)$/i
  );
  const sourceMetadata = object.metadata || {};
  if (
    !match ||
    /_compatible\.mp4$/i.test(sourcePath) ||
    sourceMetadata.convertedFrom
  ) {
    return;
  }

  const classId = match[1];
  const sourceExtension = match[3].toLowerCase();
  const needsNormalization =
    sourceExtension === "webm" ||
    String(sourceMetadata.normalize_recording || "").toLowerCase() === "true";

  // Native recorders already produce a regular H.264/AAC MP4. Re-encoding
  // those files delayed playback for several minutes and made a playable
  // recording appear as "Preparing for iPhone". Browser MP4 files explicitly
  // opt in below because they may still need their fragmented container
  // normalized for reliable seeking on Android.
  if (!needsNormalization) {
    const recordedClassRef =
      initialRecordedClassRef || (await findRecordedClass(classId, sourcePath));
    await recordedClassRef?.update({
      compatibility_status: "ready",
      compatibility_error: null,
      compatibility_updated_at: admin.database.ServerValue.TIMESTAMP,
    });
    logger.info("Skipped unnecessary recorded class conversion.", {
      classId,
      sourcePath,
      sourceExtension,
    });
    return;
  }

  const destinationPath = sourceExtension === "webm"
    ? sourcePath.replace(/\.webm$/i, ".mp4")
    : sourcePath.replace(/\.mp4$/i, "_compatible.mp4");
  const workId = randomUUID();
  const inputPath = path.join(os.tmpdir(), `${workId}.${sourceExtension}`);
  const outputPath = path.join(os.tmpdir(), `${workId}_compatible.mp4`);
  const bucket = admin.storage().bucket(bucketName);
  const sourceContentType = String(object.contentType || "").toLowerCase();
  const recordedMimeType = String(
    sourceMetadata.recorded_mime_type || ""
  ).toLowerCase();
  const canCopyH264Video =
    sourceContentType.includes("h264") ||
    sourceContentType.includes("avc1") ||
    recordedMimeType.includes("h264") ||
    recordedMimeType.includes("avc1");
  const requiresIOSConversion = sourceExtension === "webm";
  let recordedClassRef =
    initialRecordedClassRef || (await findRecordedClass(classId, sourcePath));

  try {
    await recordedClassRef?.update({
      // MP4 is directly playable while its container is normalized in the
      // background. Only WebM must block iPhone playback until conversion.
      compatibility_status: requiresIOSConversion ? "converting" : "ready",
      compatibility_updated_at: admin.database.ServerValue.TIMESTAMP,
      normalization_status: "converting",
      normalization_updated_at: admin.database.ServerValue.TIMESTAMP,
    });

    await bucket.file(sourcePath).download({destination: inputPath});
    const videoArguments = canCopyH264Video
      ? ["-c:v", "copy"]
      : [
          "-c:v",
          "libx264",
          "-preset",
          "veryfast",
          "-profile:v",
          "baseline",
          "-level",
          "3.0",
          "-pix_fmt",
          "yuv420p",
          "-crf",
          "26",
          "-maxrate",
          "500k",
          "-bufsize",
          "1000k",
        ];
    await runFfmpeg([
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-fflags",
      "+genpts+discardcorrupt",
      "-i",
      inputPath,
      "-map",
      "0:v:0?",
      "-map",
      "0:a:0?",
      ...videoArguments,
      "-c:a",
      "aac",
      "-b:a",
      "64k",
      "-ar",
      "44100",
      "-ac",
      "2",
      "-movflags",
      "+faststart",
      outputPath,
    ]);

    const outputStat = await fs.stat(outputPath);
    if (outputStat.size <= 0) {
      throw new Error("ffmpeg produced an empty MP4 file.");
    }

    const downloadToken = randomUUID();
    await bucket.upload(outputPath, {
      destination: destinationPath,
      resumable: false,
      metadata: {
        contentType: "video/mp4",
        cacheControl: "public,max-age=3600",
        metadata: {
          ...sourceMetadata,
          firebaseStorageDownloadTokens: downloadToken,
          convertedFrom: sourcePath,
          sourceGeneration: String(object.generation || ""),
        },
      },
    });

    const encodedObjectPath = encodeURIComponent(destinationPath);
    const videoUrl =
      `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/` +
      `${encodedObjectPath}?alt=media&token=${downloadToken}`;

    // The Storage event and the final database write can race. Resolve the row
    // again before publishing the compatible URL if necessary.
    recordedClassRef ||= await findRecordedClass(classId, sourcePath);
    if (!recordedClassRef) {
      throw new Error(`No database record references ${sourcePath}.`);
    }
    await recordedClassRef.update({
      video_url: videoUrl,
      storage_path: destinationPath,
      mime_type: "video/mp4",
      file_size_bytes: outputStat.size,
      compatibility_status: "ready",
      compatibility_error: null,
      compatibility_source_path: sourcePath,
      compatibility_updated_at: admin.database.ServerValue.TIMESTAMP,
      normalization_status: "ready",
      normalization_error: null,
      normalization_updated_at: admin.database.ServerValue.TIMESTAMP,
    });

    logger.info("Made recorded class video seekable and compatible.", {
      classId,
      sourcePath,
      destinationPath,
      outputBytes: outputStat.size,
      copiedH264Video: canCopyH264Video,
    });
  } catch (error) {
    logger.error("Recorded class compatibility conversion failed.", {
      classId,
      sourcePath,
      error,
    });
    const errorMessage = String(
      error && error.message ? error.message : error
    );
    await recordedClassRef?.update({
      // A source MP4 remains directly playable if optional normalization
      // fails. WebM still requires a successful conversion on iPhone.
      compatibility_status: requiresIOSConversion ? "failed" : "ready",
      compatibility_error: requiresIOSConversion ? errorMessage : null,
      compatibility_updated_at: admin.database.ServerValue.TIMESTAMP,
      normalization_status: "failed",
      normalization_error: errorMessage,
      normalization_updated_at: admin.database.ServerValue.TIMESTAMP,
    });
    throw error;
  } finally {
    await Promise.allSettled([
      fs.rm(inputPath, {force: true}),
      fs.rm(outputPath, {force: true}),
    ]);
  }
}

const transcodeOptions = {
  memory: "2GB",
  timeoutSeconds: 540,
  maxInstances: 2,
};

exports.transcodeRecordedWebmToMp4 = functions
  .region("asia-south1")
  .runWith(transcodeOptions)
  .storage.bucket(STORAGE_BUCKET)
  .object()
  .onFinalize((object) => makeRecordedClassCompatible(object));

// Existing recordings predate the Storage trigger. A client or administrator
// can request normalization without replacing the recoverable source file.
exports.transcodeRequestedRecordedWebmToMp4 = functions
  .region("us-central1")
  .runWith(transcodeOptions)
  .database.ref(
    "/recorded_classes/{classId}/{recordingId}/compatibility_requested_at"
  )
  .onWrite(async (change) => {
    if (!change.after.exists() || change.after.val() === change.before.val()) {
      return;
    }

    const recordedClassRef = change.after.ref.parent;
    const snapshot = await recordedClassRef.once("value");
    const recording = snapshot.val() || {};
    const sourcePath = String(recording.storage_path || "");
    if (
      !/\.(webm|mp4)$/i.test(sourcePath) ||
      /_compatible\.mp4$/i.test(sourcePath)
    ) {
      return;
    }

    const file = admin.storage().bucket(STORAGE_BUCKET).file(sourcePath);
    const [metadata] = await file.getMetadata();
    await makeRecordedClassCompatible(metadata, recordedClassRef);
  });

exports.notifyStudentsOnLiveClassStart = functions.database
  .ref("/live_classes/{classId}")
  .onWrite(async (change, context) => {
    if (!change.after.exists()) {
      return null;
    }

    const after = change.after.val() || {};
    if (after.is_live !== true) {
      return null;
    }

    const startedAt =
      after.started_at !== undefined && after.started_at !== null
        ? String(after.started_at)
        : "";
    if (!startedAt) {
      return null;
    }

    const before = change.before.exists() ? change.before.val() || {} : {};
    const wasLive = before.is_live === true;
    const previousStartedAt =
      before.started_at !== undefined && before.started_at !== null
        ? String(before.started_at)
        : "";

    if (wasLive && previousStartedAt === startedAt) {
      return null;
    }

    const classId = String(context.params.classId || "");
    if (!classId) {
      return null;
    }

    const studentsSnapshot = await admin
      .database()
      .ref("students")
      .orderByChild("class_id")
      .equalTo(classId)
      .once("value");

    if (!studentsSnapshot.exists()) {
      console.log(`No students found for class ${classId}.`);
      return null;
    }

    const tokenOwners = [];
    studentsSnapshot.forEach((child) => {
      const student = child.val() || {};
      const token =
        typeof student.fcm_token === "string" ? student.fcm_token.trim() : "";

      if (token) {
        tokenOwners.push({
          studentKey: child.key,
          token,
        });
      }

      return false;
    });

    if (!tokenOwners.length) {
      console.log(`No FCM tokens available for class ${classId}.`);
      return null;
    }

    const uniqueTokenOwners = [];
    const seenTokens = new Set();
    for (const owner of tokenOwners) {
      if (seenTokens.has(owner.token)) {
        continue;
      }

      seenTokens.add(owner.token);
      uniqueTokenOwners.push(owner);
    }

    const topic =
      typeof after.topic === "string" && after.topic.trim()
        ? after.topic.trim()
        : "Live Class";
    const teacherName =
      typeof after.teacher_name === "string" && after.teacher_name.trim()
        ? after.teacher_name.trim()
        : "Teacher";

    let successCount = 0;
    const failedResults = [];
    const cleanupTasks = [];

    for (let start = 0; start < uniqueTokenOwners.length; start += MAX_MULTICAST_TOKENS) {
      const batchOwners = uniqueTokenOwners.slice(start, start + MAX_MULTICAST_TOKENS);
      const response = await admin.messaging().sendEachForMulticast({
        tokens: batchOwners.map((owner) => owner.token),
        data: {
          type: CALL_TYPE,
          classId,
          topic,
          teacherName,
          startedAt,
        },
        android: {
          priority: "high",
          ttl: 120 * 1000,
          directBootOk: true,
        },
        apns: {
          headers: {
            "apns-priority": "10",
          },
          payload: {
            aps: {
              alert: {
                title: `Class Live: ${teacherName}`,
                body: topic,
              },
              contentAvailable: true,
              sound: "default",
            },
          },
        },
      });

      successCount += response.successCount;
      response.responses.forEach((result, index) => {
        if (result.success) {
          return;
        }

        failedResults.push(result);
        const errorCode = result.error && result.error.code;
        if (
          errorCode === "messaging/registration-token-not-registered" ||
          errorCode === "messaging/invalid-registration-token"
        ) {
          cleanupTasks.push(
            admin
              .database()
              .ref(`students/${batchOwners[index].studentKey}/fcm_token`)
              .remove()
          );
        }
      });
    }

    if (cleanupTasks.length) {
      await Promise.allSettled(cleanupTasks);
    }

    console.log(
      `Sent ${successCount}/${uniqueTokenOwners.length} live call notifications for class ${classId}. Failures: ${failedResults.length}.`
    );

    return null;
  });

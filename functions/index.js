const admin = require("firebase-admin");
const functions = require("firebase-functions/v1");
const {logger} = require("firebase-functions");
const {randomUUID} = require("node:crypto");
const {spawn} = require("node:child_process");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");

const cloudflareTurnKeyId = defineSecret("CLOUDFLARE_TURN_KEY_ID");
const cloudflareTurnApiToken = defineSecret("CLOUDFLARE_TURN_API_TOKEN");

admin.initializeApp();

// Issue fresh relay credentials for each live-call connection. Cloudflare's
// long-lived TURN key must stay on the server, never in the Flutter web build.
exports.getLiveClassIceServers = onCall(
  {
    secrets: [cloudflareTurnKeyId, cloudflareTurnApiToken],
    maxInstances: 10,
  },
  async (request) => {
    const classId = String(request.data?.classId || "");
    const participantId = String(request.data?.participantId || "");
    if (!request.auth || !/^[A-Za-z0-9_-]{1,128}$/.test(classId) ||
        !/^[A-Za-z0-9_-]{1,128}$/.test(participantId)) {
      throw new HttpsError("permission-denied", "Invalid live class participant.");
    }

    const classRef = admin.database().ref(`live_classes/${classId}`);
    const [liveSnapshot, participantSnapshot] = await Promise.all([
      classRef.child("is_live").get(),
      classRef.child(`participants/${participantId}`).get(),
    ]);
    if (liveSnapshot.val() !== true || !participantSnapshot.exists()) {
      throw new HttpsError("permission-denied", "The live class is unavailable.");
    }

    const response = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(cloudflareTurnKeyId.value())}/credentials/generate-ice-servers`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${cloudflareTurnApiToken.value()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ttl: 86400}),
        signal: AbortSignal.timeout(10000),
      }
    );
    if (!response.ok) {
      logger.error("Cloudflare TURN credential request failed", {status: response.status});
      throw new HttpsError("unavailable", "Video relay is unavailable.");
    }
    const payload = await response.json();
    if (!Array.isArray(payload.iceServers) ||
        !payload.iceServers.some((server) => server.username && server.credential)) {
      throw new HttpsError("unavailable", "Video relay returned no credentials.");
    }
    return {iceServers: payload.iceServers};
  }
);

const CALL_TYPE = "incoming_class_call";
const MAX_MULTICAST_TOKENS = 500;
const STORAGE_BUCKET = "scholars-c23e4.firebasestorage.app";
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

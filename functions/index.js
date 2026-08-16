const admin = require("firebase-admin");
const functions = require("firebase-functions/v1");
const {onValueWritten} = require("firebase-functions/v2/database");
const {onObjectFinalized} = require("firebase-functions/v2/storage");
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
 * Converts browser-only WebM recordings into H.264/AAC fast-start MP4 files.
 * The database URL is switched only after the compatible object is complete;
 * the source WebM is retained as a recoverable original.
 */
async function transcodeRecordedWebm(object, initialRecordedClassRef = null) {
  const bucketName = object.bucket || STORAGE_BUCKET;
  const sourcePath = object.name || "";
  const match = sourcePath.match(/^recorded_classes\/([^/]+)\/(.+)\.webm$/i);
  if (!match) {
    return;
  }

  const classId = match[1];
  const destinationPath = sourcePath.replace(/\.webm$/i, ".mp4");
  const workId = randomUUID();
  const inputPath = path.join(os.tmpdir(), `${workId}.webm`);
  const outputPath = path.join(os.tmpdir(), `${workId}.mp4`);
  const bucket = admin.storage().bucket(bucketName);
  let recordedClassRef =
    initialRecordedClassRef || (await findRecordedClass(classId, sourcePath));

  try {
    await recordedClassRef?.update({
      compatibility_status: "converting",
      compatibility_updated_at: admin.database.ServerValue.TIMESTAMP,
    });

    await bucket.file(sourcePath).download({destination: inputPath});
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
          ...(object.metadata || {}),
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
    });

    logger.info("Converted recorded class WebM to MP4.", {
      classId,
      sourcePath,
      destinationPath,
      outputBytes: outputStat.size,
    });
  } catch (error) {
    logger.error("Recorded class WebM conversion failed.", {
      classId,
      sourcePath,
      error,
    });
    await recordedClassRef?.update({
      compatibility_status: "failed",
      compatibility_error: String(
        error && error.message ? error.message : error
      ),
      compatibility_updated_at: admin.database.ServerValue.TIMESTAMP,
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
  region: "us-central1",
  memory: "2GiB",
  cpu: 2,
  timeoutSeconds: 540,
  maxInstances: 2,
};

exports.transcodeRecordedWebmToMp4 = onObjectFinalized(
  {...transcodeOptions, bucket: STORAGE_BUCKET},
  (event) => transcodeRecordedWebm(event.data)
);

// Existing WebM files predate the Storage trigger. An iPhone client can mark
// one as requested; this path converts it without replacing the source file.
exports.transcodeRequestedRecordedWebmToMp4 = onValueWritten(
  {
    ...transcodeOptions,
    ref: "/recorded_classes/{classId}/{recordingId}/compatibility_requested_at",
  },
  async (event) => {
    if (!event.data.after.exists() || event.data.after.val() === event.data.before.val()) {
      return;
    }

    const recordedClassRef = event.data.after.ref.parent;
    const snapshot = await recordedClassRef.once("value");
    const recording = snapshot.val() || {};
    const sourcePath = String(recording.storage_path || "");
    if (!/\.webm$/i.test(sourcePath) || recording.compatibility_status === "ready") {
      return;
    }

    const file = admin.storage().bucket(STORAGE_BUCKET).file(sourcePath);
    const [metadata] = await file.getMetadata();
    await transcodeRecordedWebm(metadata, recordedClassRef);
  }
);

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

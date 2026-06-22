const admin = require("firebase-admin");
const functions = require("firebase-functions/v1");

admin.initializeApp();

const CALL_TYPE = "incoming_class_call";
const MAX_MULTICAST_TOKENS = 500;

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

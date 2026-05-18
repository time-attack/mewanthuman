import express from "express";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { readFileSync, existsSync, mkdirSync, createReadStream } from "fs";
import crypto from "crypto";
import http2 from "http2";
import { spawn } from "child_process";
import Database from "better-sqlite3";

process.on("uncaughtException", (err) => { console.error("UNCAUGHT:", err.message); });
process.on("unhandledRejection", (err) => { console.error("UNHANDLED:", err?.message || err); });

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── SQLite DB ────────────────────────────────────────────────────────────────
const DB_PATH = process.env.DB_PATH || join(__dirname, "mewanthuman.db");
const db = new Database(DB_PATH);
db.pragma("journal_mode = WAL");
db.exec(`
  CREATE TABLE IF NOT EXISTS calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT UNIQUE,
    phone TEXT NOT NULL,
    reason TEXT DEFAULT '',
    status TEXT DEFAULT 'starting',
    started_at INTEGER,
    ended_at INTEGER,
    message_count INTEGER DEFAULT 0
  )
`);
// ── Screenshot directory for browser-use agent ─────────────────────────────
const SCREENSHOT_DIR = join(__dirname, ".screenshots");
mkdirSync(SCREENSHOT_DIR, { recursive: true });

const app = express();

// CORS — allow Chrome extension and any origin to call /calls
app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.use(express.json());
app.use(express.static(join(__dirname, "public")));

// ── Config ────────────────────────────────────────────────────────────────────
const AGENTPHONE_API_KEY = process.env.AGENTPHONE_API_KEY;
const AGENT_ID           = process.env.AGENTPHONE_AGENT_ID;
const USER_NUMBER        = process.env.USER_PHONE_NUMBER;
const PORT               = process.env.PORT || 3000;
const TARGET_PHONE       = "+18184489009"; // hardcoded target number
const SMS_NUMBER_ID      = "cmp9059eq006lgd29193dlwff"; // iMessage-capable number +17578314612

// APNs config (for iOS push notifications)
const APNS_KEY_ID    = process.env.APNS_KEY_ID || "57D5MTKUJL";
const APNS_TEAM_ID   = process.env.APNS_TEAM_ID || "6PPS68Y9RP";
const APNS_BUNDLE_ID = process.env.APNS_BUNDLE_ID || "com.mewanthuman.app";
const APNS_KEY_PATH  = process.env.APNS_KEY_PATH || join(__dirname, "AuthKey.p8");
const APNS_ENV       = process.env.APNS_ENV || "development"; // "production" for App Store

const SUPERMEMORY_API_KEY = process.env.SUPERMEMORY_API_KEY;
const SUPERMEMORY_USER_ID = "mewanthuman";

if (!AGENTPHONE_API_KEY || !AGENT_ID || !USER_NUMBER) {
  console.error("Missing: AGENTPHONE_API_KEY, AGENTPHONE_AGENT_ID, USER_PHONE_NUMBER");
  process.exit(1);
}

// ── Supermemory (webchat navigation playbooks) ───────────────────────────────

async function smAdd(content, metadata = {}) {
  if (!SUPERMEMORY_API_KEY) return null;
  const res = await fetch("https://api.supermemory.ai/v3/documents", {
    method: "POST",
    headers: {
      "x-api-key": SUPERMEMORY_API_KEY,
      "x-sm-user-id": SUPERMEMORY_USER_ID,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ content, metadata }),
  });
  return res.json();
}

async function smSearch(query, limit = 5) {
  if (!SUPERMEMORY_API_KEY) return { results: [] };
  const res = await fetch("https://api.supermemory.ai/v3/search", {
    method: "POST",
    headers: {
      "x-api-key": SUPERMEMORY_API_KEY,
      "x-sm-user-id": SUPERMEMORY_USER_ID,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ q: query, limit }),
  });
  return res.json();
}

// Extract text content from supermemory search results
function smExtractContent(results) {
  const texts = [];
  for (const r of results || []) {
    // v3 format: results[].chunks[].content
    const chunks = r.chunks || [];
    for (const c of chunks) {
      if (c.content && c.isRelevant !== false) texts.push(c.content.trim());
    }
  }
  return texts;
}

// ── APNs Push Notification ───────────────────────────────────────────────────

let apnsKey = null;
if (APNS_KEY_ID && APNS_TEAM_ID) {
  // Try file first, then base64 env var
  if (APNS_KEY_PATH) {
    try {
      apnsKey = readFileSync(APNS_KEY_PATH, "utf8");
      console.log(`[apns] Loaded key from file: ${APNS_KEY_PATH}`);
    } catch (e) {
      console.warn(`[apns] Could not load file ${APNS_KEY_PATH}: ${e.message}`);
    }
  }
  if (!apnsKey && process.env.APNS_KEY_BASE64) {
    apnsKey = Buffer.from(process.env.APNS_KEY_BASE64, "base64").toString("utf8");
    console.log(`[apns] Loaded key from APNS_KEY_BASE64 env var`);
  }
  if (apnsKey) {
    console.log(`[apns] Ready — key ${APNS_KEY_ID}, team ${APNS_TEAM_ID}, env ${APNS_ENV}`);
  } else {
    console.warn(`[apns] No key available — push notifications disabled`);
  }
}

function makeApnsJwt() {
  if (!apnsKey) return null;
  const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID })).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const claims = Buffer.from(JSON.stringify({ iss: APNS_TEAM_ID, iat: now })).toString("base64url");
  const payload = `${header}.${claims}`;
  // ES256 requires ieee-p1363 (raw r||s) format, not DER
  const signature = crypto.sign("SHA256", Buffer.from(payload), {
    key: apnsKey,
    dsaEncoding: "ieee-p1363",
  }).toString("base64url");
  return `${payload}.${signature}`;
}

function sendPushToDevice(token, payload, jwt, host) {
  return new Promise((resolve) => {
    const client = http2.connect(host);
    client.on("error", (err) => {
      console.error(`[apns] Connection error: ${err.message}`);
      resolve(false);
    });

    const headers = {
      ":method": "POST",
      ":path": `/3/device/${token}`,
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
    };

    const req = client.request(headers);
    let responseData = "";
    let statusCode = 0;

    req.on("response", (hdrs) => { statusCode = hdrs[":status"]; });
    req.on("data", (chunk) => { responseData += chunk; });
    req.on("end", () => {
      client.close();
      if (statusCode === 200) {
        console.log(`[apns] Push sent to ${token.slice(0, 12)}...: OK`);
        resolve(true);
      } else {
        console.error(`[apns] Push failed (${statusCode}): ${responseData}`);
        resolve(false);
      }
    });
    req.on("error", (err) => {
      console.error(`[apns] Request error: ${err.message}`);
      client.close();
      resolve(false);
    });

    req.end(payload);
  });
}

async function sendPush(title, body) {
  if (!apnsKey) {
    console.log(`[apns] No key configured, skipping push: "${title}" — "${body}"`);
    return;
  }

  const devices = db.prepare("SELECT token FROM devices WHERE platform = 'ios'").all();
  if (devices.length === 0) {
    console.log("[apns] No registered devices");
    return;
  }

  const jwt = makeApnsJwt();
  const host = APNS_ENV === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";

  const payload = JSON.stringify({
    aps: {
      alert: { title, body },
      sound: "default",
      badge: 1,
    },
  });

  for (const { token } of devices) {
    await sendPushToDevice(token, payload, jwt, host);
  }
}

// ── SMS Notification via AgentPhone ───────────────────────────────────────────
async function sendSMS(message) {
  try {
    const res = await fetch("https://api.agentphone.ai/v1/messages", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${AGENTPHONE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        agent_id: AGENT_ID,
        to_number: USER_NUMBER,
        body: message,
        number_id: SMS_NUMBER_ID,
      }),
    });

    if (res.ok) {
      const data = await res.json();
      console.log(`[notify] SMS sent to ${USER_NUMBER}:`, data.id || "ok");
    } else {
      const text = await res.text();
      console.error(`[notify] SMS failed (${res.status}):`, text);
    }
  } catch (err) {
    console.error(`[notify] SMS error:`, err.message);
  }
}

function getPublicUrl() {
  return process.env.RAILWAY_PUBLIC_DOMAIN
    ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}`
    : `http://localhost:${PORT}`;
}

async function notifyUserCallStarted(sessionId, reason) {
  const trackingUrl = `${getPublicUrl()}/#call/${sessionId}`;
  await sendSMS(`📞 MeWantHuman is calling ${TARGET_PHONE} for you now.${reason ? ` Reason: "${reason}"` : ''}\n\n🔗 Track live: ${trackingUrl}\n\nWe'll text you again when a human picks up.`);
  // Push to iOS
  await sendPush("New Call", TARGET_PHONE);
}

async function notifyUserHumanReached() {
  await sendSMS(`🧑 Human reached! We're on the phone with ${TARGET_PHONE} right now — pick up your phone! MeWantHuman is transferring you now.`);
  // Push to iOS
  await sendPush("Human Reached", TARGET_PHONE);
}

// ── Active sessions ───────────────────────────────────────────────────────────
const sessions = new Map(); // sessionId -> { messages[], status, callId }

// ══════════════════════════════════════════════════════════════════════════════
// POST /navigate — spawn a Claude Code agent to handle the call
// ══════════════════════════════════════════════════════════════════════════════

app.post("/navigate", async (req, res) => {
  const { reason, phone, channels } = req.body;
  const usePhone = channels?.phone !== false;   // default true
  const useWebchat = channels?.webchat !== false; // default true

  // Use provided phone or fall back to hardcoded target
  const rawPhone = phone || TARGET_PHONE;
  const digits = rawPhone.replace(/\D/g, "");
  let targetPhone;
  if (rawPhone.startsWith("+")) targetPhone = rawPhone;
  else if (digits.length === 10) targetPhone = `+1${digits}`;
  else if (digits.length === 11 && digits[0] === "1") targetPhone = `+${digits}`;
  else targetPhone = `+${digits}`;

  const sessionId = crypto.randomUUID();

  const session = {
    messages: [],
    status: "starting",
    phone: targetPhone,
    reason: reason || "",
    startedAt: Date.now(),
    callId: null,
    webchat: { status: "idle", actions: [], screenshotPath: null, humanReached: false, process: null },
    raceWinner: null,
  };
  sessions.set(sessionId, session);

  // Return immediately, both agents run in background
  res.json({ sessionId, phone: targetPhone });

  // Send SMS confirmation that call is being placed
  notifyUserCallStarted(sessionId, reason || "").catch(err => {
    console.error("[notify] call-started SMS error:", err.message);
  });

  // Spawn selected channels
  if (usePhone) {
    runAgent(sessionId, targetPhone, reason || "").catch(err => {
      session.status = "error";
      session.messages.push({ type: "error", text: err.message, ts: Date.now() });
    });
  }
  if (useWebchat) {
    startWebChat(sessionId, targetPhone, reason || "");
  }
});

// Fallback polling if SSE stream is unavailable
async function pollUntilComplete(callId, session) {
  const startTime = Date.now();
  const maxPollTime = 10 * 60 * 1000;
  let lastCount = 0;

  while (Date.now() - startTime < maxPollTime) {
    await new Promise(r => setTimeout(r, 4000));
    try {
      const res = await fetch(`https://api.agentphone.ai/v1/calls/${callId}/transcript`, {
        headers: { "Authorization": `Bearer ${AGENTPHONE_API_KEY}` },
      });
      const rawText = await res.text();
      let data;
      try { data = JSON.parse(rawText); } catch { continue; }
      const transcripts = data.transcript || [];

      for (let i = lastCount; i < transcripts.length; i++) {
        session.messages.push({
          type: "transcript",
          role: transcripts[i].role,
          text: transcripts[i].content,
          ts: Date.now(),
        });
      }
      lastCount = transcripts.length;

      if (data.status === "completed" || data.status === "failed") {
        session.status = "completed";
        return;
      }
    } catch { continue; }
  }
  session.status = "completed";
}

async function runAgent(sessionId, phone, reason) {
  const session = sessions.get(sessionId);
  session.status = "running";

  // Place the call directly via REST API — this is what actually works
  session.messages.push({ type: "assistant", text: `Calling ${phone}...`, ts: Date.now() });
  session.status = "calling";

  // No per-call systemPrompt override — use the agent's configured prompt which is
  // already tuned for aggressive IVR navigation + silent hold + human detection.
  // The agent's default prompt handles everything.

  try {
    const callRes = await fetch("https://api.agentphone.ai/v1/calls", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${AGENTPHONE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        agentId: AGENT_ID,
        toNumber: phone,
      }),
    });

    const callText = await callRes.text();
    let callData;
    try {
      callData = JSON.parse(callText);
    } catch {
      session.status = "error";
      const preview = callText.slice(0, 200);
      session.messages.push({ type: "error", text: `AgentPhone API returned non-JSON (HTTP ${callRes.status}). Their API may be down. Response: ${preview}`, ts: Date.now() });
      return;
    }

    if (!callRes.ok) {
      session.status = "error";
      session.messages.push({ type: "error", text: `Call failed: ${JSON.stringify(callData)}`, ts: Date.now() });
      return;
    }

    session.callId = callData.id;
    session.status = "in_progress";
    session.messages.push({
      type: "assistant",
      text: `Call placed! ID: ${callData.id} | From: ${callData.fromNumber} → To: ${callData.toNumber}`,
      ts: Date.now(),
    });

    // Stream live transcript via SSE endpoint — real-time updates!
    const startTime = Date.now();
    const allTranscripts = [];
    let humanNotified = false;

    try {
      const sseRes = await fetch(`https://api.agentphone.ai/v1/calls/${callData.id}/transcript/stream`, {
        headers: { "Authorization": `Bearer ${AGENTPHONE_API_KEY}` },
      });

      if (!sseRes.ok) {
        // Fallback to polling if SSE not available
        session.messages.push({ type: "status", text: "Live stream unavailable, polling...", ts: Date.now() });
        await pollUntilComplete(callData.id, session);
        return;
      }

      // Parse SSE stream
      const reader = sseRes.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop(); // keep incomplete line in buffer

        for (const line of lines) {
          // Skip heartbeat comments
          if (line.startsWith(":") || line.trim() === "") continue;

          // Parse SSE event
          if (line.startsWith("event: ended")) {
            // Call is done
            break;
          }

          if (line.startsWith("data: ")) {
            try {
              const data = JSON.parse(line.slice(6));
              // Live transcript entry
              if (data.role && data.content) {
                allTranscripts.push(data);
                session.messages.push({
                  type: "transcript",
                  role: data.role,
                  text: data.content,
                  ts: Date.now(),
                });

                // Detect human agent in real-time and notify user
                // Only match on the phone side (role=user), and require patterns
                // that a REAL human says — not IVR greetings or our own bot's words.
                // Exclude common IVR/bot phrases that contain trigger words.
                const isFromPhone = data.role === "user";
                const content = data.content || "";
                const looksHuman = /\b(my name is \w+|this is \w+[,.]?\s*(how can I|what can I)|hi,?\s+you'?re speaking with|how may I assist you today)\b/i.test(content);
                const isIVR = /press \d|para español|menu|option|enter your|account number|confirmation|automated|recording|please hold|moment please/i.test(content);
                const isOurBot = data.role === "agent";
                if (!humanNotified && isFromPhone && looksHuman && !isIVR && !isOurBot) {
                  humanNotified = true;
                  // Track race winner
                  if (!session.raceWinner) {
                    session.raceWinner = "phone";
                    session.messages.push({
                      type: "race_winner", channel: "phone",
                      text: "PHONE WINS THE RACE! Human agent reached via phone call!",
                      ts: Date.now(),
                    });
                  }
                  notifyUserHumanReached();
                  session.messages.push({
                    type: "status",
                    text: "📱 SMS sent — human detected, notifying you!",
                    ts: Date.now(),
                  });
                }
              }
              // Status/metadata events
              if (data.status) {
                session.messages.push({
                  type: "status",
                  text: `Call status: ${data.status}`,
                  ts: Date.now(),
                });
              }
            } catch { /* skip unparseable lines */ }
          }
        }

        // Check for ended event in processed lines
        if (lines.some(l => l.startsWith("event: ended"))) break;

        // Safety timeout
        if (Date.now() - startTime > 10 * 60 * 1000) {
          session.messages.push({ type: "status", text: "Call timed out after 10 minutes.", ts: Date.now() });
          break;
        }
      }
    } catch (err) {
      session.messages.push({ type: "status", text: `Stream error: ${err.message}. Fetching final state...`, ts: Date.now() });
    }

    // Fetch final call state for summary
    try {
      const finalRes = await fetch(`https://api.agentphone.ai/v1/calls/${callData.id}/transcript`, {
        headers: { "Authorization": `Bearer ${AGENTPHONE_API_KEY}` },
      });
      const finalText = await finalRes.text();
      let finalData;
      try { finalData = JSON.parse(finalText); } catch { finalData = {}; }
      const transcripts = finalData.transcript || allTranscripts;
      const duration = finalData.durationSeconds || Math.round((Date.now() - startTime) / 1000);

      const hasHumanAgent = transcripts.some(t => {
        if (t.role !== "user") return false;
        const c = t.content || "";
        const looksHuman = /\b(my name is \w+|this is \w+[,.]?\s*(how can I|what can I)|hi,?\s+you'?re speaking with|how may I assist you today)\b/i.test(c);
        const isIVR = /press \d|para español|menu|option|enter your|account number|confirmation|automated|recording|please hold|moment please/i.test(c);
        return looksHuman && !isIVR;
      });
      const hasTransfer = transcripts.some(t =>
        t.role === "agent" && /transfer/i.test(t.content)
      );

      // Send SMS if human was reached but we didn't catch it during live stream
      if (hasHumanAgent && !humanNotified) {
        humanNotified = true;
        notifyUserHumanReached();
      }

      // Build full transcript report
      let report = "";
      for (const t of transcripts) {
        const icon = t.role === "agent" ? "🤖" : "📞";
        const label = t.role === "agent" ? "Agent" : "Phone";
        report += `\n${icon} ${label}: ${(t.content || t.text || "").trim()}`;
      }

      session.messages.push({
        type: "summary",
        text: `## Call Complete\n\n**Duration:** ${duration}s | **Reached human:** ${hasHumanAgent ? "Yes" : "No"} | **Transfer:** ${hasTransfer ? "Yes" : "No"}\n\n### Full Transcript${report}`,
        ts: Date.now(),
      });

      // Fetch recording
      try {
        const recRes = await fetch(`https://api.agentphone.ai/v1/calls/${callData.id}/recording`, {
          headers: { "Authorization": `Bearer ${AGENTPHONE_API_KEY}` },
        });
        if (recRes.ok) {
          const contentType = recRes.headers.get("content-type") || "";
          if (contentType.includes("json")) {
            const recData = await recRes.json();
            if (recData.url) {
              session.messages.push({ type: "recording", text: recData.url, ts: Date.now() });
            }
          } else {
            // Recording endpoint returns the audio directly — build the URL
            session.messages.push({
              type: "recording",
              text: `https://api.agentphone.ai/v1/calls/${callData.id}/recording`,
              ts: Date.now(),
            });
          }
        }
      } catch { /* optional */ }
    } catch { /* final fetch optional */ }

    session.status = "completed";
    recordHistory(sessionId, session);
  } catch (err) {
    session.status = "error";
    session.messages.push({ type: "error", text: err.message, ts: Date.now() });
    recordHistory(sessionId, session);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Browser-Use Web Chat Channel (races against the phone call)
// ══════════════════════════════════════════════════════════════════════════════

async function startWebChat(sessionId, phone, reason) {
  const session = sessions.get(sessionId);
  if (!session) return;

  session.webchat = {
    status: "starting",
    actions: [],
    screenshotPath: null,
    humanReached: false,
    process: null,
  };

  session.messages.push({
    type: "webchat_status", channel: "webchat",
    text: "Starting web chat agent — searching playbook memory...",
    ts: Date.now(),
  });

  // ── Broad supermemory search: try phone, then company keywords ─────────
  let playbook = "";
  if (SUPERMEMORY_API_KEY) {
    try {
      // 1. Search by phone number
      const byPhone = await smSearch(`company phone ${phone} live chat steps`, 3);
      const phoneResults = smExtractContent(byPhone.results);
      if (phoneResults.length) {
        playbook = phoneResults.join("\n---\n");
      } else {
        // 2. Reverse-lookup: search with digits stripped
        const digits = phone.replace(/\D/g, "");
        const byDigits = await smSearch(`support chat steps ${digits}`, 3);
        const digitResults = smExtractContent(byDigits.results);
        if (digitResults.length) {
          playbook = digitResults.join("\n---\n");
        }
      }
    } catch (err) {
      console.error("[playbook] supermemory search failed:", err.message);
    }
  }

  if (playbook) {
    session.messages.push({
      type: "webchat_status", channel: "webchat",
      text: "Found playbook in memory! Passing known steps to agent.",
      ts: Date.now(),
    });
  } else {
    session.messages.push({
      type: "webchat_status", channel: "webchat",
      text: "No playbook found — agent will search from scratch.",
      ts: Date.now(),
    });
  }

  // ── Call browser-use Cloud REST API directly (no Python needed) ───────
  const BU_API = "https://api.browser-use.com/api/v3";
  const BU_KEY = process.env.BROWSER_USE_API_KEY;
  if (!BU_KEY) {
    session.webchat.status = "error";
    session.messages.push({ type: "webchat_error", channel: "webchat", text: "BROWSER_USE_API_KEY not set", ts: Date.now() });
    return;
  }

  const buHeaders = { "x-api-key": BU_KEY, "Content-Type": "application/json" };

  const playbookSection = playbook
    ? `\nIMPORTANT — KNOWN NAVIGATION STEPS (from memory):\nFollow these first, they worked before:\n${playbook}\n---\nIf these don't work, fall back to the general approach.\n`
    : "";

  const taskText = `You are racing to reach a HUMAN customer support agent via live web chat.
A phone call is happening in parallel — speed matters!

Company phone number: ${phone}
Customer's issue: "${reason}"
${playbookSection}
Steps:
1. Google "${phone}" to identify the company.
2. Go to their support/contact/help page.
3. Find a live chat widget (chat bubbles, "Chat with us", Intercom/Zendesk/Drift, etc.)
4. Open the chat.
5. If a chatbot answers, escalate aggressively:
   - "I need to speak with a human agent"
   - "Transfer me to a live representative"
   - Click "Talk to a person" / "Live agent" buttons
6. Once connected to a human, explain: "${reason}"

When a REAL human (not bot) responds, include __HUMAN_REACHED__ in your output.
Be fast — every second counts!`;

  session.webchat.status = "browsing";

  // Run the cloud agent in the background
  (async () => {
    try {
      // 1. Create cloud browser session
      handleWebChatEvent(sessionId, { type: "status", text: "Creating cloud browser session..." });
      const sessRes = await fetch(`${BU_API}/sessions`, { method: "POST", headers: buHeaders, body: JSON.stringify({}) });
      if (!sessRes.ok) throw new Error(`Session create failed: ${await sessRes.text()}`);
      const sessData = await sessRes.json();
      const cloudSessionId = sessData.id;

      if (sessData.live_url) {
        handleWebChatEvent(sessionId, { type: "live_url", text: sessData.live_url });
        handleWebChatEvent(sessionId, { type: "status", text: "Live browser view ready" });
      }

      // 2. Create task
      handleWebChatEvent(sessionId, { type: "status", text: "Launching AI browser agent..." });
      const taskRes = await fetch(`${BU_API}/tasks`, {
        method: "POST", headers: buHeaders,
        body: JSON.stringify({ task: taskText, llm: "claude-sonnet-4-6", session_id: cloudSessionId, max_steps: 35 }),
      });
      if (!taskRes.ok) throw new Error(`Task create failed: ${await taskRes.text()}`);
      const taskData = await taskRes.json();
      const cloudTaskId = taskData.id;

      handleWebChatEvent(sessionId, { type: "status", text: "Agent is browsing..." });

      // 3. Poll for steps and status
      let seenSteps = 0;
      while (true) {
        await new Promise(r => setTimeout(r, 3000));

        let taskState;
        try {
          const r = await fetch(`${BU_API}/tasks/${cloudTaskId}`, { headers: buHeaders });
          if (!r.ok) continue;
          taskState = await r.json();
        } catch { continue; }

        const status = taskState.status || "";
        const steps = taskState.steps || [];

        // Emit new steps
        for (let i = seenSteps; i < steps.length; i++) {
          seenSteps++;
          const step = steps[i];
          const desc = step.next_goal || (step.actions?.[0] || "Working...").toString().slice(0, 200);
          handleWebChatEvent(sessionId, { type: "action", text: desc, step: step.number || seenSteps });
          if (step.screenshot_url) {
            handleWebChatEvent(sessionId, { type: "screenshot_url", text: step.screenshot_url, step: step.number });
          }
          // Check for human marker
          if (`${step.next_goal} ${step.actions}`.includes("__HUMAN_REACHED__")) {
            handleWebChatEvent(sessionId, { type: "human_reached", text: "Human agent connected via web chat!" });
          }
        }

        // Check completion
        if (["finished", "stopped", "error", "timed_out", "failed"].includes(status)) {
          const output = taskState.output || "";
          if (output.includes("__HUMAN_REACHED__")) {
            handleWebChatEvent(sessionId, { type: "human_reached", text: "Human agent connected via web chat!" });
          }
          if (status === "error" || status === "failed") {
            handleWebChatEvent(sessionId, { type: "error", text: `Task ${status}: ${String(output).slice(0, 500)}` });
          }
          handleWebChatEvent(sessionId, {
            type: "completed",
            text: session.webchat.humanReached
              ? `Web chat reached a human in ${seenSteps} steps!`
              : `Web chat finished after ${seenSteps} steps. ${String(output).slice(0, 200)}`,
          });
          break;
        }

        // Safety timeout (5 min)
        if (Date.now() - session.startedAt > 5 * 60 * 1000) {
          handleWebChatEvent(sessionId, { type: "status", text: "Web chat timed out after 5 minutes." });
          try { await fetch(`${BU_API}/sessions/${cloudSessionId}/stop`, { method: "POST", headers: buHeaders }); } catch {}
          break;
        }
      }
    } catch (err) {
      handleWebChatEvent(sessionId, { type: "error", text: `Cloud agent error: ${err.message}` });
    }

    // Mark complete
    const s = sessions.get(sessionId);
    if (s && !s.webchat.humanReached) s.webchat.status = "completed";
  })();
}

function handleWebChatEvent(sessionId, event) {
  const session = sessions.get(sessionId);
  if (!session) return;

  switch (event.type) {
    case "status":
    case "action":
    case "thought":
      session.messages.push({
        type: "webchat_" + event.type, channel: "webchat",
        text: event.text, ts: event.ts || Date.now(), step: event.step,
      });
      if (event.type === "action") {
        session.webchat.actions.push({ text: event.text, step: event.step, ts: event.ts });
      }
      if (event.text?.includes("Searching") || event.text?.includes("Google")) session.webchat.status = "browsing";
      if (event.text?.toLowerCase().includes("chat")) session.webchat.status = "chatting";
      break;

    case "screenshot_ready":
      session.webchat.screenshotPath = join(SCREENSHOT_DIR, `${sessionId}.jpg`);
      session.messages.push({
        type: "webchat_screenshot", channel: "webchat",
        text: event.text, ts: event.ts || Date.now(),
      });
      break;

    case "live_url":
      session.webchat.liveUrl = event.text;
      session.messages.push({
        type: "webchat_live_url", channel: "webchat",
        text: event.text, ts: event.ts || Date.now(),
      });
      break;

    case "screenshot_url":
      session.webchat.lastScreenshotUrl = event.text;
      session.messages.push({
        type: "webchat_screenshot", channel: "webchat",
        text: event.text, ts: event.ts || Date.now(),
      });
      break;

    case "human_reached":
      session.webchat.humanReached = true;
      session.webchat.status = "human_reached";
      session.messages.push({
        type: "webchat_human", channel: "webchat",
        text: event.text, ts: event.ts || Date.now(),
      });
      if (!session.raceWinner) {
        session.raceWinner = "webchat";
        session.messages.push({
          type: "race_winner", channel: "webchat",
          text: "WEB CHAT WINS THE RACE! Human agent reached via live chat!",
          ts: Date.now(),
        });
        sendPush("Web Chat Wins!", "Human reached via live chat before the phone!");
        sendSMS(`💬 WEB CHAT WINS! Human agent reached via live chat before the phone call!\n\n🔗 ${getPublicUrl()}/#call/${sessionId}`);
      }
      break;

    case "error":
      session.webchat.status = "error";
      session.messages.push({
        type: "webchat_error", channel: "webchat",
        text: event.text, ts: event.ts || Date.now(),
      });
      break;

    case "completed":
      if (!session.webchat.humanReached) session.webchat.status = "completed";
      session.messages.push({
        type: "webchat_status", channel: "webchat",
        text: event.text, ts: event.ts || Date.now(),
      });
      break;
  }
}

function recordHistory(sessionId, session) {
  db.prepare(`
    INSERT INTO calls (session_id, phone, reason, status, started_at, ended_at, message_count)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(session_id) DO UPDATE SET status=?, ended_at=?, message_count=?
  `).run(
    sessionId, session.phone, session.reason, session.status, session.startedAt, Date.now(), session.messages.length,
    session.status, Date.now(), session.messages.length
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// POST /calls — endpoint for Chrome extension + iOS tweak
// Accepts: { phone_number, action?, source?, reason? }
// Returns: { id, sessionId, phone, status }
// ══════════════════════════════════════════════════════════════════════════════

app.post("/calls", async (req, res) => {
  const { phone_number, action, source, reason } = req.body;

  // "test" action just validates connectivity
  if (action === "test") {
    return res.json({ status: "ok", message: "API reachable", phone: phone_number || TARGET_PHONE });
  }

  if (!phone_number) return res.status(400).json({ error: "phone_number required" });

  // Normalize to E.164
  const digits = phone_number.replace(/\D/g, "");
  let e164;
  if (phone_number.startsWith("+")) e164 = phone_number;
  else if (digits.length === 10) e164 = `+1${digits}`;
  else if (digits.length === 11 && digits[0] === "1") e164 = `+${digits}`;
  else e164 = `+${digits}`;

  const sessionId = crypto.randomUUID();
  const session = {
    messages: [],
    status: "starting",
    phone: e164,
    reason: reason || "",
    source: source || "chrome_extension",
    startedAt: Date.now(),
    callId: null,
    webchat: { status: "idle", actions: [], screenshotPath: null, humanReached: false, process: null },
    raceWinner: null,
  };
  sessions.set(sessionId, session);

  // Send notification
  notifyUserCallStarted(sessionId, reason || "").catch(err => {
    console.error("[notify] call-started SMS error:", err.message);
  });

  // Spawn BOTH channels in parallel
  runAgent(sessionId, e164, reason || "").catch(err => {
    session.status = "error";
    session.messages.push({ type: "error", text: err.message, ts: Date.now() });
  });
  startWebChat(sessionId, e164, reason || "");

  res.json({ id: sessionId, sessionId, phone: TARGET_PHONE, status: "started" });
});

// ══════════════════════════════════════════════════════════════════════════════
// GET /sessions/:id/stream — SSE stream of agent messages
// ══════════════════════════════════════════════════════════════════════════════

app.get("/sessions/:id/stream", (req, res) => {
  const session = sessions.get(req.params.id);
  if (!session) return res.status(404).json({ error: "session not found" });

  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders();

  let cursor = 0;

  const interval = setInterval(() => {
    // Send new messages since last check
    while (cursor < session.messages.length) {
      const msg = session.messages[cursor];
      res.write(`data: ${JSON.stringify(msg)}\n\n`);
      cursor++;
    }

    // Send status updates
    res.write(`event: status\ndata: ${JSON.stringify({ status: session.status, callId: session.callId })}\n\n`);

    // Close when done
    if (session.status === "completed" || session.status === "error") {
      res.write(`event: done\ndata: ${JSON.stringify({ status: session.status })}\n\n`);
      clearInterval(interval);
      res.end();
    }
  }, 500);

  req.on("close", () => clearInterval(interval));
});

// ══════════════════════════════════════════════════════════════════════════════
// GET /sessions/:id — get full session state
// ══════════════════════════════════════════════════════════════════════════════

app.get("/sessions/:id", (req, res) => {
  const session = sessions.get(req.params.id);
  if (!session) return res.status(404).json({ error: "session not found" });
  // Strip non-serializable fields
  const { webchat, ...rest } = session;
  const safeWebchat = webchat ? {
    status: webchat.status,
    actions: webchat.actions,
    humanReached: webchat.humanReached,
    hasScreenshot: !!webchat.screenshotPath && existsSync(webchat.screenshotPath),
  } : null;
  res.json({ ...rest, webchat: safeWebchat, raceWinner: session.raceWinner });
});

// ══════════════════════════════════════════════════════════════════════════════
// GET /sessions/:id/screenshot — latest browser-use screenshot
// ══════════════════════════════════════════════════════════════════════════════

app.get("/sessions/:id/screenshot", (req, res) => {
  const session = sessions.get(req.params.id);
  const path = session?.webchat?.screenshotPath;
  if (!path || !existsSync(path)) return res.status(404).send("No screenshot yet");
  res.setHeader("Content-Type", "image/jpeg");
  res.setHeader("Cache-Control", "no-cache, no-store");
  createReadStream(path).pipe(res);
});

// ══════════════════════════════════════════════════════════════════════════════
// GET /history — call history (all sessions, newest first)
// ══════════════════════════════════════════════════════════════════════════════

app.get("/history", (req, res) => {
  const rows = db.prepare("SELECT * FROM calls ORDER BY started_at DESC LIMIT 100").all();
  res.json(rows.map(r => ({
    sessionId: r.session_id,
    phone: r.phone,
    reason: r.reason,
    status: r.status,
    startedAt: r.started_at,
    endedAt: r.ended_at,
    messageCount: r.message_count,
  })));
});

// ══════════════════════════════════════════════════════════════════════════════
// GET /active — list active (non-completed) sessions
// ══════════════════════════════════════════════════════════════════════════════

app.get("/active", (req, res) => {
  const active = [];
  for (const [id, s] of sessions) {
    if (s.status !== "completed" && s.status !== "error") {
      active.push({ sessionId: id, phone: s.phone, reason: s.reason, status: s.status, startedAt: s.startedAt });
    }
  }
  res.json(active);
});

// ══════════════════════════════════════════════════════════════════════════════
// POST /register-device — iOS app registers for push notifications
// ══════════════════════════════════════════════════════════════════════════════

// Store device tokens in SQLite
db.exec(`CREATE TABLE IF NOT EXISTS devices (token TEXT PRIMARY KEY, platform TEXT, registered_at INTEGER)`);

app.post("/register-device", (req, res) => {
  const { token, platform } = req.body;
  if (!token) return res.status(400).json({ error: "token required" });
  db.prepare(`INSERT OR REPLACE INTO devices (token, platform, registered_at) VALUES (?, ?, ?)`)
    .run(token, platform || "ios", Date.now());
  console.log(`[device] Registered ${platform} device (${token.length} chars): ${token}`);
  res.json({ status: "ok" });
});

// Debug: see registered devices
app.get("/devices", (req, res) => {
  const devices = db.prepare("SELECT * FROM devices").all();
  res.json(devices);
});

// ══════════════════════════════════════════════════════════════════════════════
// Playbooks — supermemory-backed webchat navigation steps
// ══════════════════════════════════════════════════════════════════════════════

// POST /playbooks — store a new playbook
app.post("/playbooks", async (req, res) => {
  const { company, url, phone, steps, notes } = req.body;
  if (!company || !steps) return res.status(400).json({ error: "company and steps required" });

  const content = [
    `Company: ${company}`,
    url ? `URL: ${url}` : null,
    phone ? `Phone: ${phone}` : null,
    `Steps to reach live chat:`,
    steps,
    notes ? `Notes: ${notes}` : null,
  ].filter(Boolean).join("\n");

  try {
    const result = await smAdd(content, {
      company: company.toLowerCase(),
      phone: phone || "",
      type: "webchat_playbook",
    });
    res.json({ status: "ok", id: result?.id, content });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /playbooks/search — search for playbooks by company, phone, or query
app.post("/playbooks/search", async (req, res) => {
  const { query, limit } = req.body;
  if (!query) return res.status(400).json({ error: "query required" });
  try {
    const result = await smSearch(query, limit || 5);
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /playbooks/lookup/:phone — quick lookup by phone number (used by browser agent)
app.get("/playbooks/lookup/:phone", async (req, res) => {
  const phone = decodeURIComponent(req.params.phone);
  try {
    const result = await smSearch(`company phone ${phone} live chat steps`, 3);
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ══════════════════════════════════════════════════════════════════════════════
// GET /status — health check
// ══════════════════════════════════════════════════════════════════════════════

app.get("/status", (req, res) => {
  res.json({
    agentId: AGENT_ID,
    transfersTo: USER_NUMBER,
    activeSessions: sessions.size,
    supermemory: !!SUPERMEMORY_API_KEY,
  });
});

// ══════════════════════════════════════════════════════════════════════════════
// STARTUP
// ══════════════════════════════════════════════════════════════════════════════

app.listen(PORT, () => {
  console.log(`\n  ┌─────────────────────────────────────────┐`);
  console.log(`  │  mewanthuman → http://localhost:${PORT}    │`);
  console.log(`  │  Claude Code Agent + AgentPhone MCP     │`);
  console.log(`  └─────────────────────────────────────────┘`);
  console.log(`  Agent ID:    ${AGENT_ID}`);
  console.log(`  Transfer to: ${USER_NUMBER}`);
  console.log(`  No webhooks, no tunnels — agent handles everything.\n`);
});

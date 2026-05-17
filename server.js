import express from "express";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
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

if (!AGENTPHONE_API_KEY || !AGENT_ID || !USER_NUMBER) {
  console.error("Missing: AGENTPHONE_API_KEY, AGENTPHONE_AGENT_ID, USER_PHONE_NUMBER");
  process.exit(1);
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
}

async function notifyUserHumanReached() {
  await sendSMS(`🧑 Human reached! We're on the phone with ${TARGET_PHONE} right now — pick up your phone! MeWantHuman is transferring you now.`);
}

// ── Active sessions ───────────────────────────────────────────────────────────
const sessions = new Map(); // sessionId -> { messages[], status, callId }

// ══════════════════════════════════════════════════════════════════════════════
// POST /navigate — spawn a Claude Code agent to handle the call
// ══════════════════════════════════════════════════════════════════════════════

app.post("/navigate", async (req, res) => {
  const { reason } = req.body;
  const sessionId = crypto.randomUUID();

  const session = {
    messages: [],
    status: "starting",
    phone: TARGET_PHONE,
    reason: reason || "",
    startedAt: Date.now(),
    callId: null,
  };
  sessions.set(sessionId, session);

  // Return immediately, agent runs in background
  res.json({ sessionId, phone: TARGET_PHONE });

  // Send SMS confirmation that call is being placed
  notifyUserCallStarted(sessionId, reason || "").catch(err => {
    console.error("[notify] call-started SMS error:", err.message);
  });

  // Spawn agent
  runAgent(sessionId, TARGET_PHONE, reason || "").catch(err => {
    session.status = "error";
    session.messages.push({ type: "error", text: err.message, ts: Date.now() });
  });
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
                if (!humanNotified && data.role === "user" &&
                    /my name is|how can I (help|assist)|thank you for calling/i.test(data.content)) {
                  humanNotified = true;
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

      const hasHumanAgent = transcripts.some(t =>
        t.role === "user" && /my name is|how can I (help|assist)|thank you for calling/i.test(t.content)
      );
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
  const { action, source, reason } = req.body;

  // "test" action just validates connectivity
  if (action === "test") {
    return res.json({ status: "ok", message: "API reachable", phone: TARGET_PHONE });
  }

  const sessionId = crypto.randomUUID();
  const session = {
    messages: [],
    status: "starting",
    phone: TARGET_PHONE,
    reason: reason || "",
    source: source || "chrome_extension",
    startedAt: Date.now(),
    callId: null,
  };
  sessions.set(sessionId, session);

  // Send SMS confirmation
  notifyUserCallStarted(sessionId, reason || "").catch(err => {
    console.error("[notify] call-started SMS error:", err.message);
  });

  // Spawn agent in background
  runAgent(sessionId, TARGET_PHONE, reason || "").catch(err => {
    session.status = "error";
    session.messages.push({ type: "error", text: err.message, ts: Date.now() });
  });

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
  res.json(session);
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
// GET /status — health check
// ══════════════════════════════════════════════════════════════════════════════

app.get("/status", (req, res) => {
  res.json({
    agentId: AGENT_ID,
    transfersTo: USER_NUMBER,
    activeSessions: sessions.size,
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

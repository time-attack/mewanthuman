import express from "express";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

process.on("uncaughtException", (err) => { console.error("UNCAUGHT:", err.message); });
process.on("unhandledRejection", (err) => { console.error("UNHANDLED:", err?.message || err); });

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
app.use(express.json());
app.use(express.static(join(__dirname, "public")));

// ── Config ────────────────────────────────────────────────────────────────────
const AGENTPHONE_API_KEY = process.env.AGENTPHONE_API_KEY;
const AGENT_ID           = process.env.AGENTPHONE_AGENT_ID;
const USER_NUMBER        = process.env.USER_PHONE_NUMBER;
const PORT               = process.env.PORT || 3000;

if (!AGENTPHONE_API_KEY || !AGENT_ID || !USER_NUMBER) {
  console.error("Missing: AGENTPHONE_API_KEY, AGENTPHONE_AGENT_ID, USER_PHONE_NUMBER");
  process.exit(1);
}

// ── Active sessions ───────────────────────────────────────────────────────────
const sessions = new Map(); // sessionId -> { messages[], status, callId }

// ══════════════════════════════════════════════════════════════════════════════
// POST /navigate — spawn a Claude Code agent to handle the call
// ══════════════════════════════════════════════════════════════════════════════

app.post("/navigate", async (req, res) => {
  const { phone, reason } = req.body;
  if (!phone) return res.status(400).json({ error: "phone required" });

  const e164 = phone.startsWith("+") ? phone : `+1${phone.replace(/\D/g, "")}`;
  const sessionId = crypto.randomUUID();

  const session = {
    messages: [],
    status: "starting",
    phone: e164,
    reason: reason || "",
    startedAt: Date.now(),
    callId: null,
  };
  sessions.set(sessionId, session);

  // Return immediately, agent runs in background
  res.json({ sessionId, phone: e164 });

  // Spawn agent
  runAgent(sessionId, e164, reason || "").catch(err => {
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
      const data = await res.json();
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

    const callData = await callRes.json();

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
      const finalData = await finalRes.json();
      const transcripts = finalData.transcript || allTranscripts;
      const duration = finalData.durationSeconds || Math.round((Date.now() - startTime) / 1000);

      const hasHumanAgent = transcripts.some(t =>
        t.role === "user" && /my name is|how can I (help|assist)/i.test(t.content)
      );
      const hasTransfer = transcripts.some(t =>
        t.role === "agent" && /transfer/i.test(t.content)
      );

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
  } catch (err) {
    session.status = "error";
    session.messages.push({ type: "error", text: err.message, ts: Date.now() });
  }
}

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

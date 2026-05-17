// Simple test API server — mimics the AgentPhone AI /v1/calls endpoint
// Run: node test-server.js
// Then set your extension endpoint to: http://localhost:3456/v1

const http = require("http");

const PORT = 3456;

const server = http.createServer((req, res) => {
  // CORS headers so the extension and popup can reach us
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method === "POST" && req.url === "/v1/calls") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const auth = req.headers.authorization || "";
      console.log(`[${new Date().toISOString()}] POST /v1/calls`);
      console.log(`  Auth: ${auth}`);
      console.log(`  Body: ${body}`);

      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Invalid JSON" }));
        return;
      }

      // Respond with a fake successful call
      const response = {
        id: "call_" + Math.random().toString(36).slice(2, 10),
        status: "initiated",
        phone_number: parsed.phone_number,
        action: parsed.action,
        message: "Call initiated successfully (test mode)",
        timestamp: new Date().toISOString(),
      };

      console.log(`  Response: ${JSON.stringify(response)}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(response));
    });
    return;
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "Not found" }));
});

server.listen(PORT, () => {
  console.log(`MeWantHuman test API running at http://localhost:${PORT}`);
  console.log(`Set your extension endpoint to: http://localhost:${PORT}/v1`);
  console.log(`Use any string as the API key.`);
});

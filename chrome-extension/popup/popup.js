const API_URL = "https://mewanthuman-production.up.railway.app/status";
const statusBar = document.getElementById("status");
const statusText = document.getElementById("statusText");

fetch(API_URL)
  .then((res) => res.json())
  .then((data) => {
    statusBar.className = "status-bar ok";
    statusText.textContent = `Connected — ${data.activeSessions} active session${data.activeSessions === 1 ? "" : "s"}`;
  })
  .catch(() => {
    statusBar.className = "status-bar err";
    statusText.textContent = "Server unreachable";
  });

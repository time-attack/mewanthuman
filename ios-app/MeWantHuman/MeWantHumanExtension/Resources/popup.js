const API_URL = "https://mewanthuman-production.up.railway.app/status";
const statusBar = document.getElementById("status");
const statusText = document.getElementById("statusText");

fetch(API_URL)
  .then((res) => res.json())
  .then((data) => {
    statusBar.className = "status-bar ok";
    const count = data.activeSessions || 0;
    statusText.textContent = `Connected \u2014 ${count} active session${count === 1 ? "" : "s"}`;
  })
  .catch(() => {
    statusBar.className = "status-bar err";
    statusText.textContent = "Server unreachable";
  });

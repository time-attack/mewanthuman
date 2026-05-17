const endpointInput = document.getElementById("endpoint");
const apikeyInput = document.getElementById("apikey");
const useridInput = document.getElementById("userid");
const saveBtn = document.getElementById("saveBtn");
const testBtn = document.getElementById("testBtn");
const clearBtn = document.getElementById("clearBtn");
const statusBar = document.getElementById("status");
const statusText = document.getElementById("statusText");
const toast = document.getElementById("toast");

// Load saved settings
chrome.storage.sync.get(["apiKey", "apiEndpoint", "userId"], (items) => {
  if (items.apiEndpoint) endpointInput.value = items.apiEndpoint;
  if (items.apiKey) apikeyInput.value = items.apiKey;
  if (items.userId) useridInput.value = items.userId;
  updateStatus(items.apiKey && items.apiEndpoint);
});

function updateStatus(connected) {
  if (connected) {
    statusBar.className = "status-bar connected";
    statusText.textContent = "Connected";
  } else {
    statusBar.className = "status-bar disconnected";
    statusText.textContent = "Not configured";
  }
}

function showToast(message, type) {
  toast.textContent = message;
  toast.className = `toast ${type}`;
  setTimeout(() => {
    toast.className = "toast";
  }, 4000);
}

saveBtn.addEventListener("click", () => {
  const endpoint = endpointInput.value.trim();
  const apiKey = apikeyInput.value.trim();
  const userId = useridInput.value.trim();

  if (!endpoint || !apiKey) {
    showToast("API Endpoint and API Key are required.", "error");
    return;
  }

  try {
    new URL(endpoint);
  } catch {
    showToast("Invalid API Endpoint URL.", "error");
    return;
  }

  chrome.storage.sync.set({ apiEndpoint: endpoint, apiKey, userId }, () => {
    updateStatus(true);
    showToast("Settings saved!", "success");
  });
});

testBtn.addEventListener("click", async () => {
  const endpoint = endpointInput.value.trim();
  const apiKey = apikeyInput.value.trim();

  if (!endpoint || !apiKey) {
    showToast("Save your settings first.", "error");
    return;
  }

  testBtn.disabled = true;
  testBtn.textContent = "Testing\u2026";

  try {
    const url = `${endpoint.replace(/\/+$/, "")}/calls`;
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        phone_number: "0000000000",
        action: "test",
      }),
    });

    if (res.ok) {
      const data = await res.json();
      showToast(`API reachable! Response: ${JSON.stringify(data).slice(0, 80)}`, "success");
    } else {
      showToast(`API returned ${res.status}: ${(await res.text()).slice(0, 80)}`, "error");
    }
  } catch (err) {
    showToast(`Connection failed: ${err.message}`, "error");
  } finally {
    testBtn.disabled = false;
    testBtn.textContent = "Test API Connection";
  }
});

clearBtn.addEventListener("click", () => {
  chrome.storage.sync.remove(["apiKey", "apiEndpoint", "userId"], () => {
    endpointInput.value = "";
    apikeyInput.value = "";
    useridInput.value = "";
    updateStatus(false);
    showToast("Disconnected and credentials cleared.", "success");
  });
});

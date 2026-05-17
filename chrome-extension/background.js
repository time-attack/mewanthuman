// Background service worker — handles API calls from content script

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "CALL_PHONE") {
    handleCallPhone(message.phoneNumber)
      .then((result) => sendResponse({ success: true, data: result }))
      .catch((err) => sendResponse({ success: false, error: err.message }));
    return true; // keep channel open for async response
  }

  if (message.type === "CHECK_AUTH") {
    chrome.storage.sync.get(["apiKey", "apiEndpoint", "userId"], (items) => {
      sendResponse({
        authenticated: !!(items.apiKey && items.apiEndpoint),
        userId: items.userId || null,
      });
    });
    return true;
  }
});

async function handleCallPhone(phoneNumber) {
  const { apiKey, apiEndpoint } = await chrome.storage.sync.get([
    "apiKey",
    "apiEndpoint",
  ]);

  if (!apiKey || !apiEndpoint) {
    throw new Error("Not configured. Open the extension popup to set up your API credentials.");
  }

  // Call the AgentPhone AI API (or test endpoint)
  const url = `${apiEndpoint.replace(/\/+$/, "")}/calls`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      phone_number: phoneNumber,
      action: "connect_human",
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`API error ${response.status}: ${text}`);
  }

  return response.json();
}

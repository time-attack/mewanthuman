// Background service worker — calls mewanthuman API directly

const API_URL = "https://mewanthuman-production.up.railway.app/calls";

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "CALL_PHONE") {
    handleCallPhone(message.phoneNumber)
      .then((result) => sendResponse({ success: true, data: result }))
      .catch((err) => sendResponse({ success: false, error: err.message }));
    return true;
  }
});

async function handleCallPhone(phoneNumber) {
  const response = await fetch(API_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
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

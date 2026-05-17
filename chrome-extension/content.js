// Content script — finds phone numbers on the page and injects "human" buttons

const PHONE_REGEX =
  /(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)?\d{3}[-.\s]?\d{4}\b/g;

const PROCESSED_ATTR = "data-mewanthuman";

function isPhoneNumber(text) {
  // Strip non-digit chars and check length
  const digits = text.replace(/\D/g, "");
  return digits.length >= 7 && digits.length <= 15;
}

function normalizePhone(raw) {
  return raw.replace(/\D/g, "");
}

function createHumanButton(phoneNumber, rawText) {
  const btn = document.createElement("button");
  btn.className = "mewanthuman-btn";
  btn.title = `Call ${rawText} via MeWantHuman`;
  btn.textContent = "\u{1F9D1} Human";
  btn.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    initiateCall(phoneNumber, btn);
  });
  return btn;
}

async function initiateCall(phoneNumber, btn) {
  btn.disabled = true;
  btn.textContent = "\u23F3 Calling\u2026";
  btn.classList.add("mewanthuman-btn--loading");

  try {
    const response = await chrome.runtime.sendMessage({
      type: "CALL_PHONE",
      phoneNumber,
    });

    if (response.success) {
      btn.textContent = "\u2705 Connected";
      btn.classList.remove("mewanthuman-btn--loading");
      btn.classList.add("mewanthuman-btn--success");
      setTimeout(() => resetButton(btn), 4000);
    } else {
      btn.textContent = "\u274C Failed";
      btn.classList.remove("mewanthuman-btn--loading");
      btn.classList.add("mewanthuman-btn--error");
      console.error("[MeWantHuman]", response.error);
      setTimeout(() => resetButton(btn), 4000);
    }
  } catch (err) {
    btn.textContent = "\u274C Error";
    btn.classList.remove("mewanthuman-btn--loading");
    btn.classList.add("mewanthuman-btn--error");
    console.error("[MeWantHuman]", err);
    setTimeout(() => resetButton(btn), 4000);
  }
}

function resetButton(btn) {
  btn.disabled = false;
  btn.textContent = "\u{1F9D1} Human";
  btn.classList.remove("mewanthuman-btn--success", "mewanthuman-btn--error", "mewanthuman-btn--loading");
}

function processTextNode(node) {
  const text = node.textContent;
  if (!text || text.trim().length < 7) return;

  const matches = text.match(PHONE_REGEX);
  if (!matches) return;

  for (const match of matches) {
    if (!isPhoneNumber(match)) continue;

    const parent = node.parentElement;
    if (!parent || parent.closest("[data-mewanthuman]")) continue;
    if (parent.tagName === "SCRIPT" || parent.tagName === "STYLE" || parent.tagName === "TEXTAREA" || parent.tagName === "INPUT" || parent.isContentEditable) continue;

    // Wrap the phone number and add button
    const idx = node.textContent.indexOf(match);
    if (idx === -1) continue;

    const before = node.textContent.substring(0, idx);
    const after = node.textContent.substring(idx + match.length);

    const wrapper = document.createElement("span");
    wrapper.setAttribute(PROCESSED_ATTR, "true");
    wrapper.className = "mewanthuman-wrapper";

    const phoneSpan = document.createElement("span");
    phoneSpan.className = "mewanthuman-phone";
    phoneSpan.textContent = match;

    const btn = createHumanButton(normalizePhone(match), match);

    wrapper.appendChild(phoneSpan);
    wrapper.appendChild(btn);

    const frag = document.createDocumentFragment();
    if (before) frag.appendChild(document.createTextNode(before));
    frag.appendChild(wrapper);
    if (after) frag.appendChild(document.createTextNode(after));

    parent.replaceChild(frag, node);
    break; // node is gone, stop processing it
  }
}

function scanNode(root) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const parent = node.parentElement;
      if (!parent) return NodeFilter.FILTER_REJECT;
      if (parent.closest("[data-mewanthuman]")) return NodeFilter.FILTER_REJECT;
      if (["SCRIPT", "STYLE", "TEXTAREA", "INPUT", "NOSCRIPT"].includes(parent.tagName)) {
        return NodeFilter.FILTER_REJECT;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });

  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  nodes.forEach(processTextNode);
}

// Also detect <a href="tel:..."> links
function scanTelLinks(root) {
  const links = root.querySelectorAll('a[href^="tel:"]:not([data-mewanthuman])');
  links.forEach((link) => {
    const raw = link.href.replace("tel:", "");
    const digits = normalizePhone(raw);
    if (!isPhoneNumber(raw)) return;

    link.setAttribute(PROCESSED_ATTR, "true");

    const wrapper = document.createElement("span");
    wrapper.setAttribute(PROCESSED_ATTR, "true");
    wrapper.className = "mewanthuman-wrapper";

    const btn = createHumanButton(digits, raw);
    link.parentElement.insertBefore(wrapper, link.nextSibling);
    wrapper.appendChild(btn);
  });
}

// Initial scan
scanNode(document.body);
scanTelLinks(document.body);

// Watch for dynamically added content
const observer = new MutationObserver((mutations) => {
  for (const mutation of mutations) {
    for (const node of mutation.addedNodes) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        scanNode(node);
        scanTelLinks(node);
      } else if (node.nodeType === Node.TEXT_NODE) {
        processTextNode(node);
      }
    }
  }
});

observer.observe(document.body, { childList: true, subtree: true });

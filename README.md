# MeWantHuman

**Built for the [CallMyAgent YC Hackathon](https://www.callmyagent.gg/)**

Skip the hold music. Skip the chatbots. Get a human, now.

MeWantHuman is a cross-platform tool that connects you directly to a real person at customer support. It races two channels simultaneously — an AI phone agent navigating IVR menus and a browser agent finding live chat — and whoever reaches a human first wins.

One tap on any phone number from your iPhone, Chrome, or Safari and MeWantHuman takes over.

## How It Works

```
You tap a phone number
        │
        ├──→ Phone Channel (AgentPhone)
        │      Dials the number, navigates IVR menus,
        │      sits on hold, detects when a human picks up
        │
        ├──→ Web Chat Channel (Browser Use)
        │      Googles the company, finds live chat,
        │      battles through chatbots, escalates to human
        │
        └──→ RACE! First channel to reach a human wins
               │
               └──→ You get an SMS + push notification
                    "Human reached! Pick up now."
```

Both channels run in parallel. The moment either one connects to a real person, you're notified instantly via SMS and push notification. The losing channel is abandoned.

## Supermemory: The Playbook System

The hardest part of reaching a human isn't the call itself — it's knowing _how_ to navigate each company's unique maze of menus, bots, and dead ends.

MeWantHuman uses [Supermemory](https://supermemory.ai) to build a growing index of successful navigation paths:

- **After each successful connection**, the steps that worked are stored as a playbook
- **Before each new attempt**, the agent checks memory for known paths
- **Two-phase lookup**: first by phone number, then by company name (identified via Google)
- **Semantic search**: even fuzzy queries like "Comcast billing chat" find the right playbook

This means the first time you call Expedia, the browser agent might take 70 steps and 10 minutes to find live chat. The second time? It already knows the 15-step bypass path and goes straight there.

Example playbook (Expedia):
```
1. Go to expedia.com/service/
2. Search for "agent" in the help search bar
3. Click "How to contact us" → "Get in touch"
4. Fill contact form: Flight credit + Flights → Next
5. Click "Chat with us" → "Live chat with an agent"
6. Bot demands sign-in → click "Never mind"
7. Type urgent/legal message to force human routing
8. Select "Flight" → human joins in ~2 minutes
```

Without the playbook, the agent would waste time trying the Virtual Agent (which loops sign-in endlessly), refreshing, retrying — all dead ends that memory already knows to skip.

## Platform Support

### iOS App (SwiftUI)
Native iPhone app with push notifications. Tap any phone number → MeWantHuman takes over. Get notified the instant a human picks up.

### Chrome Extension
Detects phone numbers on any webpage and injects a "Human" button. One click and both channels start racing. Works on any site — airline booking confirmations, bank support pages, utility bills.

### Safari Web Extension (iOS)
Same functionality as Chrome, but for Safari on iPhone and iPad. Tap a detected phone number → race starts.

### Web Dashboard
Real-time dashboard showing the race between phone and web chat channels. Live transcript, browser screenshots, and status updates as the agents navigate.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  Express Server                  │
│                   (server.js)                    │
├─────────────┬───────────────────┬───────────────┤
│  AgentPhone │   Browser Use     │  Supermemory  │
│   REST API  │   Cloud SDK       │   v3 API      │
│             │   (Python agent)  │               │
│  Places     │   Spawns cloud    │  Stores &     │
│  calls,     │   browser,        │  retrieves    │
│  streams    │   navigates to    │  navigation   │
│  transcript │   live chat       │  playbooks    │
├─────────────┴───────────────────┴───────────────┤
│  SQLite (call history, device tokens)           │
│  APNs (iOS push)  ·  SMS (AgentPhone)           │
└─────────────────────────────────────────────────┘
```

**Phone channel**: AgentPhone AI agent dials the number, navigates IVR menus ("Press 1 for billing..."), sits on hold, and detects when a real human picks up using pattern matching on the transcript.

**Web chat channel**: A Python agent (`browser_agent.py`) uses the Browser Use Cloud SDK to spawn a headless browser, Google the phone number to identify the company, navigate to their support page, find the live chat widget, and escalate through chatbots to reach a human.

**Supermemory**: Before each web chat attempt, the server searches supermemory by phone number and company name. If a playbook exists, it's injected into the browser agent's prompt so it follows the known-good path instead of exploring from scratch.

## Setup

```bash
# Install dependencies
npm install

# Set up Python environment for browser agent
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Configure environment
cp .env.example .env
# Fill in credentials (see below)

# Run
npm run dev
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `AGENTPHONE_API_KEY` | AgentPhone API key for placing calls |
| `AGENTPHONE_AGENT_ID` | AgentPhone agent ID (configured for IVR navigation) |
| `USER_PHONE_NUMBER` | Your phone number for call transfers |
| `BROWSER_USE_API_KEY` | Browser Use Cloud API key |
| `SUPERMEMORY_API_KEY` | Supermemory API key (starts with `sm_`) |
| `APNS_KEY_ID` | Apple Push Notification key ID (optional) |
| `APNS_TEAM_ID` | Apple Developer Team ID (optional) |
| `PORT` | Server port (default: 3000) |

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `POST /navigate` | Start a dual-channel race (`{phone, reason, channels}`) |
| `POST /calls` | Chrome extension / iOS endpoint (`{phone_number, reason}`) |
| `GET /sessions/:id/stream` | SSE stream of live race progress |
| `GET /sessions/:id` | Get full session state |
| `GET /sessions/:id/screenshot` | Latest browser agent screenshot |
| `POST /playbooks` | Store a new navigation playbook |
| `POST /playbooks/search` | Semantic search across playbooks |
| `GET /playbooks/lookup/:phone` | Quick playbook lookup by phone |
| `GET /history` | Call history |
| `GET /active` | Currently active sessions |
| `GET /status` | Health check |

## Chrome Extension

1. Open `chrome://extensions` → Enable Developer Mode
2. Click "Load unpacked" → select `chrome-extension/` folder
3. Click the extension icon → set API Endpoint to your server URL + `/calls`
4. Browse any page with phone numbers → click the "Human" button

## Deploy

[![Deploy on Railway](https://railway.app/button/deploy)](https://railway.app)

Set the environment variables in your Railway project settings.

## Tech Stack

- **Server**: Node.js, Express, SQLite (better-sqlite3)
- **Phone AI**: [AgentPhone](https://agentphone.ai) — AI voice agent for IVR navigation
- **Browser AI**: [Browser Use](https://browser-use.com) Cloud SDK — headless browser automation
- **Memory**: [Supermemory](https://supermemory.ai) — semantic memory for navigation playbooks
- **iOS**: SwiftUI, APNs push notifications
- **Extensions**: Chrome Manifest V3, Safari Web Extension

## License

Built at the CallMyAgent YC Hackathon, May 2026.

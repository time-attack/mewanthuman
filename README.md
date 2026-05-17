# mewanthuman

AI-powered customer support call navigator — gets you to a human agent automatically.

## Components

- **Server** (`server.js`) — Express API that places calls via AgentPhone AI, navigates IVR menus, and connects you to a real human
- **Chrome Extension** (`chrome-extension/`) — Detects phone numbers on any website and adds a "Human" button to call via the API
- **iOS Tweak** (`ios-tweak/`) — Hooks Phone.app context menu to send numbers to the API from recent calls

## Setup

```bash
npm install
cp .env.example .env
# Fill in your AgentPhone credentials
npm run dev
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `AGENTPHONE_API_KEY` | Your AgentPhone API key |
| `AGENTPHONE_AGENT_ID` | Your AgentPhone agent ID |
| `USER_PHONE_NUMBER` | Your phone number for transfers |
| `PORT` | Server port (default: 3000) |

## API Endpoints

- `POST /navigate` — Web UI call initiation (`{phone, reason}`)
- `POST /calls` — Chrome extension & iOS tweak endpoint (`{phone_number, action?, source?, reason?}`)
- `GET /sessions/:id/stream` — SSE stream of call progress
- `GET /sessions/:id` — Get session state
- `GET /status` — Health check

## Chrome Extension

1. Open `chrome://extensions` → Enable Developer Mode
2. Click "Load unpacked" → select `chrome-extension/` folder
3. Click the extension icon → set API Endpoint to your deployed server URL + `/calls`
4. Set API Key to your AgentPhone key

## iOS Tweak

Requires a jailbroken device with Theos. Update the `API_ENDPOINT` in `Tweak.x` or set it via the plist at `/var/mobile/Library/Preferences/com.yourname.phonecontexthook.plist`.

## Deploy

[![Deploy on Railway](https://railway.app/button/deploy)](https://railway.app)

Set the environment variables in your Railway project settings.

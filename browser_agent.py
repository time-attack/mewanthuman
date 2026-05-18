#!/usr/bin/env python3
"""
MeWantHuman — Browser-Use Cloud Web Chat Racing Agent
Uses the browser-use Cloud SDK. No local browser needed.
Outputs JSON-line events to stdout for the Node server.
"""

import asyncio
import json
import sys
import os
import argparse
import urllib.request
import urllib.error
from datetime import datetime


def emit(event_type: str, text: str, **kw):
    sys.stdout.write(json.dumps({
        "type": event_type, "text": text,
        "channel": "webchat",
        "ts": int(datetime.now().timestamp() * 1000),
        **kw,
    }) + "\n")
    sys.stdout.flush()


def search_playbook(query: str, server_port: int = 3000) -> str | None:
    """Query the local server's supermemory search for playbook steps."""
    try:
        url = f"http://localhost:{server_port}/playbooks/search"
        body = json.dumps({"query": query, "limit": 3}).encode()
        req = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            results = data.get("results", [])
            if results:
                steps = []
                for r in results:
                    # v3 format: results[].chunks[].content
                    for chunk in r.get("chunks", []):
                        text = chunk.get("content", "").strip()
                        if text and chunk.get("isRelevant", True):
                            steps.append(text)
                if steps:
                    return "\n---\n".join(steps)
    except Exception:
        pass
    return None


async def run(phone: str, reason: str, session_id: str, playbook_from_server: str | None = None):
    try:
        from browser_use_sdk import AsyncBrowserUse
    except ImportError as exc:
        emit("error", f"Missing dep: {exc}. pip install browser-use-sdk")
        return

    api_key = os.environ.get("BROWSER_USE_API_KEY")
    if not api_key:
        emit("error", "BROWSER_USE_API_KEY not set")
        return

    emit("status", "Connecting to browser-use Cloud...")

    # Use playbook from server if provided, otherwise it was already searched server-side
    playbook = playbook_from_server
    if playbook:
        emit("status", "Using playbook from memory — known steps for this company.")
    else:
        emit("status", "No playbook available — will search from scratch.")

    client = AsyncBrowserUse(api_key=api_key)

    human_found = False

    try:
        # 1. Create cloud browser session
        emit("status", "Creating cloud browser session...")
        session = await client.sessions.create_session()
        cloud_session_id = session.id

        live_url = getattr(session, "live_url", None)
        if live_url:
            emit("live_url", live_url)
            emit("status", "Live browser view ready")

        # 2. If no playbook yet, run a quick identification task first
        if not playbook:
            emit("status", "Identifying company from phone number...")
            id_task = await client.tasks.create_task(
                task=f'Google "{phone}" and tell me the company name. Reply with ONLY the company name, nothing else.',
                llm="claude-sonnet-4-6",
                session_id=cloud_session_id,
                max_steps=3,
            )
            # Poll for identification result
            company_name = None
            for _ in range(20):  # max 60s
                await asyncio.sleep(3)
                try:
                    id_data = await client.tasks.get_task(id_task.id)
                except Exception:
                    continue
                id_status = getattr(id_data, "status", "")
                if id_status in ("finished", "stopped", "error", "timed_out", "failed"):
                    company_name = (getattr(id_data, "output", "") or "").strip()
                    break

            if company_name and len(company_name) < 100:
                emit("status", f"Identified company: {company_name}")
                # Search supermemory by company name
                playbook = search_playbook(f"{company_name} live chat steps human agent")
                if playbook:
                    emit("status", f"Found playbook for {company_name}! Using known steps.")
                else:
                    emit("status", f"No playbook for {company_name} — navigating from scratch.")
            else:
                emit("status", "Could not identify company — navigating from scratch.")

        # 3. Build the main task prompt
        playbook_section = ""
        if playbook:
            playbook_section = f"""
IMPORTANT — KNOWN NAVIGATION STEPS (from memory):
Follow these steps first, they worked before:
{playbook}
---
If these steps don't work or the site has changed, fall back to the general approach below.
"""

        task_text = f"""You are racing to reach a HUMAN customer support agent via live web chat.
A phone call is happening in parallel — speed matters!

Company phone number: {phone}
Customer's issue: "{reason}"
{playbook_section}
Steps:
1. Google "{phone}" to identify the company.
2. Go to their support/contact/help page.
3. Find a live chat widget (chat bubbles, "Chat with us", Intercom/Zendesk/Drift, etc.)
4. Open the chat.
5. If a chatbot answers, escalate aggressively:
   - "I need to speak with a human agent"
   - "Transfer me to a live representative"
   - Click "Talk to a person" / "Live agent" buttons
6. Once connected to a human, explain: "{reason}"

When a REAL human (not bot) responds, include __HUMAN_REACHED__ in your output.
Be fast — every second counts!"""

        # 4. Create main navigation task
        emit("status", "Launching AI browser agent...")
        task = await client.tasks.create_task(
            task=task_text,
            llm="claude-sonnet-4-6",
            session_id=cloud_session_id,
            max_steps=35,
        )
        cloud_task_id = task.id
        emit("status", "Agent is browsing...")

        # 3. Poll task for steps and status
        seen_steps = 0
        while True:
            await asyncio.sleep(3)

            try:
                task_data = await client.tasks.get_task(cloud_task_id)
            except Exception:
                continue

            status = getattr(task_data, "status", "")
            steps = getattr(task_data, "steps", []) or []

            # Emit new steps
            for step in steps[seen_steps:]:
                seen_steps += 1
                goal = getattr(step, "next_goal", "") or ""
                actions = getattr(step, "actions", []) or []
                sc_url = getattr(step, "screenshot_url", None)
                step_num = getattr(step, "number", seen_steps)

                desc = goal or (str(actions[0])[:200] if actions else "Working...")
                emit("action", desc, step=step_num)

                if sc_url:
                    emit("screenshot_url", sc_url, step=step_num)

                # Check for human marker
                full = f"{goal} {actions}"
                if "__HUMAN_REACHED__" in full and not human_found:
                    human_found = True
                    emit("human_reached", "Human agent connected via web chat!")

            # Check completion
            if status in ("finished", "stopped", "error", "timed_out", "failed"):
                output = getattr(task_data, "output", "") or ""
                if "__HUMAN_REACHED__" in str(output) and not human_found:
                    human_found = True
                    emit("human_reached", "Human agent connected via web chat!")
                if status == "error" or status == "failed":
                    emit("error", f"Task {status}: {str(output)[:500]}")
                break

        if human_found:
            emit("completed", f"Web chat reached a human in {seen_steps} steps!")
        else:
            output = getattr(task_data, "output", "") or ""
            emit("completed", f"Web chat finished after {seen_steps} steps. {str(output)[:300]}")

    except Exception as exc:
        emit("error", f"Cloud agent error: {exc}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phone", required=True)
    ap.add_argument("--reason", default="General inquiry")
    ap.add_argument("--session-id", required=True)
    ap.add_argument("--playbook", default=None, help="Pre-fetched playbook steps from supermemory")
    args = ap.parse_args()
    emit("status", f"Web chat agent initializing for {args.phone}...")
    asyncio.run(run(args.phone, args.reason, args.session_id, args.playbook))


if __name__ == "__main__":
    main()

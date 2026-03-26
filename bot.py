import os
from collections import defaultdict, deque
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler
from openai import OpenAI
from dotenv import load_dotenv
from apscheduler.schedulers.background import BackgroundScheduler
import reporter
import agent_setup

load_dotenv()

app = App(token=os.environ["SLACK_BOT_TOKEN"])
client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

# Rolling buffer of last 20 (text, embedding) pairs per channel
channel_history = defaultdict(lambda: deque(maxlen=20))

# Per-channel alignment feature toggle (default: off)
alignment_enabled = defaultdict(lambda: False)

AMBIGUITY_PROMPT = """You are a communication clarity assistant in a Slack channel for an engineering team.
Your job is to detect ambiguity or vagueness in messages.

Look for:
- Vague words with no measurable definition: "fast", "soon", "optimize", "improve", "better", "scalable", "clean"
- Missing specifics: deadlines, ownership, success metrics

If you find an issue, respond in this exact format:
⚠️ Potential ambiguity: '<vague phrase>' → <one clarifying question>

If the message is clear and specific, respond with exactly: CLEAR

Rules:
- Only flag genuine ambiguity, not normal conversation
- One issue at a time — pick the most important one
- Keep the clarifying question short and concrete
- Never be preachy or lecture-y"""

CONTRADICTION_PROMPT = """You are a communication clarity assistant in a Slack channel for an engineering team.

You will receive recent related messages and a NEW message.
Your ONLY job: does the NEW message directly contradict something in the history?

A contradiction means the NEW message makes a decision or states a fact that conflicts with a prior decision or fact.

If yes, respond in this exact format:
🔀 Potential conflict: '<topic>' → <one sentence describing what conflicts>

If no contradiction with the NEW message, respond with exactly: CLEAR

Rules:
- Only flag if the NEW message itself introduces the conflict
- Ignore casual chat, opinions, and unrelated topics
- Never be preachy or lecture-y"""


def get_embedding(text: str) -> list[float]:
    response = client.embeddings.create(
        model="text-embedding-3-small",
        input=text
    )
    return response.data[0].embedding

def cosine_similarity(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = sum(x ** 2 for x in a) ** 0.5
    norm_b = sum(x ** 2 for x in b) ** 0.5
    return dot / (norm_a * norm_b) if norm_a and norm_b else 0.0

def get_relevant_history(channel: str, new_embedding: list[float], threshold: float = 0.4) -> list[str]:
    """Return only messages semantically similar to the new message."""
    relevant = []
    for text, embedding in channel_history[channel]:
        if cosine_similarity(new_embedding, embedding) >= threshold:
            relevant.append(text)
    return relevant

def analyze_ambiguity(text: str) -> str | None:
    response = client.chat.completions.create(
        model="gpt-4o-mini",
        max_tokens=150,
        messages=[
            {"role": "system", "content": AMBIGUITY_PROMPT},
            {"role": "user", "content": text}
        ]
    )
    result = response.choices[0].message.content.strip()
    return None if result == "CLEAR" else result

def analyze_contradiction(relevant_history: list[str], new_message: str) -> str | None:
    if not relevant_history:
        return None
    history_text = "\n".join(f"- {m}" for m in relevant_history)
    user_content = f"Recent related messages:\n{history_text}\n\nNew message: {new_message}"
    response = client.chat.completions.create(
        model="gpt-4o-mini",
        max_tokens=150,
        messages=[
            {"role": "system", "content": CONTRADICTION_PROMPT},
            {"role": "user", "content": user_content}
        ]
    )
    result = response.choices[0].message.content.strip()
    return None if result == "CLEAR" else result

@app.event("message")
def handle_message(event, say):
    if event.get("bot_id"):
        return

    text = event.get("text", "").strip()
    if not text:
        return

    channel = event.get("channel")
    user = event.get("user")

    # Thread replies: only handle if user has an active setup session
    if event.get("thread_ts"):
        session = agent_setup.get_session(user) if user else None
        if session:
            def reply(msg):
                say(text=msg, thread_ts=event["thread_ts"])
            agent_setup.handle_input(user, channel, text, reply)
        return

    channel_type = event.get("channel_type")
    is_dm = channel_type == "im"

    # Route to active setup session before any other checks
    if user and agent_setup.get_session(user):
        agent_setup.handle_input(user, channel, text, say)
        return

    if len(text) < 10:
        return

    # Skip alignment checks if disabled for this channel
    if not alignment_enabled[channel]:
        return

    # Embed the new message
    embedding = get_embedding(text)

    # Check ambiguity
    ambiguity = analyze_ambiguity(text)

    # Check contradiction using only semantically relevant history
    contradiction = None
    if not is_dm:
        relevant = get_relevant_history(channel, embedding)
        contradiction = analyze_contradiction(relevant, text)
        # Store after analysis so we don't compare against itself
        channel_history[channel].append((text, embedding))

    feedback = ambiguity or contradiction
    if feedback:
        if is_dm:
            say(text=feedback)
        else:
            say(text=feedback, thread_ts=event["ts"])


# ── /alignment ──────────────────────────────────────────────────────────────

@app.command("/alignment")
def handle_alignment(ack, say, command):
    ack()
    channel = command["channel_id"]
    arg = command.get("text", "").strip().lower()

    if arg == "on":
        alignment_enabled[channel] = True
        say("✅ Alignment checks *enabled* for this channel. I'll flag ambiguity and contradictions.")
    elif arg == "off":
        alignment_enabled[channel] = False
        say("⏸️ Alignment checks *disabled* for this channel. I'll stay quiet until you turn it back on.")
    else:
        status = "enabled ✅" if alignment_enabled[channel] else "disabled ⏸️ (default)"
        say(f"Alignment checks are currently *{status}*.\nUsage: `/alignment on` or `/alignment off`")


# ── /setupagent ──────────────────────────────────────────────────────────────

@app.command("/setupagent")
def handle_setup_agent(ack, say, command):
    ack()
    user = command["user_id"]
    channel = command["channel_id"]
    text = command.get("text", "").strip()
    agent_setup.handle_input(user, channel, text, say)


# ── /setupagenthelp ──────────────────────────────────────────────────────────

@app.command("/setupagenthelp")
def handle_setup_agent_help(ack, say, command):
    ack()
    say(
        "*🤖 /setupagent — LiveX Agent Setup*\n\n"

        "*Start a new agent (zero-to-live):*\n"
        "```/setupagent account_id: <id> api_key: <key> name: <agent name>```\n"
        "Optional: `desc: <description>` · `clone_from: <agent_id>`\n\n"

        "*Configure an existing agent:*\n"
        "```/setupagent account_id: <id> api_key: <key> agent_id: <pub-xxxx>```\n\n"

        "*Or just run with no args — bot will guide you:*\n"
        "```/setupagent```\n\n"

        "*Steps (automatic, pauses only when input needed):*\n"
        "1. Credentials — account_id + api_key + name or agent_id\n"
        "2. Create agent — creates corpus + agent (skipped if agent_id provided)\n"
        "3. Personality — GPT-generates from venue context, you confirm\n"
        "4. Classifier model — auto-applied, no input needed\n"
        "5. Language models — full 8-language TTS/STT config via built-in template or source agent\n"
        "6. KB upload — paste URLs to add to agent knowledge base (skippable)\n"
        "7. Selfie — GPT-generates image prompt, you confirm; creates + publishes agentflow\n"
        "8. Workflow tool — auto-added if missing\n"
        "9. Publish — goes live\n"
        "10. Verify — confirms all key fields\n\n"

        "*Re-run any step after setup:*\n"
        "```/setupagent fix personality\n"
        "/setupagent fix language_models\n"
        "/setupagent fix kb\n"
        "/setupagent fix selfie\n"
        "/setupagent fix publish\n"
        "/setupagent fix verify```\n\n"

        "*Reset session:*\n"
        "```/setupagent reset```"
    )


# ── /dailyreport ─────────────────────────────────────────────────────────────

@app.command("/dailyreport")
def handle_daily_report(ack, say, command):
    ack()
    say("Pulling airport device data... give me a moment.")
    reporter.run_daily_report(app, channel=command["channel_id"])


if __name__ == "__main__":
    scheduler = BackgroundScheduler()
    scheduled_channel = os.environ.get("DAILY_REPORT_CHANNEL")
    scheduler.add_job(
        lambda: reporter.run_daily_report(app, channel=scheduled_channel),
        trigger="cron",
        hour=10,
        minute=0,
        timezone="America/Los_Angeles",
    )
    scheduler.start()
    print("ClarityBot is running... (daily report scheduled at 10:00 AM PT)")

    handler = SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"])
    handler.start()

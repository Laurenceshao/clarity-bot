import os
from collections import defaultdict, deque
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler
from openai import OpenAI
from dotenv import load_dotenv
from apscheduler.schedulers.background import BackgroundScheduler
import reporter

load_dotenv()

app = App(token=os.environ["SLACK_BOT_TOKEN"])
client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

# Rolling buffer of last 20 (text, embedding) pairs per channel
channel_history = defaultdict(lambda: deque(maxlen=20))

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
    if event.get("thread_ts"):
        return

    text = event.get("text", "").strip()
    if not text or len(text) < 10:
        return

    channel = event.get("channel")
    channel_type = event.get("channel_type")
    is_dm = channel_type == "im"

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

if __name__ == "__main__":
    report_hour = int(os.environ.get("REPORT_HOUR_UTC", "9"))
    scheduler = BackgroundScheduler()
    scheduler.add_job(
        lambda: reporter.run_daily_report(app),
        trigger="cron",
        hour=report_hour,
        minute=0,
        timezone="UTC",
    )
    scheduler.start()
    print(f"ClarityBot is running... (daily report scheduled at {report_hour:02d}:00 UTC)")

    handler = SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"])
    handler.start()

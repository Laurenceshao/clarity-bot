import os
import requests
from datetime import datetime, timezone, timedelta
from openai import OpenAI

client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

API_HOST = "https://api.copilot.livex.ai"
API_KEY = os.environ["LIVEX_API_KEY"]
ACCOUNT_ID = os.environ["LIVEX_ACCOUNT_ID"]

AGENT_IDS = [
    "pub-2c7a2270-1e00-4a56-b677-aa2d2b71e390",
    "pub-4c60026b-66ad-4194-88ae-3afed6345e09",
    "pub-989a2749-1edc-4542-a3d1-0416b71351d2",
]


def fetch_agent_label(agent_id: str) -> str:
    """Fetch agent name + nickname from config API. Falls back to agent_id on error."""
    bare_id = agent_id.removeprefix("pub-")
    url = f"{API_HOST}/api/v1/agent"
    try:
        resp = requests.get(
            url,
            headers={"X-API-KEY": API_KEY},
            params={"account_id": ACCOUNT_ID, "agent_id": bare_id},
            timeout=10,
        )
        if resp.status_code == 200:
            config = resp.json().get("config", resp.json())
            name = config.get("name", "")
            nickname = config.get("nickname", "")
            if name and nickname:
                return f"{name} ({nickname})"
            return name or nickname or agent_id
    except Exception:
        pass
    return agent_id


def fetch_endpoint(agent_id: str, endpoint: str, start_time: str, end_time: str) -> dict:
    url = f"{API_HOST}/api/v1/accounts/{ACCOUNT_ID}/agents/{agent_id}/insight/{endpoint}"
    resp = requests.get(
        url,
        headers={"X-API-KEY": API_KEY},
        params={"start_time": start_time, "end_time": end_time},
        timeout=15,
    )
    if resp.status_code != 200:
        return {}
    return resp.json().get("response", resp.json())


def collect_data() -> list[dict]:
    now = datetime.now(timezone.utc)
    end_time = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    start_time = (now - timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")

    results = []
    for agent_id in AGENT_IDS:
        label = fetch_agent_label(agent_id)
        overview = fetch_endpoint(agent_id, "device-overview", start_time, end_time)
        selfie = fetch_endpoint(agent_id, "selfie-funnel", start_time, end_time)
        intent = fetch_endpoint(agent_id, "intent-understanding", start_time, end_time)
        results.append({
            "name": label,
            "id": agent_id,
            "overview": overview,
            "selfie": selfie,
            "intent": intent,
        })
    return results


def format_pct(val) -> str:
    if val is None:
        return "n/a"
    return f"{float(val):.1f}%"


def format_val(val, suffix="") -> str:
    if val is None:
        return "n/a"
    return f"{val}{suffix}"


def safe_rate(numerator, denominator) -> str:
    try:
        n, d = float(numerator), float(denominator)
        if d == 0:
            return "n/a"
        return f"{n / d * 100:.1f}%"
    except (TypeError, ValueError):
        return "n/a"


def build_data_summary(data: list[dict]) -> str:
    """Rich data block passed to GPT for analysis."""
    lines = []
    for d in data:
        ov = d["overview"]
        sf = d["selfie"]
        it = d["intent"]
        sf_funnel = sf.get("funnel", {}) if sf else {}

        # Device overview
        sessions = ov.get("total_sessions", "n/a")
        conversations = ov.get("total_conversations", "n/a")
        avg_session = ov.get("avg_session_duration_seconds")
        avg_engagement = ov.get("avg_engagement_duration")
        interruption = format_pct(ov.get("interruption_rate"))
        screen_touch = format_pct(ov.get("screen_touch_rate"))
        selfie_adoption = format_pct(ov.get("selfie_feature_rate"))
        agent_timeouts = format_val(ov.get("agent_timeouts"))
        wifi_degraded = format_val(ov.get("wifi_degraded"))
        noise_detected = format_val(ov.get("noise_detected"))

        # Selfie funnel
        sf_started = sf_funnel.get("PhotoCaptureStarted")
        sf_completed = sf_funnel.get("PhotoCaptureCompleted")
        sf_cancelled = sf_funnel.get("PhotoCaptureCancelled")
        sf_error = sf_funnel.get("PhotoCaptureError")
        share_landed = sf_funnel.get("SharePageLanded")
        share_downloaded = sf_funnel.get("SharePageDownloadClicked")
        share_shared = sf_funnel.get("SharePageShareClicked")
        avg_selfie_rating = sf.get("avg_selfie_rating") if sf else None
        share_engaged_pct = format_pct(sf.get("share_page_engaged_percentage")) if sf else "n/a"

        selfie_completion = safe_rate(sf_completed, sf_started)
        share_rate = safe_rate(share_shared, share_landed)
        download_rate = safe_rate(share_downloaded, share_landed)

        # Intent understanding
        total_eval = it.get("total_evaluated") if it else None
        understood = it.get("understood_count") if it else None
        not_understood = it.get("not_understood_count") if it else None
        intent_rate = safe_rate(understood, total_eval)

        lines.append(f"--- {d['name']} ---")
        lines.append(f"Sessions: {sessions} | Conversations: {conversations}")
        lines.append(f"Avg session: {format_val(avg_session, 's')} | Avg engagement: {format_val(avg_engagement, 's')}")
        lines.append(f"Interruption rate: {interruption} | Screen touch rate: {screen_touch}")
        lines.append(f"Agent timeouts: {agent_timeouts} | Wifi degraded: {wifi_degraded} | Noise detected: {noise_detected}")
        lines.append(f"Selfie adoption: {selfie_adoption} | Selfie completion: {selfie_completion}")
        lines.append(f"Selfie started: {sf_started} | Completed: {sf_completed} | Cancelled: {sf_cancelled} | Errors: {sf_error}")
        lines.append(f"Share page: landed {share_landed} | Share rate: {share_rate} | Download rate: {download_rate} | Engaged: {share_engaged_pct}")
        lines.append(f"Avg selfie rating: {format_val(avg_selfie_rating)}")
        lines.append(f"Intent understood: {understood}/{total_eval} ({intent_rate}) | Not understood: {not_understood}")
        lines.append("")
    return "\n".join(lines)


def generate_analysis(data_summary: str) -> str:
    prompt = f"""You are analyzing 24-hour engagement data for 3 airport AI kiosk devices.
Be concise and direct. Focus on signal, not noise.

Rules:
- 4-6 bullet observations
- Prioritize: intent understanding quality, selfie completion/share rates, interruptions, environmental issues
- Distinguish cross-device patterns (likely systemic) from single-device anomalies (likely local)
- If a metric is clearly broken or unusually strong, call it out plainly
- Do not restate raw numbers — the data block already has them
- End with one "Worth watching:" line if anything warrants follow-up
- Tone: direct, sharp, non-preachy

Data:
{data_summary}
"""
    response = client.chat.completions.create(
        model="gpt-4o",
        max_tokens=400,
        messages=[{"role": "user", "content": prompt}]
    )
    return response.choices[0].message.content.strip()


def build_slack_message(data: list[dict], analysis: str) -> str:
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [f"📊 *Airport Device Daily Report* — {date_str} (last 24h)\n"]

    for d in data:
        ov = d["overview"]
        sf = d["selfie"]
        it = d["intent"]
        sf_funnel = sf.get("funnel", {}) if sf else {}

        sessions = ov.get("total_sessions", "n/a")
        avg_session = ov.get("avg_session_duration_seconds")
        avg_dur_str = f"{int(avg_session)}s" if avg_session is not None else "n/a"
        avg_engagement = ov.get("avg_engagement_duration")
        avg_eng_str = f"{int(avg_engagement)}s" if avg_engagement is not None else "n/a"
        interruption = format_pct(ov.get("interruption_rate"))
        selfie_adoption = format_pct(ov.get("selfie_feature_rate"))

        sf_started = sf_funnel.get("PhotoCaptureStarted")
        sf_completed = sf_funnel.get("PhotoCaptureCompleted")
        selfie_completion = safe_rate(sf_completed, sf_started)

        share_landed = sf_funnel.get("SharePageLanded")
        share_shared = sf_funnel.get("SharePageShareClicked")
        share_downloaded = sf_funnel.get("SharePageDownloadClicked")
        share_rate = safe_rate(share_shared, share_landed)
        download_rate = safe_rate(share_downloaded, share_landed)

        total_eval = it.get("total_evaluated") if it else None
        understood = it.get("understood_count") if it else None
        intent_rate = safe_rate(understood, total_eval)

        agent_timeouts = ov.get("agent_timeouts", 0) or 0
        wifi_degraded = ov.get("wifi_degraded", 0) or 0
        noise_detected = ov.get("noise_detected", 0) or 0
        env_issues = []
        if agent_timeouts:
            env_issues.append(f"timeouts: {agent_timeouts}")
        if wifi_degraded:
            env_issues.append(f"wifi: {wifi_degraded}")
        if noise_detected:
            env_issues.append(f"noise: {noise_detected}")
        env_str = " | ".join(env_issues) if env_issues else "none"

        lines.append(f"*{d['name']}*")
        lines.append(f"• Sessions: {sessions} | Session: {avg_dur_str} | Engagement: {avg_eng_str} | Interruption: {interruption}")
        lines.append(f"• Selfie: {selfie_adoption} adoption → {selfie_completion} completion | Share: {share_rate} | Download: {download_rate}")
        lines.append(f"• Intent understood: {intent_rate} ({understood}/{total_eval}) | Env issues: {env_str}")
        lines.append("")

    lines.append("🤖 *Observations:*")
    for line in analysis.split("\n"):
        if line.strip():
            lines.append(line)

    return "\n".join(lines)


def get_bot_channels(app) -> list[str]:
    """Return IDs of all channels the bot is a member of."""
    channel_ids = []
    cursor = None
    while True:
        kwargs = {"types": "public_channel,private_channel", "limit": 200}
        if cursor:
            kwargs["cursor"] = cursor
        resp = app.client.users_conversations(**kwargs)
        for ch in resp["channels"]:
            channel_ids.append(ch["id"])
        cursor = resp.get("response_metadata", {}).get("next_cursor")
        if not cursor:
            break
    return channel_ids


def run_daily_report(app):
    print("[reporter] Collecting device data...")
    data = collect_data()
    data_summary = build_data_summary(data)
    print("[reporter] Generating analysis...")
    analysis = generate_analysis(data_summary)
    message = build_slack_message(data, analysis)

    channels = get_bot_channels(app)
    print(f"[reporter] Posting to {len(channels)} channel(s)...")
    for ch in channels:
        try:
            app.client.chat_postMessage(channel=ch, text=message)
        except Exception as e:
            print(f"[reporter] Failed to post to {ch}: {e}")
    print("[reporter] Done.")

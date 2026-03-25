import os
import requests
from datetime import datetime, timezone, timedelta
from openai import OpenAI

client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

API_HOST = "https://api.copilot.livex.ai"
API_KEY = os.environ["LIVEX_API_KEY"]
ACCOUNT_ID = os.environ["LIVEX_ACCOUNT_ID"]

AGENTS = [
    {"id": "pub-2c7a2270-1e00-4a56-b677-aa2d2b71e390", "name": "Airport Device 1"},
    {"id": "pub-4c60026b-66ad-4194-88ae-3afed6345e09", "name": "Airport Device 2"},
    {"id": "pub-989a2749-1edc-4542-a3d1-0416b71351d2", "name": "Airport Device 3"},
]


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
    for agent in AGENTS:
        overview = fetch_endpoint(agent["id"], "device-overview", start_time, end_time)
        conversion = fetch_endpoint(agent["id"], "conversion-funnel", start_time, end_time)
        results.append({"name": agent["name"], "id": agent["id"], "overview": overview, "conversion": conversion})
    return results


def format_pct(val) -> str:
    if val is None:
        return "n/a"
    return f"{float(val) * 100:.1f}%"


def format_val(val, suffix="") -> str:
    if val is None:
        return "n/a"
    return f"{val}{suffix}"


def build_data_summary(data: list[dict]) -> str:
    lines = []
    for d in data:
        ov = d["overview"]
        cv = d["conversion"]
        funnel = cv.get("funnel", {}) if cv else {}

        sessions = ov.get("total_sessions", "n/a")
        conversations = ov.get("total_conversations", "n/a")
        interruption = format_pct(ov.get("interruption_rate"))
        avg_duration = ov.get("avg_session_duration_seconds")
        avg_dur_str = f"{int(avg_duration)}s" if avg_duration is not None else "n/a"
        selfie_rate = format_pct(ov.get("selfie_feature_rate"))
        wifi_degraded = format_val(ov.get("wifi_degraded"))
        noise_detected = format_val(ov.get("noise_detected"))

        room_connected = funnel.get("RoomConnected", "n/a")
        room_left = funnel.get("RoomLeft", "n/a")
        carousel_shown = funnel.get("ProductCarouselShown", "n/a")
        carousel_clicked = funnel.get("ProductCarouselItemClicked", "n/a")
        qr_shown = funnel.get("ProductQrCodeShown", "n/a")
        qr_scanned = funnel.get("ProductQrCodeScanned", "n/a")
        csat = cv.get("csat_rating") if cv else None
        csat_str = f"{csat:.1f}/5" if csat is not None else "n/a"

        lines.append(f"--- {d['name']} ({d['id']}) ---")
        lines.append(f"Sessions: {sessions} | Conversations: {conversations} | Avg duration: {avg_dur_str}")
        lines.append(f"Interruption rate: {interruption} | Selfie adoption: {selfie_rate}")
        lines.append(f"Wifi degraded: {wifi_degraded} | Noise detected: {noise_detected}")
        lines.append(f"Room connections: {room_connected} → left: {room_left}")
        lines.append(f"Carousel shown: {carousel_shown} | Clicked: {carousel_clicked}")
        lines.append(f"QR shown: {qr_shown} | Scanned: {qr_scanned}")
        lines.append(f"CSAT: {csat_str}")
        lines.append("")
    return "\n".join(lines)


def generate_analysis(data_summary: str) -> str:
    prompt = f"""You are analyzing 24-hour engagement and conversion data for 3 airport AI kiosk devices.
Be concise. Focus on what's worth noticing: meaningful changes, anomalies, or patterns across devices.

Rules:
- 3-5 bullet observations max
- Flag if engagement or conversion looks unusually low or high
- Note cross-device patterns vs single-device anomalies
- Mention any environmental issues (wifi degraded, noise detected) that may explain performance
- Do not restate raw numbers — the data block already has them
- End with one "Worth watching" line if anything warrants follow-up
- Tone: direct and professional, not preachy

Data:
{data_summary}
"""
    response = client.chat.completions.create(
        model="gpt-4o",
        max_tokens=300,
        messages=[
            {"role": "user", "content": prompt}
        ]
    )
    return response.choices[0].message.content.strip()


def build_slack_message(data: list[dict], analysis: str) -> str:
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [f"📊 *Airport Device Daily Report* — {date_str} (last 24h)\n"]

    for d in data:
        ov = d["overview"]
        cv = d["conversion"]
        funnel = cv.get("funnel", {}) if cv else {}

        sessions = ov.get("total_sessions", "n/a")
        avg_duration = ov.get("avg_session_duration_seconds")
        avg_dur_str = f"{int(avg_duration)}s" if avg_duration is not None else "n/a"
        interruption = format_pct(ov.get("interruption_rate"))
        selfie_rate = format_pct(ov.get("selfie_feature_rate"))
        qr_shown = funnel.get("ProductQrCodeShown", "n/a")
        qr_scanned = funnel.get("ProductQrCodeScanned", "n/a")
        carousel_clicked = funnel.get("ProductCarouselItemClicked", "n/a")

        lines.append(f"*{d['name']}*")
        lines.append(f"• Sessions: {sessions} | Avg duration: {avg_dur_str} | Interruption: {interruption}")
        lines.append(f"• Selfie adoption: {selfie_rate} | QR scans: {qr_scanned}/{qr_shown} | Carousel clicks: {carousel_clicked}")
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

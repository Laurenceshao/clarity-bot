"""
Real script-execution engine for /setupagent Slack command.

Follows avatai-agent-setup SKILL.md steps in order, running actual livex-config
shell scripts via subprocess and posting step-by-step progress to Slack.

Usage (from bot.py):
    agent_setup.handle_input(user_id, channel_id, text, post_fn)

New agent (zero-to-live):
    Provide account_id + api_key + agent name → bot creates agent then configures it.

Existing agent:
    Provide account_id + api_key + agent_id → bot skips creation, goes straight to config.

Post-fix:
    /setupagent fix personality
    /setupagent fix language_models
    /setupagent fix kb
    /setupagent fix selfie
    /setupagent fix publish
"""

import os
import re
import json
import subprocess
import tempfile
import uuid
from dataclasses import dataclass, field
from typing import Optional, Callable

# ── config ────────────────────────────────────────────────────────────────────

_DEFAULT_SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts")
SCRIPTS_DIR = os.path.expanduser(
    os.environ.get("LIVEX_SCRIPTS_PATH", _DEFAULT_SCRIPTS)
)
PROFILES_FILE = os.path.expanduser("~/.config/livex-api/profiles")

CLASSIFIER_MODELS = [
    "groq-openai/gpt-oss-120b",
    "gpt-4.1-2025-04-14",
]

# 8-language Lyra template — stt_prompt placeholder is {STT_KEYWORDS}
LANGUAGE_MODELS_TEMPLATE = [
    {
        "description": "Friendly adult female voice for daily conversation",
        "fluent_language_codes": "en",
        "language_code": "en",
        "stt_provider": "whisper",
        "stt_model_id": "whisper-large-v3",
        "stt_prompt": "{STT_KEYWORDS}",
        "tts_provider": "cartesia",
        "tts_model_id": "sonic-3-2025-10-27",
        "tts_voice_id": "6f84f4b8-58a2-430c-8c79-688dad597532",
        "tts_voice_name": "Emily",
        "tts_speak_speed": 1,
        "tts_cache_mode": "all",
        "voice_gender": "female",
        "voice_age": "Mid-Age",
    },
    {
        "description": "Friendly adult female voice for daily conversation",
        "language_code": "es",
        "stt_provider": "whisper",
        "stt_model_id": "whisper-large-v3",
        "stt_prompt": "{STT_KEYWORDS}",
        "tts_provider": "cartesia",
        "tts_model_id": "sonic-3-2025-10-27",
        "tts_voice_id": "d3793b7b-4996-409c-9d59-96dd09f47717",
        "tts_voice_name": "Renata",
        "tts_speak_speed": 1.1,
        "tts_cache_mode": "all",
        "voice_gender": "female",
        "voice_age": "Mid-Age",
    },
    {
        "description": "Calm professional mid-age adult female voice",
        "fluent_language_codes": "zh,zh-TW,ja",
        "language_code": "ja",
        "stt_provider": "whisper",
        "stt_model_id": "whisper-large-v3",
        "stt_prompt": "{STT_KEYWORDS}",
        "tts_provider": "openai",
        "tts_model_id": "gpt-4o-mini-tts",
        "tts_voice_id": "shimmer",
        "tts_voice_name": "Chloe",
        "tts_speak_speed": 1,
        "tts_cache_mode": "all",
        "voice_gender": "female",
        "voice_age": "Mid-Age",
    },
    {
        "language_code": "zh",
        "stt_provider": "whisper",
        "stt_model_id": "whisper-large-v3",
        "stt_prompt": "{STT_KEYWORDS}",
        "tts_provider": "cartesia",
        "tts_model_id": "sonic-3-2025-10-27",
        "tts_voice_id": "bf32f849-7bc9-4b91-8c62-954588efcc30",
        "tts_voice_name": "Chinese Lisa",
        "tts_speak_speed": 1.2,
        "tts_cache_mode": "all",
        "voice_gender": "female",
    },
    {
        "description": "Friendly adult female voice for daily conversation",
        "language_code": "fr",
        "stt_provider": "whisper",
        "stt_model_id": "whisper-large-v3",
        "stt_prompt": "{STT_KEYWORDS}",
        "tts_provider": "cartesia",
        "tts_model_id": "sonic-3-2025-10-27",
        "tts_voice_id": "65b25c5d-ff07-4687-a04c-da2f43ef6fa9",
        "tts_voice_name": "Emily",
        "tts_speak_speed": 1,
        "tts_cache_mode": "all",
        "voice_gender": "female",
        "voice_age": "Mid-Age",
    },
    {
        "description": "Middle-aged female voice with calm tone",
        "fluent_language_codes": "de",
        "language_code": "de",
        "stt_provider": "whisper",
        "stt_model_id": "whisper-large-v3",
        "stt_prompt": "{STT_KEYWORDS}",
        "tts_provider": "elevenlabs",
        "tts_model_id": "eleven_flash_v2_5",
        "tts_voice_id": "pFZP5JQG7iQjIQuC4Bku",
        "tts_voice_name": "Anna",
        "tts_speak_speed": 1,
        "tts_cache_mode": "all",
        "voice_gender": "female",
        "voice_age": "Mid-Age",
    },
    {
        "description": "Warm, clear, and reassuring",
        "fluent_language_codes": "ar",
        "language_code": "ar",
        "stt_provider": "whisper",
        "stt_model_id": "whisper-large-v3",
        "stt_prompt": "{STT_KEYWORDS}",
        "tts_provider": "elevenlabs",
        "tts_model_id": "eleven_flash_v2_5",
        "tts_voice_id": "mRdG9GYEjJmIzqbYTidv",
        "tts_voice_name": "Salma",
        "tts_speak_speed": 1,
        "tts_cache_mode": "all",
        "voice_gender": "female",
        "voice_age": "Young",
    },
    {
        "description": "Young adult female voice for Korean",
        "fluent_language_codes": "ko",
        "language_code": "ko",
        "stt_provider": "whisper",
        "stt_model_id": "whisper-large-v3",
        "stt_prompt": "{STT_KEYWORDS}",
        "tts_provider": "cartesia",
        "tts_model_id": "sonic-3-2025-10-27",
        "tts_voice_id": "29e5f8b4-b953-4160-848f-40fae182235b",
        "tts_voice_name": "Emily",
        "tts_speak_speed": 1,
        "tts_cache_mode": "all",
        "voice_gender": "female",
        "voice_age": "Mid-Age",
    },
]

STEPS = [
    "credentials",      # 1 - parse account_id + api_key; agent_id optional
    "create_agent",     # 2 - create new agent if no agent_id given; else read existing config
    "personality",      # 3 - GPT-generate personality / write name+nickname+role
    "classifier_model", # 4 - business_voice.classifier_model (auto)
    "language_models",  # 5 - full TTS/STT patch via --full-write
    "kb",               # 6 - KB URL / doc upload
    "selfie",           # 7 - GPT selfie prompt + template + agentflow
    "workflow_tool",    # 8 - ensure workflow_tool in tool_agent.tools
    "publish",          # 9 - publish
    "verify",           # 10 - re-read + confirm
]

FIXABLE_STEPS = {
    "create_agent": "create_agent",
    "personality": "personality",
    "language_models": "language_models",
    "lm": "language_models",
    "kb": "kb",
    "selfie": "selfie",
    "workflow_tool": "workflow_tool",
    "publish": "publish",
    "verify": "verify",
}


# ── session ───────────────────────────────────────────────────────────────────

@dataclass
class SetupSession:
    user_id: str
    channel_id: str
    step: int = 0           # index into STEPS
    waiting_for: str = ""   # "" = not waiting

    # Credentials
    agent_id: str = ""        # empty = create new
    bare_id: str = ""         # no pub- prefix
    account_id: str = ""
    api_key: str = ""
    profile_name: str = ""
    config: dict = field(default_factory=dict)
    clone_from: str = ""      # source agent_id to clone config from
    agent_desc: str = ""      # description for new agent creation

    # Agent context (collected for personality + selfie generation)
    agent_name: str = ""
    agent_role: str = ""    # e.g. "AI Concierge"
    venue_name: str = ""
    organizer: str = ""
    context_extra: str = ""

    # Personality
    personality_text: str = ""

    # Language models
    lm_custom_source: str = ""   # source agent_id if user provides one
    lm_choice_made: bool = False # True once user has answered template vs custom
    stt_keywords: str = ""

    # KB
    kb_urls: list = field(default_factory=list)
    kb_skip: bool = False

    # Selfie
    selfie_choice_made: bool = False
    do_selfie: bool = False
    selfie_prompt: str = ""
    selfie_provider: str = "xai"
    selfie_model: str = "grok-imagine-image"
    counter_key: str = ""
    watermark_logo: str = ""
    image_config_str: str = ""


_sessions: dict[str, SetupSession] = {}


def get_session(user_id: str) -> Optional[SetupSession]:
    return _sessions.get(user_id)


def new_session(user_id: str, channel_id: str) -> SetupSession:
    s = SetupSession(user_id=user_id, channel_id=channel_id)
    _sessions[user_id] = s
    return s


def clear_session(user_id: str):
    _sessions.pop(user_id, None)


# ── subprocess ────────────────────────────────────────────────────────────────

def _run(cmd: list[str]) -> tuple[int, str, str]:
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _script(name: str) -> str:
    return os.path.join(SCRIPTS_DIR, name)


def _write_tmp(data: dict) -> str:
    """Write JSON to a temp file, return path."""
    f = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
    json.dump(data, f)
    f.close()
    return f.name


# ── profile bootstrap ─────────────────────────────────────────────────────────

LIVEX_API_HOST = "https://api.copilot.livex.ai"

def _ensure_profile(session: SetupSession) -> str:
    profile_name = f"prd-setup-{session.user_id[:8]}"
    os.makedirs(os.path.dirname(PROFILES_FILE), exist_ok=True)
    lines = []
    if os.path.exists(PROFILES_FILE):
        with open(PROFILES_FILE) as f:
            lines = [l for l in f.readlines() if not l.startswith(profile_name + "\t")]
    lines.append(f"{profile_name}\t{session.api_key}\t{session.account_id}\t{LIVEX_API_HOST}\n")
    with open(PROFILES_FILE, "w") as f:
        f.writelines(lines)
    return profile_name


def _remove_profile(session: SetupSession):
    if not session.profile_name or not os.path.exists(PROFILES_FILE):
        return
    with open(PROFILES_FILE) as f:
        lines = [l for l in f.readlines() if not l.startswith(session.profile_name + "\t")]
    with open(PROFILES_FILE, "w") as f:
        f.writelines(lines)
    # Remove empty profiles file if nothing left
    if os.path.exists(PROFILES_FILE) and os.path.getsize(PROFILES_FILE) == 0:
        os.unlink(PROFILES_FILE)


# ── parsing ───────────────────────────────────────────────────────────────────

def _parse_credentials(text: str) -> dict:
    result = {}
    # agent_id (optional)
    m = re.search(r'agent[_\s]?id[:\s]+([a-zA-Z0-9\-]+)', text, re.I)
    if m:
        result["agent_id"] = m.group(1).strip()
    m2 = re.search(r'(pub-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', text, re.I)
    if m2 and "agent_id" not in result:
        result["agent_id"] = m2.group(1).strip()
    # account_id
    m = re.search(r'account[_\s]?id[:\s]+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', text, re.I)
    if m:
        result["account_id"] = m.group(1).strip()
    # api_key
    m = re.search(r'api[_\s]?key[:\s]+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', text, re.I)
    if m:
        result["api_key"] = m.group(1).strip()
    # agent name (for new agent creation)
    m = re.search(r'(?:agent[_\s]?)?name[:\s]+"([^"]+)"', text, re.I)
    if not m:
        m = re.search(r'(?:agent[_\s]?)?name[:\s]+(.+?)(?:\n|$|,)', text, re.I)
    if m:
        result["agent_name"] = m.group(1).strip()
    # clone_from
    m = re.search(r'clone[_\s]?from[:\s]+([a-zA-Z0-9\-]+)', text, re.I)
    if m:
        result["clone_from"] = m.group(1).strip()
    # desc
    m = re.search(r'desc(?:ription)?[:\s]+"([^"]+)"', text, re.I)
    if not m:
        m = re.search(r'desc(?:ription)?[:\s]+(.+?)(?:\n|$)', text, re.I)
    if m:
        result["agent_desc"] = m.group(1).strip()
    return result


# ── GPT helpers ───────────────────────────────────────────────────────────────

def _gpt(system: str, user: str, max_tokens: int = 800) -> str:
    """Call OpenAI. Import lazily so module loads even without openai installed."""
    from openai import OpenAI
    c = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
    resp = c.chat.completions.create(
        model="gpt-4o-mini",
        max_tokens=max_tokens,
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
    )
    return resp.choices[0].message.content.strip()


def _generate_personality(session: SetupSession) -> str:
    system = (
        "You are writing a LiveX AI agent personality config field. "
        "Output only the personality string — no JSON wrapper, no markdown. "
        "Follow this exact structure:\n\n"
        "###Task###\n"
        "You are {name}, the {role} powered by LiveX AI.\n\n"
        "###PERSONA###\n"
        "NAME: {name}\n"
        "ROLE: {role}\n"
        "VENUE: {venue}\n"
        "POWERED BY: LiveX AI\n\n"
        "###PERSONALITY###\n"
        "Warm, professional, knowledgeable, and genuinely helpful. "
        "You make every interaction feel effortless.\n\n"
        "###VOICE STYLE###\n"
        "- Concise, natural spoken sentences\n"
        "- End responses with an inviting follow-up question\n"
        "- No markdown, no emoji, plain text only\n\n"
        "###WHAT YOU HELP WITH###\n"
        "[Derive from the agent context provided]\n\n"
        "###HANDLING OFF-TOPIC###\n"
        "Acknowledge briefly, redirect: \"I specialize in {venue}. "
        "Is there something about that I can help with?\"\n\n"
        "###DEFAULT FALLBACK###\n"
        "If unsure: \"Great question — let me connect you with our team for that.\""
    )
    user = (
        f"Agent name: {session.agent_name}\n"
        f"Role: {session.agent_role}\n"
        f"Venue/Brand: {session.venue_name}\n"
        f"Organizer: {session.organizer}\n"
        f"Additional context: {session.context_extra}"
    )
    return _gpt(system, user, max_tokens=600)


def _generate_selfie_prompt(session: SetupSession) -> str:
    system = (
        "You are writing an image generation prompt for an AI selfie kiosk agent. "
        "The prompt is used by grok-imagine-image to transform a selfie into a "
        "stylized animated illustration set at a specific venue. "
        "Output only the image prompt text — no JSON, no markdown headers.\n\n"
        "The prompt must follow this exact structure in order:\n"
        "1. ROLE — brief identity statement for the image model\n"
        "2. Description of the venue scene and aesthetic\n"
        "3. CORE STYLE block — animated illustration, no photorealism, cinematic\n"
        "4. SUBJECT & SELFIE LOGIC (STRICT) — preserve likeness, no invented subjects, preserve multi-subject count\n"
        "5. SKIN TONE & LIKENESS (STRICT) — exact match, no lightening/darkening\n"
        "6. SCENE & ENVIRONMENT — venue details, what to include\n"
        "7. CROWD & ENERGY — people, atmosphere, vibe\n"
        "8. LIGHTING — primary + accent palette\n"
        "9. TEXT OVERLAY — small top badge with venue name + rotating captions that fit the brand\n"
        "10. FINAL FEEL — one paragraph\n"
        "11. FINAL SELF-VALIDATION PASS (MANDATORY) — subject recognizability, skin tone, no offensive content\n"
    )
    user = (
        f"Venue/Brand: {session.venue_name}\n"
        f"Organizer: {session.organizer}\n"
        f"Agent name: {session.agent_name}\n"
        f"Context: {session.context_extra}\n\n"
        "Generate a full, production-ready selfie image prompt for this venue."
    )
    return _gpt(system, user, max_tokens=2000)


# ── step implementations ──────────────────────────────────────────────────────

def _step_credentials(session: SetupSession, text: str, post: Callable) -> bool:
    creds = _parse_credentials(text)
    if creds.get("agent_id"):
        session.agent_id = creds["agent_id"]
        session.bare_id = session.agent_id.removeprefix("pub-")
    if creds.get("account_id"):
        session.account_id = creds["account_id"]
    if creds.get("api_key"):
        session.api_key = creds["api_key"]
    if creds.get("agent_name") and not session.agent_name:
        session.agent_name = creds["agent_name"]
    if creds.get("clone_from"):
        session.clone_from = creds["clone_from"]
    if creds.get("agent_desc"):
        session.agent_desc = creds["agent_desc"]

    missing = []
    if not session.account_id:
        missing.append("`account_id`")
    if not session.api_key:
        missing.append("`api_key`")
    # Need either agent_id (existing) or agent name (new)
    if not session.agent_id and not session.agent_name:
        missing.append("`agent_id` (existing) or `name` (new agent)")
    if missing:
        post(f"❓ Step 1 — credentials: still need {', '.join(missing)}")
        session.waiting_for = "credentials"
        return False

    session.profile_name = _ensure_profile(session)
    mode = "existing agent" if session.agent_id else f"new agent `{session.agent_name}`"
    post(f"✅ Step 1 — credentials: ready ({mode}, profile `{session.profile_name}`)")
    session.waiting_for = ""
    return True


def _step_create_agent(session: SetupSession, post: Callable) -> bool:
    """If agent_id already provided, just read the config. Otherwise create a new agent."""
    if session.agent_id:
        # Existing agent — just read config
        rc, out, err = _run([
            _script("livex-config-read.sh"), session.agent_id,
            "--profile", session.profile_name,
        ])
        if rc != 0:
            post(f"❌ Step 2 — read config: {err or out}\n→ Check agent_id and credentials.")
            return False
        try:
            session.config = json.loads(out)
        except json.JSONDecodeError:
            post("❌ Step 2 — read config: could not parse JSON.")
            return False
        existing_name = session.config.get("name") or session.config.get("nickname") or session.agent_id
        post(f"⏭️ Step 2 — create agent: skipped (using existing `{existing_name}`)")
        # Populate agent_name from config if not set
        if not session.agent_name:
            session.agent_name = session.config.get("name") or session.config.get("nickname") or ""
        return True

    # Create new agent
    post(f"⏳ Step 2 — creating agent `{session.agent_name}`…")
    cmd = [
        _script("livex-agent-create.sh"),
        "--name", session.agent_name,
        "--profile", session.profile_name,
        "--yes",
    ]
    if session.agent_desc:
        cmd += ["--desc", session.agent_desc]
    if session.clone_from:
        cmd += ["--from", session.clone_from]

    rc, out, err = _run(cmd)
    if rc != 0:
        post(f"❌ Step 2 — create agent: {err or out}")
        return False

    # Script outputs bare agent_id on last stdout line
    bare_id = out.strip().splitlines()[-1].strip()
    if not re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', bare_id):
        post(f"❌ Step 2 — create agent: unexpected output (expected UUID, got `{bare_id}`)")
        return False

    session.bare_id = bare_id
    session.agent_id = f"pub-{bare_id}"

    # Read freshly created config
    rc2, out2, err2 = _run([
        _script("livex-config-read.sh"), session.agent_id,
        "--profile", session.profile_name,
    ])
    if rc2 == 0:
        try:
            session.config = json.loads(out2)
        except json.JSONDecodeError:
            pass

    post(
        f"✅ Step 2 — agent created!\n"
        f"  • `agent_id`: `{session.agent_id}`\n"
        f"  • `bare_id`: `{session.bare_id}`"
        + (f"\n  • cloned from: `{session.clone_from}`" if session.clone_from else "")
    )
    return True


def _step_personality(session: SetupSession, text: str, post: Callable) -> bool:
    # Collecting context
    if session.waiting_for == "personality_context":
        # Parse free-form: name, role, venue, organizer
        lines = text.strip().splitlines()
        for line in lines:
            line = line.strip()
            kv = re.match(r'^(name|role|venue|organizer|context)[:\s]+(.+)', line, re.I)
            if kv:
                key, val = kv.group(1).lower(), kv.group(2).strip()
                if key == "name":
                    session.agent_name = val
                elif key == "role":
                    session.agent_role = val
                elif key == "venue":
                    session.venue_name = val
                elif key == "organizer":
                    session.organizer = val
                elif key == "context":
                    session.context_extra = val
        # If we can't parse structured, treat the whole text as context
        if not session.agent_name and not session.venue_name:
            session.context_extra = text.strip()
        session.waiting_for = ""

    if session.waiting_for == "personality_confirm":
        if text.strip().lower() in ("yes", "y", "ok", "looks good", "good", "apply"):
            # Apply
            pass
        elif text.strip().lower().startswith(("no", "edit", "change", "redo")):
            post("Paste your revised personality text (or `generate` to re-generate):")
            session.waiting_for = "personality_manual"
            return False
        else:
            # Treat as edited personality text
            session.personality_text = text.strip()
            session.waiting_for = ""

    if session.waiting_for == "personality_manual":
        if text.strip().lower() == "generate":
            session.personality_text = ""
        else:
            session.personality_text = text.strip()
        session.waiting_for = ""

    # First entry — ask for context if not already collected
    if not session.agent_name and not session.venue_name and not session.context_extra:
        # Try to pull from existing config
        session.agent_name = session.config.get("name") or session.config.get("nickname") or ""
        if not session.agent_name:
            post(
                "❓ Step 2 — personality: provide agent context (paste as `key: value` pairs):\n"
                "• `name` — agent name (e.g. `Aria`)\n"
                "• `role` — role (e.g. `Hotel Concierge`)\n"
                "• `venue` — venue/brand (e.g. `Hilton Santa Clara`)\n"
                "• `organizer` — organizer (e.g. `Hilton Hotels`)\n"
                "• `context` — any extra context (optional)\n\n"
                "_Or paste a one-liner description and I'll extract what I can._"
            )
            session.waiting_for = "personality_context"
            return False

    # Generate if not already set
    if not session.personality_text:
        post("⏳ Step 2 — generating personality…")
        try:
            session.personality_text = _generate_personality(session)
        except Exception as e:
            post(f"❌ Step 2 — personality generation failed: {e}")
            return False

        preview = session.personality_text[:400].replace("\n", " ↵ ")
        post(
            f"✅ Step 2 — personality generated. Preview:\n```{preview}…```\n"
            f"Reply `yes` to apply, `no` to edit, or paste replacement text."
        )
        session.waiting_for = "personality_confirm"
        return False

    # Apply personality + name/nickname
    update = {"personality": session.personality_text}
    if session.agent_name:
        existing_name = session.config.get("name", "")
        existing_nick = session.config.get("nickname", "")
        if not existing_name:
            update["name"] = session.agent_name
        if not existing_nick:
            update["nickname"] = re.sub(r'\s+', '-', session.agent_name.lower())
    if session.agent_role:
        update["role"] = session.agent_role

    tmp = _write_tmp(update)
    try:
        rc, out, err = _run([
            _script("livex-config-update.sh"), session.agent_id,
            "--profile", session.profile_name,
            f"@{tmp}", "--yes",
        ])
    finally:
        os.unlink(tmp)

    if rc != 0:
        post(f"❌ Step 2 — personality apply: {err or out}")
        return False

    post(f"✅ Step 2 — personality applied (name: `{session.agent_name}`, role: `{session.agent_role}`)")
    session.waiting_for = ""
    return True


def _step_classifier_model(session: SetupSession, post: Callable) -> bool:
    payload = json.dumps({"business_voice": {"classifier_model": CLASSIFIER_MODELS}})
    rc, out, err = _run([
        _script("livex-config-update.sh"), session.agent_id,
        "--profile", session.profile_name,
        payload, "--yes",
    ])
    if rc != 0:
        post(f"❌ Step 3 — classifier_model: {err or out}")
        return False
    post(f"✅ Step 3 — classifier_model: `{', '.join(CLASSIFIER_MODELS)}`")
    return True


def _build_language_models(stt_keywords: str) -> list:
    prompt = f"Keywords include LiveX AI and {stt_keywords}"
    return [
        {**entry, "stt_prompt": prompt}
        for entry in LANGUAGE_MODELS_TEMPLATE
    ]


def _step_language_models(session: SetupSession, text: str, post: Callable) -> bool:
    """Full TTS/STT language_models patch via --full-write."""

    if session.waiting_for == "lm_source_choice":
        low = text.strip().lower()
        if low in ("template", "default", "lyra", "n", "no"):
            session.lm_custom_source = ""
        else:
            session.lm_custom_source = text.strip()
        session.lm_choice_made = True
        session.waiting_for = ""

    if session.waiting_for == "stt_keywords":
        session.stt_keywords = text.strip()
        session.waiting_for = ""

    # First entry for this step — ask only if choice hasn't been made yet
    if not session.lm_choice_made and session.waiting_for == "":
        post(
            "❓ Step 4 — language_models: do you have a source agent to copy TTS/STT config from?\n"
            "• Reply with a source `agent_id` to copy it exactly\n"
            "• Reply `template` to use the built-in 8-language Lyra config (recommended)\n\n"
            "_Either way, I'll ask for STT keywords next._"
        )
        session.waiting_for = "lm_source_choice"
        return False

    if not session.stt_keywords:
        post(
            "❓ Step 4 — language_models: what STT prompt keywords should I use?\n"
            "_e.g. `LiveX AI, Aria, Hilton Santa Clara, Levi's Stadium, concierge`_"
        )
        session.waiting_for = "stt_keywords"
        return False

    # Build the language_models array
    if session.lm_custom_source:
        # Read from source agent
        rc, out, err = _run([
            _script("livex-config-read.sh"), session.lm_custom_source,
            "--profile", session.profile_name,
            "--full",
        ])
        if rc != 0:
            post(f"❌ Step 4 — lm source read: {err or out}")
            return False
        try:
            src_cfg = json.loads(out)
        except json.JSONDecodeError:
            post("❌ Step 4 — lm source read: could not parse JSON.")
            return False
        lm_array = src_cfg.get("avatai", {}).get("language_models") or src_cfg.get("voice", {}).get("language_models") or []
        if not lm_array:
            post(f"⚠️ Step 4 — source agent has no language_models; falling back to built-in template.")
            lm_array = _build_language_models(session.stt_keywords)
        else:
            # Patch stt_prompt on each entry
            kw = f"Keywords include LiveX AI and {session.stt_keywords}"
            lm_array = [{**e, "stt_prompt": kw} for e in lm_array]
    else:
        lm_array = _build_language_models(session.stt_keywords)

    payload = {"avatai": {"language_models": lm_array}, "voice": {"language_models": lm_array}}
    tmp = _write_tmp(payload)
    try:
        rc, out, err = _run([
            _script("livex-config-update.sh"), session.bare_id,
            "--profile", session.profile_name,
            f"@{tmp}", "--full-write", "--yes",
        ])
    finally:
        os.unlink(tmp)

    if rc != 0:
        post(f"❌ Step 4 — language_models --full-write: {err or out}")
        return False

    post(
        f"✅ Step 4 — language_models: {len(lm_array)} entries patched via --full-write\n"
        f"  stt_prompt: `Keywords include LiveX AI and {session.stt_keywords}`"
    )
    session.waiting_for = ""
    return True


def _step_kb(session: SetupSession, text: str, post: Callable) -> bool:
    """Upload KB URLs (or docs). Asks for URLs, calls livex-kb-upload.sh per URL."""

    if session.waiting_for == "kb_urls":
        low = text.strip().lower()
        if low in ("skip", "none", "no", "n"):
            session.kb_skip = True
            session.waiting_for = ""
        else:
            # Slack wraps URLs as <https://...> or <https://...|display text>
            # Extract actual URLs from both wrapped and plain forms
            slack_urls = re.findall(r'<(https?://[^|>]+)(?:\|[^>]*)?>',  text)
            plain_urls = re.findall(r'(?<![<|])(https?://\S+)', text)
            all_urls = slack_urls + [u for u in plain_urls if u not in slack_urls]
            session.kb_urls = [u.strip('.,') for u in all_urls if u.strip('.,')]
            if not session.kb_urls:
                post("❓ Step 5 — KB: no valid URLs found. Paste URLs (one per line) or reply `skip`.")
                return False
            session.waiting_for = ""

    if session.kb_skip:
        post("⏭️ Step 5 — KB: skipped.")
        return True

    if not session.kb_urls:
        post(
            "❓ Step 5 — KB upload: provide URLs to add to the agent's knowledge base.\n"
            "• Paste one or more URLs (one per line or comma-separated)\n"
            "• Sitemaps work too (e.g. `https://example.com/sitemap.xml`)\n"
            "• Reply `skip` to skip KB upload"
        )
        session.waiting_for = "kb_urls"
        return False

    # Upload each URL
    results = []
    for url in session.kb_urls:
        rc, out, err = _run([
            _script("livex-kb-upload.sh"), session.agent_id,
            "--url", url,
            "--profile", session.profile_name,
            "--yes",
        ])
        status = "✅" if rc == 0 else "❌"
        detail = out.split("\n")[0][:80] if out else (err.split("\n")[0][:80] if err else "")
        results.append(f"  {status} `{url}` — {detail}")

    post("✅ Step 5 — KB upload:\n" + "\n".join(results))
    session.waiting_for = ""
    return True


def _build_selfie_agentflow(session: SetupSession) -> dict:
    """Build a full production-ready selfie agentflow from the moscone template pattern."""
    venue = session.venue_name or session.agent_name or "this location"
    agent_name = session.agent_name or "your AI agent"

    start_step_id = str(uuid.uuid4())
    end_step_id = "566b64c0"  # stable ID matching template

    camera_msg = (
        f"Call the `camera_command_tool` for the user to open the camera for them, "
        f"so they can take the selfie. Please translate `messages`, `processing_messages` and "
        f"`image_generation_completion_messages` based on user's language. Call with the following parameters:\n"
        f"  - `**`messages`**`: `[\"Hold on tight, I'll take the picture at the end of the countdown! Big Smile!\", "
        f"\"Get ready to smile big! I'll snap the picture after the countdown.\", "
        f"\"Hold still — I'll take the photo after the countdown. Say cheese!\"]`\n"
        f"  - `**`auto_execute_on_frontend`**`: `True`\n"
        f"  - `**`button_text`**`: `Open Camera`\n"
        f"  - `**`camera_command`**`: `capture_image_and_submit`\n"
        f"  - `**`target_url`**`: `https://chat.copilot.livex.ai/api/v1/selfie/generate`\n"
        f"  - `**`processing_messages`**`: `[\"Awesome! We're working some magic on your image. "
        f"Our creative engine is enhancing every detail to deliver a stunning result. "
        f"This experience is powered by LiveX AI.\"]`\n"
        f"  - `**`image_generation_completion_messages`**`: `[\"Your pic is ready! Scan the QR code to save and share it. "
        f"Click Continue or this session will end in 45 seconds.\"]`"
    )

    image_config = session.image_config_str or json.dumps({
        "message": f"Just met {agent_name} at {venue}! Powered by @livex_ai #LiveXAI",
        "tags": ["LiveXAI", re.sub(r'\s+', '', venue)],
    })

    flow = {
        "workflow_name": f"Feature: Selfie, {venue}",
        "type": "ai-based",
        "start_step_id": start_step_id,
        "steps": [
            {
                "step_id": start_step_id,
                "description": "Start",
                "operation_id": "internalProcess",
                "parameters": {
                    "field": {},
                    "messages": [{"text": camera_msg}],
                    "tools": [],
                },
                "next": [
                    {
                        "condition": "Immediate",
                        "target_step_id": end_step_id,
                        "use_condition_as_option": False,
                    }
                ],
            },
            {
                "step_id": end_step_id,
                "description": "End",
                "operation_id": "endOfWorkflow",
                "parameters": {
                    "end_of_workflow": {"success": True},
                    "field": {},
                    "messages": [{"text": f"Enjoy your visit to {venue}! How else can I help?"}],
                    "tools": [],
                },
                "next": [],
            },
        ],
        "workflow_config": {
            "disable_button": True,
            "disable_question_suggestion": True,
            "enable_support_button": False,
            "global_tools": [
                "document_retrieval_tool",
                "end_of_workflow",
                "external_api_call_tool",
                "camera_command_tool",
            ],
            "image_prompt": session.selfie_prompt,
            "image_config": image_config,
            "image_counter_key": session.counter_key,
        },
    }

    if session.watermark_logo:
        flow["workflow_config"]["image_watermark_logo"] = session.watermark_logo

    return flow


def _step_selfie(session: SetupSession, text: str, post: Callable) -> bool:
    """Selfie: generate prompt from context, confirm, set template + create agentflow."""

    if session.waiting_for == "selfie_confirm":
        low = text.strip().lower()
        if low in ("no", "n", "skip"):
            session.do_selfie = False
            session.selfie_choice_made = True
            post("⏭️ Step 6 — selfie: skipped.")
            session.waiting_for = ""
            return True
        session.do_selfie = True
        session.selfie_choice_made = True
        session.waiting_for = ""

    if session.waiting_for == "selfie_prompt_confirm":
        if text.strip().lower() in ("yes", "y", "ok", "good", "looks good", "apply"):
            session.waiting_for = ""
        elif len(text.strip()) > 100:
            # Replacement prompt
            session.selfie_prompt = text.strip()
            session.waiting_for = ""
        else:
            post("Paste the full replacement prompt, or reply `yes` to use the generated one.")
            return False

    if session.waiting_for == "selfie_config":
        # Parse counter_key / watermark_logo / image_config from user text
        m = re.search(r'counter[_\s]?key[:\s]+(\S+)', text, re.I)
        if m:
            session.counter_key = m.group(1).strip().rstrip(',')
        m = re.search(r'watermark[_\s]?logo[:\s]+(\S+)', text, re.I)
        if m:
            session.watermark_logo = m.group(1).strip().rstrip(',')
        # image_config as JSON block
        m = re.search(r'\{.*\}', text, re.DOTALL)
        if m:
            try:
                json.loads(m.group(0))
                session.image_config_str = m.group(0)
            except json.JSONDecodeError:
                pass
        if not session.counter_key:
            post(
                "❓ Step 6 — selfie config: still need at minimum a `counter_key`.\n"
                "Example: `counter_key: hilton_sc | watermark_logo: https://... | {\"message\":\"...\"}`"
            )
            return False
        session.waiting_for = ""

    # First entry — ask yes/no
    if not session.selfie_choice_made and session.waiting_for == "":
        post(
            "❓ Step 6 — selfie: do you want to set up the selfie feature?\n"
            "Reply `yes` or `no`."
        )
        session.waiting_for = "selfie_confirm"
        return False

    # Generate selfie prompt if not set
    if not session.selfie_prompt:
        if not session.venue_name and not session.context_extra:
            post(
                "❓ Step 6 — selfie prompt: I need venue context to generate the prompt.\n"
                "What venue/brand/event should the selfie background be set in?\n"
                "_Or paste a full image prompt directly (200+ chars)._"
            )
            session.waiting_for = "selfie_prompt_confirm"
            return False

        post("⏳ Step 6 — generating selfie image prompt from venue context…")
        try:
            session.selfie_prompt = _generate_selfie_prompt(session)
        except Exception as e:
            post(f"❌ Step 6 — selfie prompt generation failed: {e}")
            return False

        preview = session.selfie_prompt[:300].replace("\n", " ↵ ")
        post(
            f"✅ Step 6 — selfie prompt generated ({len(session.selfie_prompt)} chars). Preview:\n"
            f"```{preview}…```\n"
            f"Reply `yes` to use it, or paste a replacement prompt."
        )
        session.waiting_for = "selfie_prompt_confirm"
        return False

    # Ask for agentflow config if not set
    if not session.counter_key:
        post(
            "❓ Step 6 — selfie agentflow config: provide these values:\n"
            "• `counter_key` — unique slug for selfie counter (e.g. `hilton_sc_2026`) _(required)_\n"
            "• `watermark_logo` — logo URL _(optional)_\n"
            "• `image_config` — JSON with `message` and `tags` _(optional, defaults to venue name)_\n\n"
            "Example: `counter_key: hilton_sc | watermark_logo: https://... | {\"message\":\"...\"}`"
        )
        session.waiting_for = "selfie_config"
        return False

    # Set selfie.templates[0] on agent config
    template_payload = json.dumps({
        "selfie": {
            "templates": [{
                "provider": session.selfie_provider,
                "model": session.selfie_model,
                "prompt": session.selfie_prompt,
            }]
        }
    })
    rc, out, err = _run([
        _script("livex-config-update.sh"), session.agent_id,
        "--profile", session.profile_name,
        template_payload, "--yes",
    ])
    if rc != 0:
        post(f"❌ Step 6 — selfie template: {err or out}")
        return False
    post(f"✅ Step 6a — selfie template: `{session.selfie_provider}/{session.selfie_model}` set.")

    # Create agentflow
    flow = _build_selfie_agentflow(session)
    # Strip account/agent IDs (shouldn't be there but be safe)
    flow.pop("account_id", None)
    flow.pop("agent_id", None)

    tmp = _write_tmp(flow)
    try:
        rc2, out2, err2 = _run([
            _script("livex-flow-create.sh"),
            f"@{tmp}",
            "--profile", session.profile_name,
        ])
    finally:
        os.unlink(tmp)

    if rc2 != 0:
        post(f"❌ Step 6b — selfie agentflow create: {err2 or out2}")
        return False

    # Extract workflow_id
    workflow_id = ""
    try:
        resp = json.loads(out2)
        workflow_id = resp.get("workflow_id") or resp.get("id") or ""
    except (json.JSONDecodeError, AttributeError):
        m = re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', out2)
        if m:
            workflow_id = m.group(0)

    if not workflow_id:
        post(f"⚠️ Step 6b — agentflow created but workflow_id not found in:\n`{out2[:300]}`\n→ Publish manually.")
        return True

    # Publish
    rc3, out3, err3 = _run([
        _script("livex-flow-publish.sh"), workflow_id,
        "--profile", session.profile_name,
        "--yes",
    ])
    if rc3 != 0:
        post(f"❌ Step 6c — selfie agentflow publish: {err3 or out3}")
        return False

    post(f"✅ Step 6b/c — selfie agentflow created and published (`{workflow_id}`)")
    session.waiting_for = ""
    return True


def _step_workflow_tool(session: SetupSession, post: Callable) -> bool:
    tools = []
    try:
        tools = session.config.get("tool_agent", {}).get("tools", []) or []
    except AttributeError:
        pass

    # Re-read in case config changed since we loaded it
    rc, out, _ = _run([
        _script("livex-config-read.sh"), session.agent_id,
        "--profile", session.profile_name, "--field", ".tool_agent.tools",
    ])
    if rc == 0:
        try:
            tools = json.loads(out) or []
        except json.JSONDecodeError:
            pass

    if "workflow_tool" in tools:
        post("⏭️ Step 7 — workflow_tool: already present.")
        return True

    new_tools = list(tools) + ["workflow_tool"]
    rc2, out2, err2 = _run([
        _script("livex-config-update.sh"), session.agent_id,
        "--profile", session.profile_name,
        json.dumps({"tool_agent": {"tools": new_tools}}),
        "--yes",
    ])
    if rc2 != 0:
        post(f"❌ Step 7 — workflow_tool: {err2 or out2}")
        return False

    post(f"✅ Step 7 — workflow_tool added. tools: `{new_tools}`")
    return True


def _step_publish(session: SetupSession, post: Callable) -> bool:
    rc, out, err = _run([
        _script("livex-config-publish.sh"), session.agent_id,
        "--profile", session.profile_name, "--yes",
    ])
    if rc != 0:
        post(f"❌ Step 8 — publish: {err or out}")
        return False
    post("✅ Step 8 — agent config published to live.")
    return True


def _step_verify(session: SetupSession, post: Callable) -> bool:
    rc, out, _ = _run([
        _script("livex-config-read.sh"), session.agent_id,
        "--profile", session.profile_name,
    ])
    if rc != 0:
        post(f"❌ Step 9 — verify: could not read config.")
        return False

    try:
        cfg = json.loads(out)
    except json.JSONDecodeError:
        post("❌ Step 9 — verify: could not parse config.")
        return False

    tools = cfg.get("tool_agent", {}).get("tools", [])
    bv = cfg.get("business_voice", {})
    selfie_tmpls = cfg.get("selfie", {}).get("templates", [])
    name = cfg.get("name") or cfg.get("nickname") or session.agent_id

    lines = [f"✅ Step 9 — verify: `{name}`"]
    lines.append(f"  • tools: `{tools}`")
    lines.append(f"  • business_voice.enabled: `{bv.get('enabled')}`")
    if selfie_tmpls:
        t = selfie_tmpls[0]
        lines.append(f"  • selfie: `{t.get('provider')}/{t.get('model')}` ({len(t.get('prompt',''))} char prompt)")
    else:
        lines.append("  • selfie: not configured")
    lines.append(f"  • personality: {'set ✅' if cfg.get('personality') else 'not set ⚠️'}")

    post("\n".join(lines))
    _remove_profile(session)
    return True


# ── runner ─────────────────────────────────────────────────────────────────────

def _run_from_step(session: SetupSession, text: str, post: Callable):
    """Advance session from current step, calling handlers in sequence."""
    while session.step < len(STEPS):
        step_name = STEPS[session.step]

        ok = False
        if step_name == "credentials":
            ok = _step_credentials(session, text, post)
        elif step_name == "create_agent":
            ok = _step_create_agent(session, post)
        elif step_name == "personality":
            ok = _step_personality(session, text, post)
        elif step_name == "classifier_model":
            ok = _step_classifier_model(session, post)
        elif step_name == "language_models":
            ok = _step_language_models(session, text, post)
        elif step_name == "kb":
            ok = _step_kb(session, text, post)
        elif step_name == "selfie":
            ok = _step_selfie(session, text, post)
        elif step_name == "workflow_tool":
            ok = _step_workflow_tool(session, post)
        elif step_name == "publish":
            ok = _step_publish(session, post)
        elif step_name == "verify":
            ok = _step_verify(session, post)

        if not ok:
            # Step is waiting for more input — stop here
            return

        session.step += 1
        text = ""  # clear text for auto-advancing steps that need no input

    post("🎉 *Setup complete!* All steps finished. Session cleared.\n_Use `/setupagent fix <step>` to re-run any step._")
    clear_session(session.user_id)


# ── public entry point ─────────────────────────────────────────────────────────

def handle_input(user_id: str, channel_id: str, text: str, post: Callable) -> None:
    text = (text or "").strip()

    # Abort
    if text.lower() in ("abort", "cancel", "stop", "exit", "quit"):
        had_session = get_session(user_id) is not None
        clear_session(user_id)
        if had_session:
            post("🛑 Setup aborted. Any steps already applied to the agent remain in place.\nRun `/setupagent` to start a new session or `/setupagent fix <step>` to continue.")
        else:
            post("No active session to abort.")
        return

    # Reset
    if text.lower() in ("reset", "restart", "start", ""):
        clear_session(user_id)
        post(
            "🤖 *LiveX Agent Setup* — zero to live\n\n"
            "*New agent* — provide:\n"
            "• `account_id`, `api_key`, `name: <agent name>`\n"
            "• Optional: `desc: <description>`, `clone_from: <agent_id>`\n\n"
            "*Existing agent* — provide:\n"
            "• `account_id`, `api_key`, `agent_id: <pub-xxxx>`\n\n"
            "_Steps: credentials → create/load agent → personality → classifier_model → language_models → kb → selfie → workflow_tool → publish → verify_\n"
            "_Use `/setupagent fix <step>` to re-run any step after setup._"
        )
        return

    # Fix / jump to a specific step
    fix_match = re.match(r'^fix\s+(\S+)', text, re.I)
    if fix_match:
        step_key = fix_match.group(1).lower()
        target = FIXABLE_STEPS.get(step_key)
        if not target:
            post(f"❓ Unknown step `{step_key}`. Fixable steps: {', '.join(FIXABLE_STEPS.keys())}")
            return
        session = get_session(user_id)
        if not session:
            post("No active session. Start with `/setupagent reset` first and provide credentials.")
            return
        session.step = STEPS.index(target)
        session.waiting_for = ""
        post(f"↩️ Jumping to step: `{target}`")
        _run_from_step(session, "", post)
        return

    session = get_session(user_id)
    if session is None:
        session = new_session(user_id, channel_id)

    _run_from_step(session, text, post)

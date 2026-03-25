"""
Real script-execution engine for /setupagent Slack command.

Follows avatai-agent-setup SKILL.md steps in order, running actual livex-config
shell scripts via subprocess and posting step-by-step progress to Slack.
"""

import os
import re
import json
import subprocess
import tempfile
from dataclasses import dataclass, field
from typing import Optional

SCRIPTS_DIR = os.path.expanduser(
    os.environ.get(
        "LIVEX_SCRIPTS_PATH",
        "~/.claude/plugins/cache/livex-plugins/livex-config/1.7.1/scripts"
    )
)
SCRIPTS_DIR = os.path.expanduser(SCRIPTS_DIR)
PROFILES_FILE = os.path.expanduser("~/.config/livex-api/profiles")

CLASSIFIER_MODELS = [
    "cerebras-gpt-oss-120b",
    "groq-openai/gpt-oss-120b",
    "gpt-4.1-2025-04-14",
]

STEPS = [
    "credentials",       # 1 - parse + verify agent_id / account_id / api_key
    "read_config",       # 2 - read full draft config
    "classifier_model",  # 3 - patch business_voice.classifier_model
    "stt_prompt",        # 4 - ask for STT keywords, patch via --full-write
    "selfie_template",   # 5 - set selfie.templates[0] (provider/model/prompt)
    "selfie_agentflow",  # 6 - create + publish selfie agentflow
    "workflow_tool",     # 7 - ensure workflow_tool in tool_agent.tools
    "publish",           # 8 - publish agent config
    "verify",            # 9 - re-read + confirm key fields
]


@dataclass
class SetupSession:
    user_id: str
    channel_id: str
    step: int = 0                   # index into STEPS
    agent_id: str = ""              # may have pub- prefix
    bare_id: str = ""               # always without pub- prefix
    account_id: str = ""
    api_key: str = ""
    profile_name: str = ""
    config: dict = field(default_factory=dict)

    # Step 4 — STT keywords
    stt_keywords: str = ""

    # Step 5 — selfie
    do_selfie: bool = False
    selfie_provider: str = "xai"
    selfie_model: str = "grok-imagine-image"
    selfie_prompt: str = ""

    # Step 6 — agentflow
    image_config: str = ""          # JSON string
    counter_key: str = ""
    watermark_logo: str = ""

    # Internal
    waiting_for: str = ""           # "" means not waiting, else label of what's needed


# ── session store ──────────────────────────────────────────────────────────────

_sessions: dict[str, SetupSession] = {}


def get_session(user_id: str) -> Optional[SetupSession]:
    return _sessions.get(user_id)


def new_session(user_id: str, channel_id: str) -> SetupSession:
    s = SetupSession(user_id=user_id, channel_id=channel_id)
    _sessions[user_id] = s
    return s


def clear_session(user_id: str):
    _sessions.pop(user_id, None)


# ── subprocess helpers ─────────────────────────────────────────────────────────

def _run(cmd: list[str], input_data: str = None) -> tuple[int, str, str]:
    """Run a shell command, return (returncode, stdout, stderr)."""
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        input=input_data,
        timeout=60,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _script(name: str) -> str:
    return os.path.join(SCRIPTS_DIR, name)


# ── profile bootstrap ──────────────────────────────────────────────────────────

def _ensure_profile(session: SetupSession) -> str:
    """Create (or overwrite) a temp profile for this session. Returns profile name."""
    profile_name = f"_setup_{session.user_id[:8]}"
    os.makedirs(os.path.dirname(PROFILES_FILE), exist_ok=True)

    # Read existing profiles, remove any old temp line for this user
    lines = []
    if os.path.exists(PROFILES_FILE):
        with open(PROFILES_FILE) as f:
            lines = [l for l in f.readlines() if not l.startswith(profile_name + "\t")]

    lines.append(f"{profile_name}\t{session.api_key}\t{session.account_id}\n")
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


# ── parsing helpers ────────────────────────────────────────────────────────────

def _parse_credentials(text: str) -> dict:
    """Extract agent_id, account_id, api_key from free-form text."""
    result = {}
    # agent_id: pub-xxxx or bare UUID
    m = re.search(r'agent[_\s]?id[:\s]+([a-zA-Z0-9\-]+)', text, re.I)
    if m:
        result["agent_id"] = m.group(1).strip()
    # fallback: look for pub- prefix directly
    m2 = re.search(r'(pub-[0-9a-f\-]{32,})', text, re.I)
    if m2 and "agent_id" not in result:
        result["agent_id"] = m2.group(1).strip()

    m = re.search(r'account[_\s]?id[:\s]+([0-9a-f\-]{32,})', text, re.I)
    if m:
        result["account_id"] = m.group(1).strip()

    m = re.search(r'api[_\s]?key[:\s]+([0-9a-f\-]{32,})', text, re.I)
    if m:
        result["api_key"] = m.group(1).strip()

    return result


# ── step implementations ───────────────────────────────────────────────────────

def _step_credentials(session: SetupSession, text: str, post) -> bool:
    """Parse and verify credentials. Returns True if complete."""
    creds = _parse_credentials(text)

    if creds.get("agent_id"):
        session.agent_id = creds["agent_id"]
        session.bare_id = session.agent_id.removeprefix("pub-")
    if creds.get("account_id"):
        session.account_id = creds["account_id"]
    if creds.get("api_key"):
        session.api_key = creds["api_key"]

    missing = []
    if not session.agent_id:
        missing.append("`agent_id`")
    if not session.account_id:
        missing.append("`account_id`")
    if not session.api_key:
        missing.append("`api_key`")

    if missing:
        post(f"❓ Step 1 — credentials: still need {', '.join(missing)}")
        session.waiting_for = "credentials"
        return False

    session.profile_name = _ensure_profile(session)
    post(
        f"✅ Step 1 — credentials: `{session.agent_id}` on account `{session.account_id[:8]}…` "
        f"(profile `{session.profile_name}`)"
    )
    session.waiting_for = ""
    return True


def _step_read_config(session: SetupSession, post) -> bool:
    rc, out, err = _run([
        _script("livex-config-read.sh"),
        session.agent_id,
        "--profile", session.profile_name,
    ])
    if rc != 0:
        post(f"❌ Step 2 — read config: {err or out}\n→ Check credentials and try again.")
        return False

    try:
        session.config = json.loads(out)
    except json.JSONDecodeError:
        post(f"❌ Step 2 — read config: could not parse JSON response.\n`{out[:200]}`")
        return False

    name = session.config.get("name") or session.config.get("nickname") or session.agent_id
    post(f"✅ Step 2 — read config: `{name}` loaded.")
    return True


def _step_classifier_model(session: SetupSession, post) -> bool:
    payload = json.dumps({
        "business_voice": {
            "classifier_model": CLASSIFIER_MODELS
        }
    })
    rc, out, err = _run([
        _script("livex-config-update.sh"),
        session.agent_id,
        "--profile", session.profile_name,
        payload,
        "--yes",
    ])
    if rc != 0:
        post(f"❌ Step 3 — classifier_model: {err or out}")
        return False
    post(f"✅ Step 3 — classifier_model: set to `{', '.join(CLASSIFIER_MODELS)}`")
    return True


def _step_stt_prompt(session: SetupSession, text: str, post) -> bool:
    """
    Patch stt_prompt in both voice.language_models[] and avatai.language_models[]
    via --full-write. First call: ask for keywords. Second call: apply.
    """
    if session.waiting_for == "stt_keywords":
        # User just provided keywords
        session.stt_keywords = text.strip()
        session.waiting_for = ""

    if not session.stt_keywords:
        post(
            "❓ Step 4 — stt_prompt: what keywords should be added to the STT prompt?\n"
            "_(e.g. brand name, venue, event name, product names)_"
        )
        session.waiting_for = "stt_keywords"
        return False

    # Read full config to get existing language_models
    rc, out, err = _run([
        _script("livex-config-read.sh"),
        session.agent_id,
        "--profile", session.profile_name,
        "--full",
    ])
    if rc != 0:
        post(f"❌ Step 4 — stt_prompt: full read failed: {err or out}")
        return False

    try:
        full_cfg = json.loads(out)
    except json.JSONDecodeError:
        post(f"❌ Step 4 — stt_prompt: could not parse full config JSON.")
        return False

    stt_prompt = f"Keywords: {session.stt_keywords}"

    def patch_lm(lm_list):
        patched = []
        for entry in (lm_list or []):
            entry = dict(entry)
            entry["stt_prompt"] = stt_prompt
            patched.append(entry)
        return patched

    voice_lm = full_cfg.get("voice", {}).get("language_models", [])
    avatai_lm = full_cfg.get("avatai", {}).get("language_models", [])

    payload = {}
    if voice_lm:
        payload["voice"] = {"language_models": patch_lm(voice_lm)}
    if avatai_lm:
        payload["avatai"] = {"language_models": patch_lm(avatai_lm)}

    if not payload:
        post("⏭️ Step 4 — stt_prompt: no language_models found to patch (skipped).")
        return True

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(payload, f)
        tmp = f.name

    try:
        rc, out, err = _run([
            _script("livex-config-update.sh"),
            session.bare_id,
            "--profile", session.profile_name,
            f"@{tmp}",
            "--full-write",
            "--yes",
        ])
    finally:
        os.unlink(tmp)

    if rc != 0:
        post(f"❌ Step 4 — stt_prompt: full-write failed: {err or out}")
        return False

    count = len(voice_lm) + len(avatai_lm)
    post(f"✅ Step 4 — stt_prompt: patched {count} language_models entries with `{stt_prompt}`")
    return True


def _step_selfie_template(session: SetupSession, text: str, post) -> bool:
    """
    Ask whether selfie is needed. If yes, ask for prompt/config if not already set.
    """
    if session.waiting_for == "selfie_confirm":
        answer = text.strip().lower()
        if answer in ("no", "n", "skip"):
            session.do_selfie = False
            post("⏭️ Step 5 — selfie template: skipped (user said no).")
            session.waiting_for = ""
            return True
        session.do_selfie = True
        session.waiting_for = ""

    if session.waiting_for == "selfie_prompt":
        session.selfie_prompt = text.strip()
        session.waiting_for = ""

    if not session.do_selfie and session.waiting_for == "":
        # First entry — ask
        post(
            "❓ Step 5 — selfie template: do you want to configure a selfie feature?\n"
            "Reply `yes` / `no`. If yes, also provide:\n"
            "• `provider` (default: `xai`)\n"
            "• `model` (default: `grok-imagine-image`)\n"
            "• selfie prompt (paste the full prompt, or reply `yes` and I'll ask next)"
        )
        session.waiting_for = "selfie_confirm"
        return False

    # If user said yes but we still have no prompt
    if session.do_selfie and not session.selfie_prompt:
        # Check if text contains a long prompt
        if len(text.strip()) > 100:
            session.selfie_prompt = text.strip()
        else:
            post("❓ Step 5 — selfie template: please paste the full selfie image prompt.")
            session.waiting_for = "selfie_prompt"
            return False

    # Apply selfie template
    payload = json.dumps({
        "selfie": {
            "templates": [{
                "provider": session.selfie_provider,
                "model": session.selfie_model,
                "prompt": session.selfie_prompt,
            }]
        }
    })
    rc, out, err = _run([
        _script("livex-config-update.sh"),
        session.agent_id,
        "--profile", session.profile_name,
        payload,
        "--yes",
    ])
    if rc != 0:
        post(f"❌ Step 5 — selfie template: {err or out}")
        return False

    post(
        f"✅ Step 5 — selfie template: set `{session.selfie_provider}/{session.selfie_model}` "
        f"({len(session.selfie_prompt)} char prompt)"
    )
    return True


def _step_selfie_agentflow(session: SetupSession, text: str, post) -> bool:
    """Create + publish a selfie agentflow if selfie is enabled."""
    if not session.do_selfie:
        post("⏭️ Step 6 — selfie agentflow: skipped (no selfie).")
        return True

    if session.waiting_for == "agentflow_config":
        # User is providing image_config / counter_key / watermark_logo
        # Try to parse as JSON or key=value pairs
        try:
            cfg = json.loads(text)
            session.image_config = json.dumps(cfg.get("image_config", cfg))
            session.counter_key = cfg.get("counter_key", session.counter_key)
            session.watermark_logo = cfg.get("watermark_logo", session.watermark_logo)
        except json.JSONDecodeError:
            # Plain text — extract fields manually
            m = re.search(r'counter[_\s]?key[:\s]+(\S+)', text, re.I)
            if m:
                session.counter_key = m.group(1).strip()
            m = re.search(r'watermark[_\s]?logo[:\s]+(\S+)', text, re.I)
            if m:
                session.watermark_logo = m.group(1).strip()
        session.waiting_for = ""

    if not session.image_config or not session.counter_key:
        post(
            "❓ Step 6 — selfie agentflow: provide agentflow config (JSON or key=value):\n"
            "• `counter_key` — e.g. `my_event_2026`\n"
            "• `watermark_logo` — logo URL (optional)\n"
            "• `image_config` — JSON with `message` and `tags` (optional)\n\n"
            "Example: `counter_key: my_event | watermark_logo: https://...`"
        )
        session.waiting_for = "agentflow_config"
        return False

    # Build agentflow JSON
    workflow_config = {
        "image_prompt": session.selfie_prompt,
        "image_counter_key": session.counter_key,
    }
    if session.watermark_logo:
        workflow_config["image_watermark_logo"] = session.watermark_logo
    if session.image_config:
        try:
            workflow_config["image_config"] = json.loads(session.image_config)
        except (json.JSONDecodeError, TypeError):
            workflow_config["image_config"] = session.image_config

    agentflow = {
        "workflow_name": f"Feature: Selfie - {session.agent_id}",
        "workflow_type": "agentflow",
        "workflow_config": workflow_config,
        "steps": [{"step_type": "selfie"}],
    }

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(agentflow, f)
        tmp = f.name

    try:
        rc, out, err = _run([
            _script("livex-flow-create.sh"),
            f"@{tmp}",
            "--profile", session.profile_name,
        ])
    finally:
        os.unlink(tmp)

    if rc != 0:
        post(f"❌ Step 6 — selfie agentflow create: {err or out}")
        return False

    # Extract workflow_id from response
    try:
        resp = json.loads(out)
        workflow_id = resp.get("workflow_id") or resp.get("id") or ""
    except (json.JSONDecodeError, AttributeError):
        # Try to grep from output
        m = re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', out)
        workflow_id = m.group(0) if m else ""

    if not workflow_id:
        post(f"⚠️ Step 6 — agentflow created but could not extract workflow_id from:\n`{out[:300]}`\nSkipping publish step.")
        return True

    # Publish the flow
    rc2, out2, err2 = _run([
        _script("livex-flow-publish.sh"),
        workflow_id,
        "--profile", session.profile_name,
        "--yes",
    ])
    if rc2 != 0:
        post(f"❌ Step 6 — selfie agentflow publish: {err2 or out2}")
        return False

    post(f"✅ Step 6 — selfie agentflow: created and published (`{workflow_id}`)")
    return True


def _step_workflow_tool(session: SetupSession, post) -> bool:
    """Ensure workflow_tool is in tool_agent.tools."""
    tools = []
    try:
        tools = session.config.get("tool_agent", {}).get("tools", [])
    except AttributeError:
        pass

    if "workflow_tool" in tools:
        post("⏭️ Step 7 — workflow_tool: already present.")
        return True

    new_tools = list(tools) + ["workflow_tool"]
    payload = json.dumps({"tool_agent": {"tools": new_tools}})
    rc, out, err = _run([
        _script("livex-config-update.sh"),
        session.agent_id,
        "--profile", session.profile_name,
        payload,
        "--yes",
    ])
    if rc != 0:
        post(f"❌ Step 7 — workflow_tool: {err or out}")
        return False

    post(f"✅ Step 7 — workflow_tool: added (tools: {new_tools})")
    return True


def _step_publish(session: SetupSession, post) -> bool:
    rc, out, err = _run([
        _script("livex-config-publish.sh"),
        session.agent_id,
        "--profile", session.profile_name,
        "--yes",
    ])
    if rc != 0:
        post(f"❌ Step 8 — publish: {err or out}")
        return False

    post("✅ Step 8 — publish: agent config published to live.")
    return True


def _step_verify(session: SetupSession, post) -> bool:
    rc, out, err = _run([
        _script("livex-config-read.sh"),
        session.agent_id,
        "--profile", session.profile_name,
    ])
    if rc != 0:
        post(f"❌ Step 9 — verify: {err or out}")
        return False

    try:
        cfg = json.loads(out)
    except json.JSONDecodeError:
        post("❌ Step 9 — verify: could not parse config.")
        return False

    tools = cfg.get("tool_agent", {}).get("tools", [])
    bv_enabled = cfg.get("business_voice", {}).get("enabled")
    selfie_tmpl = cfg.get("selfie", {}).get("templates", [])

    summary = [f"✅ Step 9 — verify:"]
    summary.append(f"  • tools: {tools}")
    summary.append(f"  • business_voice.enabled: {bv_enabled}")
    if selfie_tmpl:
        tmpl = selfie_tmpl[0]
        summary.append(f"  • selfie template: `{tmpl.get('provider')}/{tmpl.get('model')}`")
    else:
        summary.append("  • selfie template: none")

    post("\n".join(summary))
    _remove_profile(session)
    return True


# ── main entry point ───────────────────────────────────────────────────────────

def handle_input(user_id: str, channel_id: str, text: str, post) -> None:
    """
    Called from bot.py /setupagent handler.
    `post` is a callable(str) that sends a message to Slack.
    """
    text = text.strip()

    # Reset commands
    if text.lower() in ("reset", "restart", "start", ""):
        clear_session(user_id)
        session = new_session(user_id, channel_id)
        post(
            "🤖 *LiveX Agent Setup* — real script execution mode\n\n"
            "Provide credentials to begin:\n"
            "• `agent_id` — e.g. `pub-xxxx-…`\n"
            "• `account_id`\n"
            "• `api_key`\n\n"
            "Paste in any format. `/setupagent reset` to start over at any time.\n"
            "_Steps: credentials → read config → classifier model → STT prompt → selfie → agentflow → workflow_tool → publish → verify_"
        )
        return

    session = get_session(user_id)
    if session is None:
        session = new_session(user_id, channel_id)
        # Fall through and treat text as first input (credentials)

    # Route to the right step handler
    step_name = STEPS[session.step] if session.step < len(STEPS) else "done"

    def advance():
        session.step += 1

    if step_name == "credentials" or session.waiting_for == "credentials":
        if not _step_credentials(session, text, post):
            return
        advance()
        # Immediately proceed to read_config without waiting
        step_name = STEPS[session.step]

    if step_name == "read_config":
        if not _step_read_config(session, post):
            return
        advance()
        step_name = STEPS[session.step]

    if step_name == "classifier_model":
        if not _step_classifier_model(session, post):
            return
        advance()
        step_name = STEPS[session.step]

    if step_name == "stt_prompt" or session.waiting_for == "stt_keywords":
        if not _step_stt_prompt(session, text, post):
            return
        advance()
        step_name = STEPS[session.step]

    if step_name == "selfie_template" or session.waiting_for in ("selfie_confirm", "selfie_prompt"):
        if not _step_selfie_template(session, text, post):
            return
        advance()
        step_name = STEPS[session.step]

    if step_name == "selfie_agentflow" or session.waiting_for == "agentflow_config":
        if not _step_selfie_agentflow(session, text, post):
            return
        advance()
        step_name = STEPS[session.step]

    if step_name == "workflow_tool":
        if not _step_workflow_tool(session, post):
            return
        advance()
        step_name = STEPS[session.step]

    if step_name == "publish":
        if not _step_publish(session, post):
            return
        advance()
        step_name = STEPS[session.step]

    if step_name == "verify":
        if not _step_verify(session, post):
            return
        advance()

    if session.step >= len(STEPS):
        post("🎉 *Setup complete!* All steps finished. Session cleared.")
        clear_session(user_id)

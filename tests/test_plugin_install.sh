#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2059,SC2329  # eval strings, globals read by sourced fns, overrides
# Tests for the dashi-plugin (channel-jarvis) part of install.sh, no root needed:
#   channel.env rendering + merge on re-run, folder-trust edit of ~/.claude.json,
#   unit template, sudoers entries, migration inputs from the old gateway,
#   workspace files kept on re-run.
# Run: bash tests/test_plugin_install.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "${TDIR:?}"' EXIT

PASS=0
FAIL=0
check() {
    local name=$1; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$name" >&2
    fi
}
has()    { grep -qxF -- "$2" "$1"; }
hasnt()  { ! grep -qE -- "$2" "$1"; }

# A copy of install.sh whose EDGELAB_HOME points into the sandbox.
FAKE_HOME="${TDIR}/home"
mkdir -p "$FAKE_HOME"
# Root-only paths (/etc, /var/backups) and the root check are pointed into
# the sandbox too, so the switch-over logic runs as a normal user.
mkdir -p "${TDIR}/systemd" "${TDIR}/etc-jarvis" "${TDIR}/backups"
sed -e "s#^readonly EDGELAB_HOME=.*#readonly EDGELAB_HOME=\"${FAKE_HOME}\"#" \
    -e "s#^readonly JARVIS_ENV_DIR=.*#readonly JARVIS_ENV_DIR=\"${TDIR}/etc-jarvis\"#" \
    -e "s#^readonly LEGACY_BACKUP_ROOT=.*#readonly LEGACY_BACKUP_ROOT=\"${TDIR}/backups\"#" \
    -e "s#^readonly RICHARD_HOME=.*#readonly RICHARD_HOME=\"${TDIR}/richard\"#" \
    -e "s#/etc/systemd/system/#${TDIR}/systemd/#g" \
    -e 's#\$EUID -ne 0 ]]#$EUID -ne 0 \&\& -z "${TEST_AS_ROOT:-}" ]]#' \
    "${REPO}/install.sh" >"${TDIR}/install.sh"

export INSTALL_SH_SOURCED_FOR_TESTING=1
export EDGELAB_TEMPLATES_DIR="${REPO}/templates"
# shellcheck disable=SC1091
source "${TDIR}/install.sh"
set +e    # the checks below report failures themselves
as_edgelab() { "$@"; }

TOKEN="123456789:AAHabcdefghijklmnopqrstuvwxyz0123456"
TOKEN2="987654321:BBHabcdefghijklmnopqrstuvwxyz0123456"

# --- channel.env: fresh install ------------------------------------------------
ENV1="${TDIR}/env1"
CHANNEL_ENV_TOKEN="$TOKEN" render_channel_env "" "555" "" /st /ws >"$ENV1"
check "fresh: token written"            has "$ENV1" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "fresh: user ids"                 has "$ENV1" "TELEGRAM_ALLOWED_USER_IDS=555"
check "fresh: chat ids = user ids"      has "$ENV1" "TELEGRAM_ALLOWED_CHAT_IDS=555"
check "fresh: state dir"                has "$ENV1" "TELEGRAM_STATE_DIR=/st"
check "fresh: workspace root"           has "$ENV1" "TELEGRAM_WORKSPACE_ROOT=/ws"
check "fresh: agent id"                 has "$ENV1" "AGENT_ID=jarvis"
check "fresh: no expected bot id line"  hasnt "$ENV1" '^TELEGRAM_EXPECTED_BOT_ID='
check "fresh: no groq without key"      hasnt "$ENV1" '^GROQ_API_KEY='
check "fresh: token not in argv form"   hasnt "$ENV1" '^#.*AAHabc'

# --- channel.env: empty answers (tokens filled later by hand) ------------------
ENV0="${TDIR}/env0"
CHANNEL_ENV_TOKEN="" render_channel_env "" "" "" /st /ws >"$ENV0"
check "empty: renders"                  test -s "$ENV0"
check "empty: token line present"       has "$ENV0" "TELEGRAM_BOT_TOKEN="
check "empty: chat ids line present"    has "$ENV0" "TELEGRAM_ALLOWED_CHAT_IDS="

# --- channel.env: re-run keeps values, merges chat ids, keeps extras ----------
PREV="${TDIR}/prev"
cat >"$PREV" <<EOF
TELEGRAM_BOT_TOKEN=${TOKEN}
TELEGRAM_EXPECTED_BOT_ID=111
TELEGRAM_ALLOWED_USER_IDS=555
TELEGRAM_ALLOWED_CHAT_IDS=-100777
TELEGRAM_WEBHOOK_PORT=8095
MY_EXTRA=keep
EOF
ENV2="${TDIR}/env2"
CHANNEL_ENV_TOKEN="" render_channel_env "$PREV" "" "" /st /ws >"$ENV2"
check "rerun: token kept"               has "$ENV2" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "rerun: user ids kept"            has "$ENV2" "TELEGRAM_ALLOWED_USER_IDS=555"
check "rerun: group kept + owner added" has "$ENV2" "TELEGRAM_ALLOWED_CHAT_IDS=-100777,555"
check "rerun: custom port kept"         has "$ENV2" "TELEGRAM_WEBHOOK_PORT=8095"
check "rerun: extra key kept"           has "$ENV2" "MY_EXTRA=keep"
check "rerun: stale expected id dropped" hasnt "$ENV2" '^TELEGRAM_EXPECTED_BOT_ID='

ENV3="${TDIR}/env3"
CHANNEL_ENV_TOKEN="$TOKEN2" render_channel_env "$PREV" "999" "" /st /ws >"$ENV3"
check "rerun: new token wins"           has "$ENV3" "TELEGRAM_BOT_TOKEN=${TOKEN2}"
check "rerun: new user id wins"         has "$ENV3" "TELEGRAM_ALLOWED_USER_IDS=999"
check "rerun: new id added to chats"    has "$ENV3" "TELEGRAM_ALLOWED_CHAT_IDS=-100777,999"

# --- channel.env: groq key from file -------------------------------------------
printf 'gsk_test123\n' >"${TDIR}/groq"
ENV4="${TDIR}/env4"
CHANNEL_ENV_TOKEN="$TOKEN" render_channel_env "" "555" "${TDIR}/groq" /st /ws >"$ENV4"
check "groq: key from file"             has "$ENV4" "GROQ_API_KEY=gsk_test123"

# --- channel.env: bad input refused ---------------------------------------------
check "bad token refused"   eval '! CHANNEL_ENV_TOKEN="nope" render_channel_env "" "" "" /st /ws >/dev/null 2>&1'
check "bad user id refused" eval '! CHANNEL_ENV_TOKEN="" render_channel_env "" "12a" "" /st /ws >/dev/null 2>&1'

# --- ~/.claude.json folder trust ------------------------------------------------
CJ="${TDIR}/claude.json"
printf '{"oauthAccount":{"x":1},"projects":{"/other":{"a":1}},"hasCompletedOnboarding":false}\n' >"$CJ"
chmod 600 "$CJ"
_accept_trust_dialog "$CJ" "/p/plugin"
check "trust: set for plugin dir" \
    python3 -c "import json,sys; d=json.load(open('$CJ')); sys.exit(0 if d['projects']['/p/plugin']['hasTrustDialogAccepted'] is True else 1)"
check "trust: other keys kept" \
    python3 -c "import json,sys; d=json.load(open('$CJ')); sys.exit(0 if d['oauthAccount']=={'x':1} and d['projects']['/other']=={'a':1} else 1)"
check "trust: explicit onboarding value kept" \
    python3 -c "import json,sys; d=json.load(open('$CJ')); sys.exit(0 if d['hasCompletedOnboarding'] is False else 1)"
check "trust: mode 600 kept"      test "$(stat -c %a "$CJ")" = "600"
check "trust: backup written"     test -f "${CJ}.bak-edgelab-install"
_accept_trust_dialog "$CJ" "/p/plugin"
check "trust: idempotent" \
    python3 -c "import json,sys; d=json.load(open('$CJ')); sys.exit(0 if len(d['projects'])==2 else 1)"

CJ2="${TDIR}/new.json"
_accept_trust_dialog "$CJ2" "/p/plugin"
check "trust: file created"       test -f "$CJ2"
check "trust: new file onboarding done" \
    python3 -c "import json,sys; d=json.load(open('$CJ2')); sys.exit(0 if d['hasCompletedOnboarding'] is True else 1)"

CJ3="${TDIR}/broken.json"
printf '{not json' >"$CJ3"
check "trust: broken json -> non-zero" eval '! _accept_trust_dialog "$CJ3" /p/plugin 2>/dev/null'
check "trust: broken json untouched"   test "$(cat "$CJ3")" = "{not json"

# --- unit template --------------------------------------------------------------
UNIT="${TDIR}/unit"
render_template "${REPO}/templates/channel-jarvis.service" "$UNIT" \
    USER edgelab HOME /home/edgelab PLUGIN_DIR /pd ENV_FILE /etc/dashi-plugin/jarvis/channel.env \
    CONFIRM_SCRIPT /usr/local/lib/edgelab/channel-confirm.sh
check "unit: no placeholders left"   hasnt "$UNIT" '\{\{'
check "unit: user"                   has "$UNIT" "User=edgelab"
check "unit: workdir"                has "$UNIT" "WorkingDirectory=/pd"
check "unit: env file"               has "$UNIT" "EnvironmentFile=/etc/dashi-plugin/jarvis/channel.env"
check "unit: bun on PATH"            grep -q '^Environment=PATH=/home/edgelab/.bun/bin:' "$UNIT"
check "unit: system target"          has "$UNIT" "WantedBy=multi-user.target"
check "unit: confirm script"         has "$UNIT" "ExecStartPost=/bin/bash /usr/local/lib/edgelab/channel-confirm.sh channel-jarvis"
if command -v systemd-analyze >/dev/null 2>&1; then
    cp "$UNIT" "${TDIR}/channel-jarvis.service"
    check "unit: systemd-analyze verify" \
        bash -c "systemd-analyze verify '${TDIR}/channel-jarvis.service' 2>&1 | grep -vE 'not executable|No such file|Failed to|WorkingDirectory|EnvironmentFile|/pd' | grep -qiE 'error|unknown' && exit 1 || exit 0"
fi

# --- sudoers: channel-jarvis entries, legacy kept, syntax valid ----------------
SUDO_OUT="${TDIR}/sudoers"
install() { cp "${@: -2:1}" "$SUDO_OUT"; }
step() { :; }
PATH="${PATH}:/usr/sbin:/sbin" install_sudoers >/dev/null
unset -f install
check "sudoers: restart channel-jarvis" grep -q '/usr/bin/systemctl restart channel-jarvis, ' "$SUDO_OUT"
check "sudoers: journal channel-jarvis" grep -q '/usr/bin/journalctl -u channel-jarvis \*' "$SUDO_OUT"
check "sudoers: gateway kept for rollback" grep -q '/usr/bin/systemctl enable claude-gateway, ' "$SUDO_OUT"
if [[ -x /usr/sbin/visudo ]]; then
    check "sudoers: visudo -c" /usr/sbin/visudo -cqf "$SUDO_OUT"
fi

# --- migration: inputs from the old gateway config -----------------------------
mkdir -p "${FAKE_HOME}/claude-gateway/secrets" "${FAKE_HOME}/.claude-lab/shared/secrets"
printf '{"allowed_user_ids":[555,777],"agents":{"jarvis":{"bot_token":"%s"}}}\n' "$TOKEN" \
    >"${FAKE_HOME}/claude-gateway/config.json"
printf 'gsk_legacy\n' >"${FAKE_HOME}/claude-gateway/secrets/groq-api-key"
JARVIS_BOT_TOKEN=""; TG_USER_ID=""
_collect_jarvis_channel_inputs
check "legacy: token imported"      test "$JARVIS_BOT_TOKEN" = "$TOKEN"
check "legacy: ids imported"        test "$JARVIS_ALLOWED_IDS" = "555,777"
check "legacy: groq file fallback"  test "$JARVIS_GROQ_KEY_FILE" = "${FAKE_HOME}/claude-gateway/secrets/groq-api-key"

printf 'gsk_shared\n' >"${FAKE_HOME}/.claude-lab/shared/secrets/groq-api-key"
JARVIS_BOT_TOKEN="$TOKEN2"; TG_USER_ID="999"
_collect_jarvis_channel_inputs
check "legacy: operator answer wins (token)" test "$JARVIS_BOT_TOKEN" = "$TOKEN2"
check "legacy: operator answer wins (id)"    test "$JARVIS_ALLOWED_IDS" = "999"
check "legacy: shared groq preferred"        test "$JARVIS_GROQ_KEY_FILE" = "${FAKE_HOME}/.claude-lab/shared/secrets/groq-api-key"

# groq key rotated inside channel.env: the file on disk must not win back
GENV="${TDIR}/groq.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nGROQ_API_KEY=gsk_rotated\n' "$TOKEN" >"$GENV"
_collect_jarvis_channel_inputs "$GENV"
check "groq rotated: no file import" test -z "$JARVIS_GROQ_KEY_FILE"
CHANNEL_ENV_TOKEN="" render_channel_env "$GENV" "" "$JARVIS_GROQ_KEY_FILE" /st /ws >"${TDIR}/groq.out"
check "groq rotated: kept" has "${TDIR}/groq.out" "GROQ_API_KEY=gsk_rotated"

rm -rf "${FAKE_HOME:?}/claude-gateway"
JARVIS_BOT_TOKEN=""; TG_USER_ID=""
check "fresh server: no legacy, returns 0" _collect_jarvis_channel_inputs
check "fresh server: token stays empty"    test -z "$JARVIS_BOT_TOKEN"

# --- migrated server, re-run: channel.env beats the stale gateway config ------
mkdir -p "${FAKE_HOME}/claude-gateway"
printf '{"allowed_user_ids":[555],"agents":{"jarvis":{"bot_token":"%s"}}}\n' "$TOKEN" \
    >"${FAKE_HOME}/claude-gateway/config.json"
ROT="${TDIR}/rotated.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USER_IDS=999\nTELEGRAM_ALLOWED_CHAT_IDS=999\n' "$TOKEN2" >"$ROT"
JARVIS_BOT_TOKEN=""; TG_USER_ID=""
_collect_jarvis_channel_inputs "$ROT"
check "rotated: legacy token not re-imported" test -z "$JARVIS_BOT_TOKEN"
check "rotated: legacy ids not re-imported"   test -z "$JARVIS_ALLOWED_IDS"
ENV5="${TDIR}/env5"
CHANNEL_ENV_TOKEN="$JARVIS_BOT_TOKEN" render_channel_env "$ROT" "$JARVIS_ALLOWED_IDS" "" /st /ws >"$ENV5"
check "rotated: rotated token kept"  has "$ENV5" "TELEGRAM_BOT_TOKEN=${TOKEN2}"
check "rotated: revoked id not back" has "$ENV5" "TELEGRAM_ALLOWED_USER_IDS=999"
rm -rf "${FAKE_HOME:?}/claude-gateway"

# --- switch-over with a stubbed systemctl -----------------------------------------
CALLS="${TDIR}/calls"
# Stub state: *_ACTIVE / *_ENABLED; *_STOPS / *_DISABLES say whether
# `disable --now` manages to stop / disable that unit.
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; LEGACY_STOPS=1; LEGACY_DISABLES=1
PLUGIN_ACTIVE=0; PLUGIN_ENABLED=0; PLUGIN_STOPS=1; PLUGIN_DISABLES=1
systemctl() {
    printf '%s\n' "$*" >>"$CALLS"
    local verb=$1 unit=${*: -1} who
    [[ "$unit" == --quiet ]] && unit=${*: -2:1}
    if [[ "$unit" == claude-gateway* ]]; then who=LEGACY; else who=PLUGIN; fi
    local -n active="${who}_ACTIVE" enabled="${who}_ENABLED" stops="${who}_STOPS" disables="${who}_DISABLES"
    case "$verb" in
        is-active)  [[ "$active" == 1 ]] ;;
        is-enabled) [[ "$enabled" == 1 ]] ;;
        disable)
            [[ "$stops" == 1 ]] && active=0
            [[ "$disables" == 1 ]] && enabled=0
            return 0 ;;
        enable)
            enabled=1
            [[ "$*" == *"--now"* ]] && active=1
            return 0 ;;
        restart) active=1 ;;
        *) return 0 ;;
    esac
}
install() {    # drop -o/-g/-m: the sandbox user cannot chown to root
    local args=()
    while (($#)); do case $1 in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
}
printf '[Service]\n' >"${TDIR}/systemd/claude-gateway.service"
printf '[Service]\n' >"${TDIR}/systemd/channel-jarvis.service"
mkdir -p "${FAKE_HOME}/.claude"; printf '{}' >"${FAKE_HOME}/.claude/.credentials.json"
RICHARD_BOT_TOKEN=""

# token only in the file (filled by hand), no answer this run
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >"${TDIR}/etc-jarvis/channel.env"
JARVIS_BOT_TOKEN=""; : >"$CALLS"
enable_services >/dev/null 2>&1
check "switch: token from file starts plugin" grep -qx 'restart channel-jarvis.service' "$CALLS"
check "switch: gateway disabled first" \
    bash -c "grep -n 'disable --now claude-gateway' '$CALLS' | cut -d: -f1 | head -1 | xargs -I{} test {} -lt \$(grep -n 'restart channel-jarvis' '$CALLS' | cut -d: -f1)"
check "switch: gateway backup made" bash -c "ls '${TDIR}/backups'/claude-gateway-*/claude-gateway.service >/dev/null"

# gateway refuses to stop -> plugin must not start
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; LEGACY_STOPS=0; PLUGIN_ACTIVE=0; : >"$CALLS"
enable_services >/dev/null 2>&1
check "switch: stuck gateway -> plugin not started" bash -c "! grep -q 'channel-jarvis' '$CALLS'"

# gateway stops but stays enabled (would come back at boot) -> no start
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; LEGACY_STOPS=1; LEGACY_DISABLES=0; : >"$CALLS"
enable_services >/dev/null 2>&1
check "switch: gateway still enabled -> plugin not started" bash -c "! grep -q 'channel-jarvis' '$CALLS'"
LEGACY_DISABLES=1

# backup fails -> gateway untouched, plugin not started
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; : >"$CALLS"
cp() { return 1; }
enable_services >/dev/null 2>&1
unset -f cp
check "switch: backup fails -> gateway untouched" bash -c "! grep -q 'disable --now claude-gateway' '$CALLS'"
check "switch: backup fails -> plugin not started" bash -c "! grep -q 'channel-jarvis' '$CALLS'"

# no token anywhere -> nothing enabled
LEGACY_ACTIVE=1; LEGACY_ENABLED=1; LEGACY_STOPS=1; printf 'TELEGRAM_BOT_TOKEN=\n' >"${TDIR}/etc-jarvis/channel.env"; : >"$CALLS"
enable_services >/dev/null 2>&1
check "switch: empty token -> plugin not enabled" bash -c "! grep -q 'channel-jarvis' '$CALLS'"
check "switch: empty token -> gateway untouched"  bash -c "! grep -q 'disable --now claude-gateway' '$CALLS'"

# rollback: plugin off, gateway on
export TEST_AS_ROOT=1
LEGACY_ACTIVE=0; LEGACY_ENABLED=0; PLUGIN_ACTIVE=1; PLUGIN_ENABLED=1; PLUGIN_STOPS=1; : >"$CALLS"
( rollback_to_gateway ) >/dev/null 2>&1
check "rollback: exit 0" test $? -eq 0
check "rollback: plugin disabled" grep -q 'disable --now channel-jarvis.service' "$CALLS"
check "rollback: gateway enabled" grep -q 'enable --now claude-gateway.service' "$CALLS"

# rollback: plugin refuses to stop -> gateway must not start
LEGACY_ACTIVE=0; LEGACY_ENABLED=0; PLUGIN_ACTIVE=1; PLUGIN_ENABLED=1; PLUGIN_STOPS=0; : >"$CALLS"
( rollback_to_gateway ) >/dev/null 2>&1
check "rollback: stuck plugin -> non-zero" test $? -ne 0
check "rollback: stuck plugin -> gateway not started" bash -c "! grep -q 'enable --now claude-gateway' '$CALLS'"

# rollback: plugin stops but stays enabled -> gateway must not start
PLUGIN_ACTIVE=1; PLUGIN_ENABLED=1; PLUGIN_STOPS=1; PLUGIN_DISABLES=0; : >"$CALLS"
( rollback_to_gateway ) >/dev/null 2>&1
check "rollback: plugin still enabled -> non-zero" test $? -ne 0
check "rollback: plugin still enabled -> gateway not started" bash -c "! grep -q 'enable --now claude-gateway' '$CALLS'"
PLUGIN_DISABLES=1

# rollback on a plugin-only server: nothing to return to, exit 0
rm -f "${TDIR}/systemd/claude-gateway.service"
PLUGIN_ACTIVE=1; PLUGIN_STOPS=1; : >"$CALLS"
( rollback_to_gateway ) >/dev/null 2>&1
check "rollback: no gateway -> exit 0" test $? -eq 0
check "rollback: no gateway -> nothing enabled" bash -c "! grep -q '^enable' '$CALLS'"
check "rollback: no gateway -> plugin left running" bash -c "! grep -q 'disable' '$CALLS'"
unset -f systemctl install
unset TEST_AS_ROOT

# --- workspace: a re-run keeps the agent's files --------------------------------
WS="${TDIR}/ws"
write_as_user() { mkdir -p "$(dirname "$2")"; cp "$1" "$2"; chmod "$3" "$2"; }
_write_agent_workspace_test() {
    local f="${WS}/core/hot/handoff.md" tmp
    mkdir -p "$(dirname "$f")"
    printf 'MY MEMORY\n' >"$f"
    tmp=$(mktemp)
    printf 'stub\n' >"$tmp"
    _write_if_absent "$tmp" "$f" 0644
    _write_if_absent "$tmp" "${WS}/core/new.md" 0644
    rm -f "$tmp"
}
_write_agent_workspace_test
check "workspace: existing file kept" test "$(cat "${WS}/core/hot/handoff.md")" = "MY MEMORY"
check "workspace: missing file written" test "$(cat "${WS}/core/new.md")" = "stub"

# --- prompt_or_env without a tty: like Enter, never dies -----------------------
unset EDGELAB_TEST_ANSWER
R1=$( (EDGELAB_NONINTERACTIVE=1 prompt_or_env V EDGELAB_TEST_ANSWER "q" "" --secret </dev/null 2>/dev/null; printf 'rc=%s v=[%s]' "$?" "$V") )
check "no tty, no default: rc 0, empty" test "$R1" = "rc=0 v=[]"
R2=$( (prompt_or_env V EDGELAB_TEST_ANSWER "q" "Russian" </dev/null 2>/dev/null; printf 'rc=%s v=[%s]' "$?" "$V") )
check "no tty, default used"            test "$R2" = "rc=0 v=[Russian]"
R3=$( (EDGELAB_TEST_ANSWER=from_env prompt_or_env V EDGELAB_TEST_ANSWER "q" "" </dev/null 2>/dev/null; printf 'rc=%s v=[%s]' "$?" "$V") )
check "no tty, env wins"                test "$R3" = "rc=0 v=[from_env]"
R4=$( (EDGELAB_NONINTERACTIVE=1 collect_inputs </dev/null >/dev/null 2>&1; printf 'rc=%s' "$?") )
check "no tty: collect_inputs survives with no tokens" test "$R4" = "rc=0"

# --- merge_env_file ---------------------------------------------------------------
REND="${TDIR}/rend.env"; OLD="${TDIR}/old.env"
printf '# c\nTELEGRAM_BOT_TOKEN=\nTELEGRAM_BOT_USERNAME=\nALLOWED_USERS=\nENVIRONMENT=production\nNEW_KEY=1\n' >"$REND"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_BOT_USERNAME=rbot\nALLOWED_USERS=555\nENVIRONMENT=dev\nMY_OWN=x\n' "$TOKEN" >"$OLD"
merge_env_file "$REND" "$OLD" TELEGRAM_BOT_TOKEN,TELEGRAM_BOT_USERNAME,ALLOWED_USERS >"${TDIR}/m1"
check "merge: empty answer keeps token" has "${TDIR}/m1" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "merge: empty answer keeps users" has "${TDIR}/m1" "ALLOWED_USERS=555"
check "merge: hand edit kept"           has "${TDIR}/m1" "ENVIRONMENT=dev"
check "merge: extra key kept"           has "${TDIR}/m1" "MY_OWN=x"
check "merge: new template key added"   has "${TDIR}/m1" "NEW_KEY=1"
check "merge: comments from template"   has "${TDIR}/m1" "# c"
printf 'TELEGRAM_BOT_TOKEN=%s\nALLOWED_USERS=999\n' "$TOKEN2" >"$REND"
merge_env_file "$REND" "$OLD" TELEGRAM_BOT_TOKEN,TELEGRAM_BOT_USERNAME,ALLOWED_USERS >"${TDIR}/m2"
check "merge: new answer wins (token)"  has "${TDIR}/m2" "TELEGRAM_BOT_TOKEN=${TOKEN2}"
check "merge: new answer wins (users)"  has "${TDIR}/m2" "ALLOWED_USERS=999"
printf 'TELEGRAM_BOT_TOKEN=\nANTHROPIC_API_KEY=\n' >"$REND"
printf 'export TELEGRAM_BOT_TOKEN = %s\nANTHROPIC_API_KEY = sk-x\nexport MY_EXP=1\nQ="a \\"b\\" c"\n' "$TOKEN" >"$OLD"
merge_env_file "$REND" "$OLD" TELEGRAM_BOT_TOKEN >"${TDIR}/m3"
check "merge: export/space answer key kept" has "${TDIR}/m3" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "merge: spaced other key kept"        has "${TDIR}/m3" "ANTHROPIC_API_KEY=sk-x"
check "merge: export extra kept"            has "${TDIR}/m3" "MY_EXP=1"
check "merge: escaped quotes one line kept" has "${TDIR}/m3" 'Q="a \"b\" c"'
for bad in 'MY_OWN="first\nsecond"\nANOTHER=ok\n' 'MY_OWN="first \\"\nsecond"\nANOTHER=ok\n' "MY_OWN='open\nANOTHER=ok\n" 'weird line\nANOTHER=ok\n' \
        "T=a\nMY_OWN='first \\\\'\nU=b\nTAIL=end'\n" 'T=a\nT=b\n' \
        'LOCAL_ROOT=/srv\nAPPROVED_DIRECTORY=${LOCAL_ROOT}\n'; do
    printf "$bad" >"$OLD"
    merge_env_file "$REND" "$OLD" TELEGRAM_BOT_TOKEN >/dev/null 2>&1
    rc=$?
    check "merge: unsafe file -> exit 3 ($(head -1 "$OLD"))" test "$rc" -eq 3
done

# --- install_richard re-run with empty answers keeps Richard alive ---------------
RH="${TDIR}/richard"
mkdir -p "${RH}/venv/bin"
printf '#!/bin/sh\n' >"${RH}/venv/bin/python"; printf '#!/bin/sh\n' >"${RH}/venv/bin/claude-telegram-bot"
chmod +x "${RH}/venv/bin/python" "${RH}/venv/bin/claude-telegram-bot"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_BOT_USERNAME=rbot\nALLOWED_USERS=555\nMY_OWN=x\n' "$TOKEN2" >"${RH}/.env"
sudo() { :; }
install() {
    local args=()
    while (($#)); do case $1 in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
}
RICHARD_BOT_TOKEN=""; RICHARD_BOT_USERNAME=""; TG_USER_ID=""
install_richard >/dev/null 2>&1
check "richard rerun: token kept"    has "${RH}/.env" "TELEGRAM_BOT_TOKEN=${TOKEN2}"
check "richard rerun: users kept"    has "${RH}/.env" "ALLOWED_USERS=555"
check "richard rerun: own line kept" has "${RH}/.env" "MY_OWN=x"
check "richard rerun: template keys" has "${RH}/.env" "USE_SDK=true"
check "richard rerun: backup made"   bash -c "ls '${RH}'/.env.bak-* >/dev/null 2>&1"
check "richard rerun: backup = old"  bash -c "grep -qx 'MY_OWN=x' '${RH}'/.env.bak-* && ! grep -q '^USE_SDK' '${RH}'/.env.bak-*"
N_BAK=$(find "$RH" -name '.env.bak-*' | wc -l)
install_richard >/dev/null 2>&1
check "richard rerun: unchanged -> no new backup" test "$(find "$RH" -name '.env.bak-*' | wc -l)" = "$N_BAK"
rm -f "${RH}/.env"
RICHARD_BOT_TOKEN="$TOKEN"; TG_USER_ID="777"
install_richard >/dev/null 2>&1
check "richard fresh: token written" has "${RH}/.env" "TELEGRAM_BOT_TOKEN=${TOKEN}"
check "richard fresh: users written" has "${RH}/.env" "ALLOWED_USERS=777"
printf 'TELEGRAM_BOT_TOKEN=%s\nMY_OWN="first \\"\nsecond"\nANOTHER=ok\n' "$TOKEN" >"${RH}/.env"
cp "${RH}/.env" "${TDIR}/richard-ml.orig"
RICHARD_BOT_TOKEN=""; TG_USER_ID=""
install_richard >/dev/null 2>&1
check "richard multi-line: file untouched" cmp -s "${RH}/.env" "${TDIR}/richard-ml.orig"
printf "TELEGRAM_BOT_TOKEN=%s\nMY_OWN='first \\\\'\nTELEGRAM_BOT_TOKEN=wrong\nTAIL=end'\n" "$TOKEN" >"${RH}/.env"
cp "${RH}/.env" "${TDIR}/richard-sq.orig"
install_richard >/dev/null 2>&1
check "richard single-quote backslash: file untouched" cmp -s "${RH}/.env" "${TDIR}/richard-sq.orig"
printf 'TELEGRAM_BOT_TOKEN=%s\nLOCAL_ROOT=/srv/richard\nAPPROVED_DIRECTORY=${LOCAL_ROOT}\n' "$TOKEN" >"${RH}/.env"
cp "${RH}/.env" "${TDIR}/richard-interp.orig"
install_richard >/dev/null 2>&1
check "richard interpolation: file untouched" cmp -s "${RH}/.env" "${TDIR}/richard-interp.orig"
unset -f sudo install

# --- final notes point at `claude auth login` ------------------------------------
final_instructions >"${TDIR}/final.txt" 2>&1
check "final: claude auth login"    grep -q "bash -lc 'claude auth login'" "${TDIR}/final.txt"
check "final: no bare claude login" bash -c "! grep -q \"'claude login'\" '${TDIR}/final.txt'"
check "header: claude auth login"   grep -q "claude auth login" "${REPO}/install.sh"

# --- sourcing does not run main -------------------------------------------------
check "guard: sourcing did not install anything" test ! -e "${FAKE_HOME}/.local/bin/claude"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

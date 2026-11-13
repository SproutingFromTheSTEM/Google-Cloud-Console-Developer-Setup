#!/usr/bin/env bash
# dev.sh: use Gemini from your own terminal without ever handling the API key (Mac / Linux).
#
#   ./dev.sh setup                        one-time setup (installs what's missing, signs you in, tests)
#   ./dev.sh status                       who you're signed in as, the app URL, and a connection test
#   ./dev.sh models                       models you're allowed to use
#   ./dev.sh ask "PROMPT" [MODEL]         send one prompt from the terminal
#   ./dev.sh apis                         other APIs your admin added (use them with api("NAME"))
#   ./dev.sh login                        sign in again or switch accounts
#   ./dev.sh set-url URL                  save the gemini-app URL your admin gave you
#
# In your own Python code:  from gemini_access import get_client, get_model, api

set -uo pipefail
cd "$(dirname "$0")"
DEFAULT_MODEL="gemini-3.5-flash-lite"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }

CMD="${1:-help}"; shift || true
export CLOUDSDK_CORE_DISABLE_PROMPTS=1   # sign-in is run with prompts on

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
find_python() {
  PY="$(command -v python3 || command -v python || true)"
  [[ -n "$PY" ]] && "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null
}

ensure_python() {
  find_python && return
  if command -v brew >/dev/null 2>&1; then
    warn "Python 3.9+ not found; installing with Homebrew"
    brew install python || die "Homebrew couldn't install Python. Get it from https://www.python.org/downloads/ and run this again."
    find_python || die "Python still isn't available. Open a new terminal and run this again."
  else
    die "Python 3.9+ isn't installed. Get it from https://www.python.org/downloads/, open a new terminal, and run this again."
  fi
}

ensure_gcloud() {
  command -v gcloud >/dev/null 2>&1 && return
  local sdk="$HOME/google-cloud-sdk"
  if [[ ! -x "$sdk/bin/gcloud" ]]; then
    warn "Google Cloud CLI not found; installing to $sdk (a few minutes)"
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL https://sdk.cloud.google.com -o "$tmp/install.sh" \
      || die "Couldn't download the installer. Check your internet connection, or install it from https://cloud.google.com/sdk/docs/install"
    bash "$tmp/install.sh" --disable-prompts --install-dir="$HOME" >"$tmp/log" 2>&1 \
      || die "The gcloud installer failed. Details: $tmp/log"
  fi
  export PATH="$sdk/bin:$PATH"
  local rc inc
  case "$(basename "${SHELL:-zsh}")" in
    zsh)  rc="$HOME/.zshrc";  inc="$sdk/path.zsh.inc" ;;
    bash) rc="$HOME/.bash_profile"; [[ "$(uname)" == "Linux" ]] && rc="$HOME/.bashrc"; inc="$sdk/path.bash.inc" ;;
    *)    rc="$HOME/.profile"; inc="$sdk/path.bash.inc" ;;
  esac
  if ! grep -qs "google-cloud-sdk/path" "$rc"; then
    printf '\n# Google Cloud CLI\nsource "%s"\n' "$inc" >> "$rc"
    ok "Added gcloud to $rc (new terminal windows will find it)"
  fi
  command -v gcloud >/dev/null 2>&1 || die "gcloud still isn't available. Open a new terminal and run this again."
}

install_packages() {
  local err; err="$(mktemp)"
  if "$PY" -m pip install -q -r requirements.txt 2>"$err" \
     || "$PY" -m pip install -q --user -r requirements.txt 2>"$err" \
     || "$PY" -m pip install -q --user --break-system-packages -r requirements.txt 2>"$err"; then
    ok "Python packages installed"
  else
    die "pip couldn't install requirements.txt: $(tail -3 "$err")"
  fi
}

signed_in() { gcloud auth print-identity-token >/dev/null 2>&1; }
account()   { gcloud config get-value account 2>/dev/null; }

do_login() {
  echo "    A browser window will open. Sign in with the account your admin gave access to."
  CLOUDSDK_CORE_DISABLE_PROMPTS=0 gcloud auth login || die "Sign-in didn't finish. Run ./dev.sh login to retry."
  ok "Signed in as $(account)"
}

url_is_set() { [[ -n "${GEMINI_APP_URL:-}" ]] || ! grep -q 'PASTE_GEMINI_APP_URL' gemini_access.py; }

save_url() {
  local url="${1%/}"
  [[ "$url" == https://* ]] || die "The URL should start with https:// (it ends in .run.app)."
  "$PY" - "$url" <<'PY'
import re, sys, pathlib
p = pathlib.Path("gemini_access.py")
s = p.read_text()
p.write_text(re.sub(r'(os\.environ\.get\("GEMINI_APP_URL",\s*")[^"]*(")',
                    lambda m: m.group(1) + sys.argv[1] + m.group(2), s, count=1))
PY
  ok "Saved the URL in gemini_access.py"
}

connection_test() {
  local out
  if out="$("$PY" -c 'from gemini_access import list_models; print(", ".join(list_models()))' 2>&1)"; then
    ok "Connected. Models you can use: $out"
    return 0
  fi
  warn "The connection test failed:"
  printf '      %s\n' "$(tail -1 <<<"$out")"
  cat <<EOF
    - 403 Forbidden: ask your admin to run  ./admin.sh add-developer $(account)
    - 401: run  ./dev.sh login
    - 404 or connection error: the URL is wrong. Fix it with  ./dev.sh set-url https://...
EOF
  return 1
}

ready() {   # everything a command needs, without installing
  find_python || die "Python isn't set up. Run ./dev.sh setup first."
  command -v gcloud >/dev/null 2>&1 || [[ -x "$HOME/google-cloud-sdk/bin/gcloud" ]] || die "gcloud isn't installed. Run ./dev.sh setup first."
  command -v gcloud >/dev/null 2>&1 || export PATH="$HOME/google-cloud-sdk/bin:$PATH"
  signed_in || die "You're not signed in. Run ./dev.sh login"
  url_is_set || die "The gemini-app URL isn't set. Run ./dev.sh set-url https://... (your admin has it)."
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_setup() {
  say "Python";            ensure_python; ok "$("$PY" --version 2>&1)"
  say "Google Cloud CLI";  ensure_gcloud; ok "$(gcloud --version 2>/dev/null | head -1)"
  say "Python packages";   install_packages
  say "Sign in"
  if signed_in; then
    ok "Signed in as $(account)"
    read -r -p "    Is that the account your admin gave access to? [Y/n] " a
    [[ "${a:-y}" =~ ^[Nn] ]] && do_login
  else
    do_login
  fi
  say "gemini-app URL"
  if url_is_set; then ok "Already set"; else
    local url; read -r -p "    Paste the gemini-app URL from your admin: " url
    save_url "$url"
  fi
  say "Testing the connection"
  if connection_test; then
    printf '\n\033[1;32mSetup complete.\033[0m Try:  ./dev.sh ask "Say hi"\n'
    printf 'In your code:\n    from gemini_access import get_model\n    model = get_model("%s")\n    response = model.generate_content(YOUR_PROMPT)\n' "$DEFAULT_MODEL"
    printf 'Every Gemini feature (images, files, chat, streaming), as in Google'"'"'s docs:\n    from gemini_access import get_client\n    client = get_client()\n\n'
  else
    exit 1
  fi
}

cmd_status() {
  find_python || die "Python isn't set up. Run ./dev.sh setup first."
  command -v gcloud >/dev/null 2>&1 || export PATH="$HOME/google-cloud-sdk/bin:$PATH"
  say "Status"
  if signed_in; then ok "Signed in as $(account)"; else warn "Not signed in (./dev.sh login)"; fi
  if url_is_set; then
    ok "gemini-app URL: ${GEMINI_APP_URL:-$(sed -n 's/.*GEMINI_APP_URL", "\([^"]*\)".*/\1/p' gemini_access.py | head -1)}"
  else
    warn "gemini-app URL not set (./dev.sh set-url https://...)"
  fi
  signed_in && url_is_set && connection_test
}

cmd_models() {
  ready
  "$PY" -c 'from gemini_access import list_models; print("\n".join(list_models()))' 2>&1 | tail -20
}

cmd_ask() {
  [[ $# -ge 1 ]] || die 'Usage: ./dev.sh ask "PROMPT" [MODEL]'
  ready
  "$PY" -c '
import sys
from gemini_access import get_model
try:
    print(get_model(sys.argv[2]).generate_content(sys.argv[1]))
except RuntimeError as e:
    sys.exit("Error: %s" % e)
' "$1" "${2:-$DEFAULT_MODEL}"
}

cmd_login()   { ensure_gcloud; do_login; }
cmd_set_url() { [[ $# -eq 1 ]] || die "Usage: ./dev.sh set-url https://gemini-app-....run.app"; find_python || die "Run ./dev.sh setup first."; save_url "$1"; }
cmd_help()    { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

cmd_apis() {
  ready
  local out
  out="$("$PY" -c 'from gemini_access import list_apis; print("\n".join(list_apis()))' 2>&1)" \
    || die "$(tail -1 <<<"$out")"
  if [[ -z "$out" ]]; then
    echo "No other APIs yet. Your admin adds them with ./admin.sh add-key NAME."
  else
    printf '%s\n' "$out"
    echo
    echo "In your code:  from gemini_access import api"
    echo "               r = api(\"$(head -1 <<<"$out")\").post(\"/path/from/the/api/docs\", json={...})"
  fi
}

case "$CMD" in
  setup)   cmd_setup ;;
  status)  cmd_status ;;
  models)  cmd_models ;;
  ask)     cmd_ask "$@" ;;
  apis)    cmd_apis ;;
  login)   cmd_login ;;
  set-url) cmd_set_url "$@" ;;
  help|-h|--help) cmd_help ;;
  *) echo "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac

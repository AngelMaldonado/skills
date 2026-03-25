#!/usr/bin/env bash
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
REPO="AngelMaldonado/skills"
BRANCH="main"
BASE_URL="https://api.github.com/repos/${REPO}/contents"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

# ─── Colors ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

info()  { printf "${CYAN}▸${RESET} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}⚠${RESET} %s\n" "$1"; }
fail()  { printf "${RED}✗${RESET} %s\n" "$1" >&2; exit 1; }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}install.sh${RESET} — Install Claude Code skills from ${REPO}

${BOLD}USAGE${RESET}
  curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh | bash -s -- <skill-name>
  # or
  ./install.sh <skill-name>
  ./install.sh --list

${BOLD}COMMANDS${RESET}
  <skill-name>    Install the specified skill into .claude/skills/ in the current directory
  --list, -l      List all available skills in the repo
  --help, -h      Show this help message

${BOLD}EXAMPLES${RESET}
  ./install.sh log-debugger          Install the log-debugger skill
  ./install.sh --list                List available skills

${BOLD}OPTIONS${RESET}
  --force, -f     Overwrite existing skill installation without prompting
  --global, -g    Install to ~/.claude/skills/ (available across all projects)

EOF
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

# List available skills by querying the GitHub API for top-level directories
list_skills() {
  info "Fetching available skills from ${REPO}..."
  local response
  response=$(curl -fsSL "${BASE_URL}/.claude/skills?ref=${BRANCH}" 2>/dev/null) \
    || fail "Failed to fetch repo contents. Check your network connection."

  local skills
  skills=$(echo "$response" \
    | grep '"name"' \
    | sed 's/.*"name": *"\([^"]*\)".*/\1/' \
  )

  if [ -z "$skills" ]; then
    warn "No skills found in the repo."
    return
  fi

  printf "\n${BOLD}Available skills:${RESET}\n\n"
  while IFS= read -r skill; do
    printf "  ${CYAN}•${RESET} %s\n" "$skill"
  done <<< "$skills"
  printf "\nInstall with: ${BOLD}./install.sh <skill-name>${RESET}\n\n"
}

# Recursively download all files from a directory in the repo
download_dir() {
  local remote_path="$1"
  local local_dir="$2"

  local response
  response=$(curl -fsSL "${BASE_URL}/${remote_path}?ref=${BRANCH}" 2>/dev/null) \
    || fail "Failed to fetch contents of '${remote_path}'. Does this skill exist?"

  # Parse JSON entries — each has "name", "type" (file/dir), "download_url"
  local names types urls
  names=$(echo "$response" | grep '"name"' | sed 's/.*"name": *"\([^"]*\)".*/\1/')
  types=$(echo "$response" | grep '"type"' | sed 's/.*"type": *"\([^"]*\)".*/\1/')
  urls=$(echo "$response"  | grep '"download_url"' | sed 's/.*"download_url": *"\([^"]*\)".*/\1/' | sed 's/null//')

  # Zip the three arrays together line by line
  paste <(echo "$names") <(echo "$types") <(echo "$urls") | while IFS=$'\t' read -r name type url; do
    if [ "$type" = "dir" ]; then
      mkdir -p "${local_dir}/${name}"
      download_dir "${remote_path}/${name}" "${local_dir}/${name}"
    elif [ "$type" = "file" ]; then
      info "Downloading ${name}..."
      curl -fsSL "$url" -o "${local_dir}/${name}" \
        || fail "Failed to download ${remote_path}/${name}"
    fi
  done
}

# ─── Parse args ──────────────────────────────────────────────────────────────
SKILL=""
FORCE=false
GLOBAL=false

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)     usage; exit 0 ;;
    --list|-l)     require_cmd curl; list_skills; exit 0 ;;
    --force|-f)    FORCE=true; shift ;;
    --global|-g)   GLOBAL=true; shift ;;
    -*)            fail "Unknown option: $1. Use --help for usage." ;;
    *)             SKILL="$1"; shift ;;
  esac
done

[ -z "$SKILL" ] && { usage; fail "Please specify a skill name."; }

# ─── Prerequisites ───────────────────────────────────────────────────────────
require_cmd curl
require_cmd node

# ─── Determine install location ─────────────────────────────────────────────
if $GLOBAL; then
  INSTALL_DIR="${HOME}/.claude/skills/${SKILL}"
else
  INSTALL_DIR=".claude/skills/${SKILL}"
fi

# ─── Check for existing installation ────────────────────────────────────────
if [ -d "$INSTALL_DIR" ] && ! $FORCE; then
  warn "Skill '${SKILL}' is already installed at ${INSTALL_DIR}"
  printf "    Overwrite? [y/N] "
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) info "Aborted."; exit 0 ;;
  esac
fi

# ─── Verify skill exists in repo ────────────────────────────────────────────
info "Checking if '${SKILL}' exists in ${REPO}..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/.claude/skills/${SKILL}?ref=${BRANCH}")
if [ "$HTTP_CODE" != "200" ]; then
  fail "Skill '${SKILL}' not found in ${REPO}. Run with --list to see available skills."
fi

# ─── Download ────────────────────────────────────────────────────────────────
info "Installing skill '${SKILL}' into ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
download_dir ".claude/skills/${SKILL}" "$INSTALL_DIR"

# ─── Make scripts executable ────────────────────────────────────────────────
find "$INSTALL_DIR" -name "*.sh" -exec chmod +x {} \;

# ─── Verify ──────────────────────────────────────────────────────────────────
if [ ! -f "${INSTALL_DIR}/SKILL.md" ]; then
  warn "Installation completed but SKILL.md was not found — the skill may not work correctly."
else
  ok "Skill '${SKILL}' installed successfully!"
  printf "\n"
  printf "  ${BOLD}Location:${RESET}  %s\n" "$(cd "$INSTALL_DIR" && pwd)"
  printf "  ${BOLD}Invoke:${RESET}    /${SKILL} in Claude Code\n"
  printf "\n"
fi

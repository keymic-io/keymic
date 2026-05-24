#!/usr/bin/env bash
# scripts/symphony-setup.sh
# Prepare this Mac as a Symphony worker for KeyMic.
# Run once before starting the Symphony orchestrator.
# See docs/superpowers/symphony-guide.md for context.

set -euo pipefail

WORKSPACE_ROOT="${HOME}/code/keymic-symphony-workspaces"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
fail() { echo -e "${RED}❌ $*${NC}"; ERRORS=$((ERRORS+1)); }

ERRORS=0

echo -e "\n${BOLD}=== KeyMic Symphony Worker Setup ===${NC}\n"

# -------------------------------------------------
# Step 1: Check required tools
# -------------------------------------------------
echo -e "${BOLD}[1/5] Checking required tools...${NC}"

if xcode-select -p &>/dev/null; then
    ok "Xcode Command Line Tools: $(xcode-select -p)"
else
    fail "Xcode Command Line Tools not found. Run: xcode-select --install"
fi

if command -v git &>/dev/null; then
    ok "git: $(git --version)"
else
    fail "git not found. Install Xcode Command Line Tools."
fi

if command -v gh &>/dev/null; then
    ok "gh: $(gh --version | head -1)"
else
    fail "gh (GitHub CLI) not found. Install with: brew install gh"
fi

if command -v codex &>/dev/null; then
    ok "codex: $(codex --version 2>/dev/null || echo 'installed')"
else
    fail "codex CLI not found. Install with: npm install -g @openai/codex"
fi

if command -v swift &>/dev/null; then
    ok "swift: $(swift --version 2>&1 | head -1)"
else
    fail "swift not found. Install Xcode or Xcode Command Line Tools."
fi

if command -v mise &>/dev/null; then
    ok "mise: $(mise --version)"
else
    warn "mise not installed (optional). Install with: brew install mise"
fi

echo ""

# -------------------------------------------------
# Step 2: Check authentication
# -------------------------------------------------
echo -e "${BOLD}[2/5] Checking authentication...${NC}"

if gh auth status &>/dev/null; then
    GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
    ok "GitHub CLI authenticated as: ${GH_USER}"
else
    fail "GitHub CLI not authenticated. Run: gh auth login"
fi

# Check SSH key for git operations
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    ok "SSH key authenticated with GitHub"
else
    warn "SSH key may not be set up for GitHub. Test with: ssh -T git@github.com"
fi

# Linear auth: no CLI check possible, just remind
warn "Linear API Key: ensure LINEAR_API_KEY env var or Symphony config is set"

echo ""

# -------------------------------------------------
# Step 3: Create workspace root
# -------------------------------------------------
echo -e "${BOLD}[3/5] Creating Symphony workspace root...${NC}"

if [ -d "${WORKSPACE_ROOT}" ]; then
    ok "Workspace root exists: ${WORKSPACE_ROOT}"
else
    mkdir -p "${WORKSPACE_ROOT}"
    ok "Created workspace root: ${WORKSPACE_ROOT}"
fi

echo ""

# -------------------------------------------------
# Step 4: Validate WORKFLOW.md exists in repo
# -------------------------------------------------
echo -e "${BOLD}[4/5] Validating KeyMic repository configuration...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/WORKFLOW.md" ]; then
    ok "WORKFLOW.md found at repo root"
else
    fail "WORKFLOW.md not found at ${REPO_ROOT}/WORKFLOW.md"
fi

if [ -f "${REPO_ROOT}/AGENTS.md" ]; then
    ok "AGENTS.md found (macOS event-tap safety guidelines)"
else
    warn "AGENTS.md not found — add it before running HID-related tickets"
fi

echo ""

# -------------------------------------------------
# Step 5: Print Symphony start command
# -------------------------------------------------
echo -e "${BOLD}[5/5] Ready to start Symphony${NC}"

cat <<EOF
${YELLOW}To start Symphony, run from this machine:${NC}

  symphony --workflow ${REPO_ROOT}/WORKFLOW.md \\
           --workspace-root ${WORKSPACE_ROOT}

Or if Symphony reads WORKFLOW.md automatically from the repo:

  cd ${REPO_ROOT}
  symphony start

${YELLOW}Recommended first run:${NC}
  - Set max_concurrent_agents: 1 in WORKFLOW.md (already set)
  - Start with a low-risk ticket (parser/model/store changes)
  - Review PR before merging
  - Do NOT automate: event-tap, Secure Input, signing, release

See docs/superpowers/symphony-guide.md for full details.
EOF

echo ""

# -------------------------------------------------
# Summary
# -------------------------------------------------
if [ "${ERRORS}" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✅ All checks passed — worker is ready for Symphony.${NC}\n"
else
    echo -e "${RED}${BOLD}❌ ${ERRORS} check(s) failed — fix the issues above before starting Symphony.${NC}\n"
    exit 1
fi

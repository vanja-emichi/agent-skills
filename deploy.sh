#!/bin/bash
# deploy.sh - Deploy WordPress agent-skills to Agent Zero
# Usage: ./deploy.sh [A0_SKILLS_DIR]
#
# Deploys all skills from this repo to an Agent Zero skills directory.
# Default target: /a0/skills/ (inside container)
# Can also target project-scoped skills or usr/skills/.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC="${SCRIPT_DIR}/skills"
A0_SKILLS_DIR="${1:-/a0/skills}"

if [ ! -d "$SKILLS_SRC" ]; then
  echo "Error: skills/ directory not found at $SKILLS_SRC"
  exit 1
fi

echo "Deploying WordPress agent-skills..."
echo "  Source: $SKILLS_SRC"
echo "  Target: $A0_SKILLS_DIR"
echo ""

# Count skills
SKILL_COUNT=0

for skill_dir in "$SKILLS_SRC"/*/; do
  skill_name=$(basename "$skill_dir")
  
  # Skip if no SKILL.md
  if [ ! -f "${skill_dir}SKILL.md" ]; then
    echo "  SKIP  $skill_name (no SKILL.md)"
    continue
  fi
  
  # Create target dir and copy
  target="${A0_SKILLS_DIR}/${skill_name}"
  mkdir -p "$target"
  
  # Sync files (preserve structure, delete removed files)
  rsync -a --delete "$skill_dir" "$target/"
  
  SKILL_COUNT=$((SKILL_COUNT + 1))
  echo "  ✓  $skill_name"
done

echo ""
echo "Deployed $SKILL_COUNT skills to $A0_SKILLS_DIR"
echo "Done."

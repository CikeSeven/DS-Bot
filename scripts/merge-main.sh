#!/bin/sh
# Bring the current branch up to date with origin/main.
#
#   scripts/merge-main.sh
#
# ds-bot/client.js is built from ds-bot/src/client, so a conflict in it is never
# resolved by hand: it is taken from main and rebuilt once the sources are merged.
# Any other conflict stops the script with the merge still open, to be resolved
# and committed as usual.
set -eu

root="$(git rev-parse --show-toplevel)"
cd "$root"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "merge-main: commit or stash your changes first" >&2
  exit 1
fi

git fetch origin main
if git merge --no-edit origin/main; then
  merged=1
else
  merged=0
fi

if [ "$merged" -eq 0 ]; then
  if git diff --name-only --diff-filter=U | grep -qx 'ds-bot/client.js'; then
    git checkout --theirs -- ds-bot/client.js
    git add ds-bot/client.js
  fi
  left="$(git diff --name-only --diff-filter=U)"
  if [ -n "$left" ]; then
    echo "merge-main: resolve these, then run 'npm run build' in ds-bot and commit:" >&2
    echo "$left" >&2
    exit 1
  fi
fi

# The bundle includes locked packages (deep-view), so a lockfile that changed with the
# merge, or a checkout that never installed, needs `npm ci` before the build.
if [ ! -d ds-bot/node_modules ] || ! git diff --quiet ORIG_HEAD -- ds-bot/package-lock.json; then
  (cd ds-bot && npm ci --no-fund --no-audit >/dev/null)
fi
# The merged sources may differ from both sides' bundles even without a conflict.
(cd ds-bot && npm run build >/dev/null)
git add ds-bot/client.js
if [ "$merged" -eq 0 ]; then
  git commit --no-edit
elif ! git diff --cached --quiet; then
  git commit -m "Rebuild client.js after merging main"
fi
echo "merge-main: up to date with origin/main"

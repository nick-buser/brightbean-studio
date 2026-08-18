#!/usr/bin/env bash
#
# Sync this fork with upstream (brightbeanxyz/brightbean-studio).
#
#   main  = pristine mirror of upstream. Never commit to it.
#   trunk = our real branch. Deployed to Railway. Our commits live here.
#
# Flow:  upstream/main --(fast-forward)--> main --(merge)--> trunk
#
# See docs/FORK-WORKFLOW.md for the why.
#
# Usage:
#   bin/sync-upstream.sh              # sync, merge into trunk, stop before pushing trunk
#   bin/sync-upstream.sh --push       # ...and push trunk (this DEPLOYS to Railway)
#   bin/sync-upstream.sh --check      # report drift only, read-only, changes nothing
#
set -euo pipefail

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/brightbeanxyz/brightbean-studio.git"
ORIGIN="origin"
MIRROR="main"
TRUNK="trunk"

PUSH_TRUNK=0
CHECK_ONLY=0
case "${1:-}" in
  --push)  PUSH_TRUNK=1 ;;
  --check) CHECK_ONLY=1 ;;
  ""|-h|--help)
           [ -n "${1:-}" ] && { sed -n '2,16p' "$0"; exit 0; } ;;
  *)       echo "unknown option: $1" >&2; sed -n '12,16p' "$0" >&2; exit 2 ;;
esac

cd "$(git rev-parse --show-toplevel)"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- preflight (read-only) -------------------------------------------------

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  say "adding missing '$UPSTREAM_REMOTE' remote"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  # Pushing to upstream should be impossible by accident.
  git remote set-url --push "$UPSTREAM_REMOTE" DISABLED
fi

say "fetching $UPSTREAM_REMOTE and $ORIGIN"
git fetch "$UPSTREAM_REMOTE" --prune --quiet
git fetch "$ORIGIN" --prune --quiet

# --- --check: pure report off remote-tracking refs, mutates nothing --------

if [ "$CHECK_ONLY" -eq 1 ]; then
  say "drift report (read-only)"
  row() { printf '  %-44s %s\n' "$1" "$2"; }
  row "upstream commits not yet in $ORIGIN/$MIRROR:" \
      "$(git rev-list --count "$ORIGIN/$MIRROR..$UPSTREAM_REMOTE/$MIRROR")"
  row "$ORIGIN/$MIRROR commits not yet in $ORIGIN/$TRUNK:" \
      "$(git rev-list --count "$ORIGIN/$TRUNK..$ORIGIN/$MIRROR")"
  row "our own commits on $ORIGIN/$TRUNK:" \
      "$(git rev-list --count "$ORIGIN/$MIRROR..$ORIGIN/$TRUNK")"

  STRAY="$(git rev-list --count "$UPSTREAM_REMOTE/$MIRROR..$ORIGIN/$MIRROR")"
  if [ "$STRAY" -ne 0 ]; then
    echo
    echo "  WARNING: $ORIGIN/$MIRROR has $STRAY commit(s) of its own — the mirror"
    echo "           invariant is broken. Run without --check for repair steps."
  fi
  exit 0
fi

# --- mutating from here: require a clean tree ------------------------------

ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if [ -n "$(git status --porcelain)" ]; then
  die "working tree is dirty. Commit or stash first — this script switches branches."
fi

# A fresh clone only gets the default branch; make sure the mirror exists locally.
if ! git show-ref --verify --quiet "refs/heads/$MIRROR"; then
  say "creating local '$MIRROR' tracking $ORIGIN/$MIRROR"
  git branch "$MIRROR" "$ORIGIN/$MIRROR"
fi

# --- guard: the mirror must have no commits of its own ---------------------
# If it does, the fast-forward below is impossible and the invariant is already
# broken. Report it rather than papering over it with a merge commit.
LOCAL_ONLY="$(git rev-list --count "$UPSTREAM_REMOTE/$MIRROR..$MIRROR")"
if [ "$LOCAL_ONLY" -ne 0 ]; then
  echo >&2
  git log --oneline "$UPSTREAM_REMOTE/$MIRROR..$MIRROR" >&2
  echo >&2
  die "'$MIRROR' has $LOCAL_ONLY commit(s) not in $UPSTREAM_REMOTE/$MIRROR (listed above).
       '$MIRROR' is supposed to be a pristine mirror; those commits belong on '$TRUNK'.
       To fix: cherry-pick them onto '$TRUNK', then reset the mirror:
         git switch $TRUNK && git cherry-pick <sha>...
         git switch $MIRROR && git reset --hard $UPSTREAM_REMOTE/$MIRROR
         git push --force-with-lease $ORIGIN $MIRROR"
fi

# --- step 1: fast-forward the mirror ---------------------------------------

BEHIND="$(git rev-list --count "$MIRROR..$UPSTREAM_REMOTE/$MIRROR")"
if [ "$BEHIND" -eq 0 ]; then
  say "step 1/3: '$MIRROR' already matches $UPSTREAM_REMOTE/$MIRROR — nothing to pull"
else
  say "step 1/3: fast-forwarding '$MIRROR' by $BEHIND commit(s)"
  git switch --quiet "$MIRROR"
  git merge --ff-only "$UPSTREAM_REMOTE/$MIRROR"
  git push --quiet "$ORIGIN" "$MIRROR"
  echo "  pushed $ORIGIN/$MIRROR"
fi

# --- step 2: merge the mirror into our trunk -------------------------------

say "step 2/3: merging '$MIRROR' into '$TRUNK'"
git switch --quiet "$TRUNK"
if git merge --no-edit "$MIRROR" >/dev/null 2>&1; then
  echo "  merged cleanly"
else
  echo
  echo "  MERGE CONFLICT — upstream changed files we also modified:"
  git diff --name-only --diff-filter=U | sed 's/^/    /'
  echo
  echo "  Resolve, then:  git add -A && git commit && git push $ORIGIN $TRUNK"
  echo "  Or abandon:     git merge --abort"
  exit 1
fi

# --- step 3: publish -------------------------------------------------------

AHEAD="$(git rev-list --count "$ORIGIN/$TRUNK..$TRUNK")"
if [ "$AHEAD" -eq 0 ]; then
  say "step 3/3: '$TRUNK' already up to date with $ORIGIN — nothing to push"
elif [ "$PUSH_TRUNK" -eq 1 ]; then
  say "step 3/3: pushing '$TRUNK' ($AHEAD commit(s)) — this triggers a Railway deploy"
  git push --quiet "$ORIGIN" "$TRUNK"
  echo "  pushed. Watch it with: railway logs --service web"
else
  say "step 3/3: NOT pushed — '$TRUNK' is $AHEAD commit(s) ahead of $ORIGIN"
  echo "  Pushing '$TRUNK' deploys to Railway, so review first:"
  echo "    git log --oneline $ORIGIN/$TRUNK..$TRUNK"
  echo "    git push $ORIGIN $TRUNK"
  echo "  Or re-run with --push to do it automatically."
fi

if [ "$ORIGINAL_BRANCH" != "$TRUNK" ] && git show-ref --verify --quiet "refs/heads/$ORIGINAL_BRANCH"; then
  git switch --quiet "$ORIGINAL_BRANCH"
  echo
  echo "(returned to '$ORIGINAL_BRANCH')"
fi

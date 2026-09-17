#!/bin/sh
#
# The one place the version stamp is computed. build_app.sh, the iOS archive,
# the Windows publish and the release workflow all read it, so the three
# platforms cannot drift apart the way they did before (macOS 1.4.0, iOS 1.0.0,
# Windows nothing at all). Prints four KEY=value lines:
#
#   APP_VERSION   on a v* tag, the tag without the v (v1.5.0 -> 1.5.0);
#                 otherwise the VERSION file verbatim.
#   BUILD_NUMBER  commits reachable from HEAD. Monotonic, which is what
#                 CFBundleVersion has to be for App Store Connect — a semver
#                 short version cannot serve, and a commit count since some
#                 file last changed can go backwards across branches.
#   GIT_SHA       short commit, "-dirty" when the tree has uncommitted changes.
#   BUILD_TIME    UTC, minute precision.
#
# Usage:  eval "$(sh scripts/version.sh)"              (from anywhere)
#         sh scripts/version.sh | tee -a "$GITHUB_OUTPUT"   (in Actions)
#
# Runs from any directory; resolves the repo root from its own location.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

GIT_SHA=unknown
if command -v git >/dev/null 2>&1; then
  GIT_SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
  if [ "$GIT_SHA" != unknown ] && [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    GIT_SHA="${GIT_SHA}-dirty"
  fi
fi

# In Actions the ref is authoritative; locally, ask git whether HEAD is tagged.
tag=""
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
  tag="${GITHUB_REF_NAME:-}"
elif command -v git >/dev/null 2>&1; then
  tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
fi

case "$tag" in
  v[0-9]*)
    APP_VERSION="${tag#v}"
    ;;
  *)
    APP_VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
    [ -n "$APP_VERSION" ] || APP_VERSION=0.0.0
    ;;
esac

BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%MZ)"

printf 'APP_VERSION=%s\nBUILD_NUMBER=%s\nGIT_SHA=%s\nBUILD_TIME=%s\n' \
  "$APP_VERSION" "$BUILD_NUMBER" "$GIT_SHA" "$BUILD_TIME"

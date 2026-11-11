#!/bin/sh
# Runs the macOS app's pixel and popover tests, which need the window server
# (a logged-in GUI session). Run before each release.
#
# The pixel tests draw their windows beneath the desktop picture, so nothing
# appears in front of you; the popover tests briefly show the real popover
# near the top-right of the main screen.
#
# A failing pixel test saves its render to $TMPDIR/pauselet-<name>.png.
set -eu
cd "$(dirname "$0")/.."
PAUSELET_VISUAL_TESTS=1 swift test --filter ReminderAppTests "$@"

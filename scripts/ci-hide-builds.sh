#!/bin/bash
# Keeps the FalconMail copies that CI and Release build on this Mac out of Spotlight, Launchpad
# and "Open With". The runner is the owner's own Mac: every build leaves a FalconMail.app in the
# runner's folders, and macOS lists each one as another FalconMail app.
#
#   scripts/ci-hide-builds.sh <runner _work folder>
#
# Takes every FalconMail.app under the folder out of Launch Services, then deletes the ones that
# are only build leftovers (Release builds, DMG staging). The Debug build cache is kept, since
# the next push builds on it, but lives in a folder Spotlight never indexes (".noindex").
# Nothing outside the runner's folder is touched: /Applications/FalconMail.app stays as it is.
set -u
WORK="${1:?usage: ci-hide-builds.sh <runner _work folder>}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$WORK" ] || exit 0
case "$(cd "$WORK" && pwd)" in
  /Applications|/Applications/*|"$HOME") echo "refusing to clean $WORK"; exit 0 ;;
esac

# Never index the runner's folders at all.
touch "$WORK/.metadata_never_index" 2>/dev/null || true

found=0
while IFS= read -r -d '' app; do
  found=$((found + 1))
  "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
  case "$app" in
    */ci-cache.noindex/*) ;;                     # the Debug build cache the next push reuses
    *) rm -rf "$app" && echo "removed $app" ;;   # a Release build or DMG staging copy
  esac
done < <(find "$WORK" -name 'FalconMail*.app' -type d -prune -print0 2>/dev/null)

# Old CI cache from before it moved into the unindexed folder.
if [ -d "$WORK/ci-cache/mc4mac" ]; then
  while IFS= read -r -d '' app; do "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true; done \
    < <(find "$WORK/ci-cache" -name 'FalconMail*.app' -type d -prune -print0 2>/dev/null)
fi

# Report every copy Spotlight lists, so the owner can see where the others come from.
echo "FalconMail copies Spotlight knows of:"
mdfind 'kMDItemCFBundleIdentifier == "com.falconmail.*"' 2>/dev/null | sed 's/^/  /'
echo "Launch Services entries:"
"$LSREGISTER" -dump 2>/dev/null | grep -E '^path: .*FalconMail[^/]*\.app' | sort -u | sed 's/^/  /' | head -60

# Forget entries for copies already deleted by earlier runs.
"$LSREGISTER" -gc >/dev/null 2>&1 || true
echo "FalconMail build copies taken out of Launch Services: $found"

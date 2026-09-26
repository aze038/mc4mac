#!/bin/bash
# Keeps the FalconMail copies built on this Mac out of Spotlight, Launchpad and "Open With".
# The CI runner is the owner's own Mac: every build, and every DMG made for a release, leaves a
# FalconMail.app that macOS lists as yet another FalconMail app.
#
#   scripts/ci-hide-builds.sh <runner _work folder>
#
# 1. Detaches the temporary disks create-dmg left mounted (/Volumes/dmg.XXXXXX).
# 2. Deletes the build leftovers inside the runner's own folder (Release builds, DMG staging);
#    the Debug build cache the next push reuses is kept, in a ".noindex" folder.
# 3. Takes every FalconMail copy but the installed /Applications/FalconMail.app out of Launch
#    Services, which is what Launchpad and "Open With" list. This deletes nothing: a copy opened
#    again is simply known again. Development builds outside the runner's folder are never deleted.
set -u
WORK="${1:?usage: ci-hide-builds.sh <runner _work folder>}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
INSTALLED=/Applications/FalconMail.app

# 1. create-dmg's temporary disks: named dmg.<random> and holding FalconMail.app.
for volume in /Volumes/dmg.*; do
  [ -d "$volume/FalconMail.app" ] || continue
  "$LSREGISTER" -u "$volume/FalconMail.app" >/dev/null 2>&1 || true
  hdiutil detach "$volume" -force >/dev/null 2>&1 && echo "detached $volume"
done

# 2. The runner's own leftovers.
if [ -d "$WORK" ]; then
  case "$(cd "$WORK" && pwd)" in
    /Applications|/Applications/*|"$HOME") echo "refusing to clean $WORK"; exit 0 ;;
  esac
  touch "$WORK/.metadata_never_index" 2>/dev/null || true
  while IFS= read -r -d '' app; do
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    case "$app" in
      */ci-cache.noindex/*) ;;                     # the Debug build cache the next push reuses
      *) rm -rf "$app" && echo "removed $app" ;;   # a Release build or DMG staging copy
    esac
  done < <(find "$WORK" -name 'FalconMail*.app' -type d -prune -print0 2>/dev/null)
fi

# 2b. Crash symbols: the release keeps each build's dSYM for the daily crash triage, ~60-90 MB a
#     version. Only the newest 3 versions are kept; nobody runs older ones once updates arrive.
SYMBOLS="$HOME/Library/Application Support/FalconMail Symbols"
if [ -d "$SYMBOLS" ]; then
  ls -1 "$SYMBOLS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | awk '{ v[NR] = $0 } END { for (i = 1; i <= NR - 3; i++) print v[i] }' | while read -r old; do
    rm -rf "${SYMBOLS:?}/$old" && echo "removed crash symbols of $old"
  done
  du -sh "$SYMBOLS" 2>/dev/null | sed 's/^/crash symbols kept: /'
fi

# 3. Every other copy Launch Services knows, installed app excepted.
forgotten=0
while IFS= read -r app; do
  [ "$app" = "$INSTALLED" ] && continue
  "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
  forgotten=$((forgotten + 1))
done < <("$LSREGISTER" -dump 2>/dev/null | sed -nE 's/^path: +(.*FalconMail[^/]*\.app) \(0x[0-9a-f]+\)$/\1/p' | sort -u)
"$LSREGISTER" -gc >/dev/null 2>&1 || true
echo "FalconMail copies taken out of Launchpad and Open With: $forgotten"

echo "Copies Launch Services still lists:"
"$LSREGISTER" -dump 2>/dev/null | grep -E '^path: .*FalconMail[^/]*\.app' | sort -u | sed 's/^/  /'
echo "Copies Spotlight still finds (development builds are left in place):"
mdfind 'kMDItemCFBundleIdentifier == "com.falconmail.*"' 2>/dev/null | sed 's/^/  /'

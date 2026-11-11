#!/bin/bash
# Usage: Scripts/check-linkage.sh <path-to-.app> <daily|livekit>
#
# Proves that an app linking one transport adapter did not pull in the other SDK, and that
# no second WebRTC is embedded. Two WebRTC builds in one process duplicate the
# un-prefixed RTC* Objective-C classes and crash calls at runtime.
#
# Fails (non-zero exit) unless:
#   daily   : Frameworks/Daily.framework present, no Frameworks/LiveKitWebRTC.framework,
#             and no LiveKit module symbols or LKRTC classes in the app's Mach-O images.
#   livekit : Frameworks/LiveKitWebRTC.framework present, no Frameworks/Daily.framework,
#             and no Daily or PipecatClientIOSDaily symbols in the app's Mach-O images.
#   always  : no Frameworks/WebRTC.framework, and no un-prefixed RTC* class defined in
#             more than one Mach-O image of the bundle.
set -u

if [ $# -ne 2 ] || [ ! -d "$1" ] || { [ "$2" != daily ] && [ "$2" != livekit ]; }; then
  echo "usage: $0 <path-to-.app> <daily|livekit>" >&2
  exit 2
fi

APP="${1%/}"
ADAPTER="$2"
FW="$APP/Frameworks"
status=0

fail() {
  echo "FAIL: $1"
  status=1
}

echo "Checking $APP (expected adapter: $ADAPTER)"
echo "Embedded frameworks in $FW:"
if [ -d "$FW" ]; then
  ls -1 "$FW" | sed 's/^/  /'
else
  echo "  (none)"
fi

# Mach-O images: the app binary, any *.dylib at the app root (Debug builds put the code in
# <App>.debug.dylib and a __preview.dylib), and each embedded framework's binary.
images=()
exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)
[ -n "$exe" ] && [ -f "$APP/$exe" ] && images+=("$APP/$exe")
for d in "$APP"/*.dylib; do
  [ -f "$d" ] && images+=("$d")
done
app_images=("${images[@]}")
if [ -d "$FW" ]; then
  for f in "$FW"/*.framework; do
    [ -d "$f" ] || continue
    fexe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$f/Info.plist" 2>/dev/null)
    [ -z "$fexe" ] && fexe=$(basename "$f" .framework)
    [ -f "$f/$fexe" ] && images+=("$f/$fexe")
  done
fi

# Frameworks.
if [ "$ADAPTER" = daily ]; then
  want=Daily.framework
  unwanted=LiveKitWebRTC.framework
  symbol_pattern='LiveKit|LKRTC'
  symbol_label="LiveKit or LKRTC"
else
  want=LiveKitWebRTC.framework
  unwanted=Daily.framework
  symbol_pattern='[^A-Za-z]Daily|PipecatClientIOSDaily|ConduitCallEngineDaily'
  symbol_label="Daily or PipecatClientIOSDaily"
fi

if [ -d "$FW/$want" ]; then
  echo "ok: Frameworks/$want present"
else
  fail "Frameworks/$want is missing"
fi
if [ -d "$FW/$unwanted" ]; then
  fail "Frameworks/$unwanted is embedded in a $ADAPTER-only app"
else
  echo "ok: Frameworks/$unwanted absent"
fi
if [ -d "$FW/WebRTC.framework" ]; then
  fail "Frameworks/WebRTC.framework is embedded (un-prefixed WebRTC collides with Daily's)"
else
  echo "ok: Frameworks/WebRTC.framework absent"
fi

# The other adapter's symbols, in the app's own images (not the SDK frameworks, which
# legitimately mention their own names).
if [ ${#app_images[@]} -eq 0 ]; then
  fail "no Mach-O images found in the app bundle"
fi
for img in "${app_images[@]}"; do
  hits=$(nm -m "$img" 2>/dev/null | grep -E "$symbol_pattern" | head -5)
  if [ -n "$hits" ]; then
    fail "$(basename "$img") references $symbol_label symbols:"
    echo "$hits" | sed 's/^/    /'
  else
    echo "ok: $(basename "$img") has no $symbol_label symbols"
  fi
done

# Duplicate un-prefixed RTC* classes. A defined ObjC class is an "_OBJC_CLASS_$_Name"
# symbol in an __objc_data section. Daily links its WebRTC with hidden visibility, so most
# of its RTC* classes are non-external: `nm -m` lists them, `nm -g` would miss them.
# LiveKitWebRTC's LKRTC* classes are prefixed and do not match.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for img in "${images[@]}"; do
  nm -m "$img" 2>/dev/null \
    | grep -E '__objc_data\).*_OBJC_CLASS_\$_RTC' \
    | sed -E 's/.*_OBJC_CLASS_\$_//' \
    | sort -u \
    | sed "s|^|$img	|" >> "$tmp"
done

dups=$(cut -f2 "$tmp" | sort | uniq -d)
if [ -n "$dups" ]; then
  fail "un-prefixed RTC* classes defined in more than one image:"
  while read -r cls; do
    [ -n "$cls" ] || continue
    echo "  $cls"
    awk -F'\t' -v c="$cls" '$2==c {print "    in " $1}' "$tmp"
  done <<< "$dups"
fi
total=$(cut -f2 "$tmp" | sort -u | wc -l | tr -d ' ')
echo "ok: scanned ${#images[@]} Mach-O images; $total distinct un-prefixed RTC* classes, none defined twice"

if [ $status -eq 0 ]; then
  echo "PASS: $ADAPTER-only linkage verified"
fi
exit $status

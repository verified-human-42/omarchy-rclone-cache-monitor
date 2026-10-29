#!/usr/bin/env bash
# Tests for rclone Cache Monitor. Run from anywhere: bash test/run.sh
# The live-mount test needs rclone and FUSE; it is skipped when either is missing.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
pass=0 fail=0
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

echo "manifest"
jq -e '.schemaVersion == 1 and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and (.id | startswith("omarchy.") | not)
       and (.kinds | index("bar-widget")) and .entryPoints.barWidget == "Panel.qml"' "$ROOT/manifest.json" >/dev/null \
  && ok "required fields and id rules" || bad "required fields and id rules"
if command -v omarchy >/dev/null; then
  omarchy plugin validate "$ROOT" >/dev/null 2>&1 && ok "omarchy plugin validate" || bad "omarchy plugin validate"
fi
[[ -z "$(find "$ROOT" -type l -not -path '*/.git/*')" ]] && ok "no symlinks" || bad "no symlinks"

echo "translations"
missing=$(grep -oE 'strings\.tn?\("[^"]+"' "$ROOT/Panel.qml" | sed -E 's/.*\("//; s/"$//' | sort -u |
  while read -r k; do jq -e --arg k "$k" 'has($k)' "$ROOT/i18n/en.json" >/dev/null || echo "$k"; done)
[[ -z "$missing" ]] && ok "every string key is in en.json" || bad "missing keys: $missing"

echo "plain text (no rich-text rendering of mount, file or app names)"
# Every Text-derived element must set textFormat: Text.PlainText, or untrusted names could render as markup.
texts=$(grep -cE '^\s*(Text|component [A-Za-z]+: Text) \{' "$ROOT/Panel.qml")
plain=$(grep -cE 'textFormat: Text\.PlainText' "$ROOT/Panel.qml")
[[ "$texts" -gt 0 && "$plain" -ge "$texts" ]] && ok "$texts Text elements, $plain PlainText" \
  || bad "$texts Text elements but only $plain PlainText"
grep -qE 'Text\.(RichText|StyledText|AutoText|MarkdownText)' "$ROOT/Panel.qml" && bad "rich text format used" || ok "no rich text formats"

echo "collector"
out=$(bash "$ROOT/rclone-cache-stats" --readers)
jq -e '(.ts | type) == "number" and (.hz | type) == "number" and (.mounts | type) == "array"
       and all(.mounts[]; (.mountpoint | type) == "string"
               and (.stats | IN("ok", "off", "auth", "unreachable", "no-process")))' <<< "$out" >/dev/null \
  && ok "snapshot shape ($(jq '.mounts | length' <<< "$out") mounts)" || bad "snapshot shape"

if command -v rclone >/dev/null && command -v fusermount3 >/dev/null && [[ -e /dev/fuse ]]; then
  tmp=$(mktemp -d)
  # A mount point and queued file whose names look like markup and contain quotes and spaces.
  mp="$tmp/mnt \"<b>bold</b>\" & <img src=x>"
  sock="${XDG_RUNTIME_DIR:-/tmp}/rcm-test-$$.sock"
  mkdir -p "$tmp/src" "$mp"
  rclone mount "$tmp/src" "$mp" --daemon --vfs-cache-mode full --vfs-write-back 30s --cache-dir "$tmp/cache" \
    --rc --rc-no-auth --rc-addr "unix://$sock" 2>/dev/null
  for _ in $(seq 1 20); do findmnt -n "$mp" >/dev/null && break; sleep 0.25; done
  name='<img src=x onerror=alert(1)> "q".txt'
  echo hi > "$mp/$name"
  sleep 1
  snap=$(bash "$ROOT/rclone-cache-stats" --readers)
  rec=$(jq -c --arg mp "$mp" '.mounts[] | select(.mountpoint == $mp)' <<< "$snap")
  [[ -n "$rec" ]] && ok "markup-named mount point found verbatim" || bad "markup-named mount point found verbatim"
  [[ "$(jq -r .stats <<< "$rec")" == ok ]] && ok "stats over unix socket" || bad "stats over unix socket"
  jq -e --arg n "$name" '.queue | index($n)' <<< "$rec" >/dev/null \
    && ok "markup-named queued file kept verbatim" || bad "markup-named queued file kept verbatim"
  fusermount3 -uz "$mp" 2>/dev/null
  pkill -f "rclone mount $tmp/src" 2>/dev/null
  rm -rf "$tmp" "$sock"
else
  echo "  skip  live mount test (needs rclone and FUSE)"
fi

echo
echo "$pass passed, $fail failed"
((fail == 0))

#!/bin/bash
# Assemble a before/after page from two Design Lab capture folders.
#
#   scripts/evidence.sh <before-dir> <after-dir> <out.html> [scene ...]
#
# Each scene present in both folders becomes a pair; captures are halved
# with sips so the page stays under the artifact size limit, then inlined.
set -euo pipefail
BEFORE="$1"; AFTER="$2"; OUT="$3"; shift 3
TMP=$(mktemp -d)
scenes=("$@")
{
cat <<'HTML'
<title>Visor Redesign Evidence</title>
<style>
:root{--bg:#f6f6f8;--ink:#1a1a1f;--dim:#6b6b76;--line:#e2e2e8;--accent:#6b46ef}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#0e0e12;--ink:#ececf1;--dim:#9a9aa6;--line:#26262e}}
:root[data-theme="dark"]{--bg:#0e0e12;--ink:#ececf1;--dim:#9a9aa6;--line:#26262e}
body{background:var(--bg);color:var(--ink);font:14px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:32px 40px}
h1{font-size:22px;margin:0 0 6px}p.lead{color:var(--dim);margin:0 0 28px;max-width:70ch}
section{margin:0 0 36px;border-top:1px solid var(--line);padding-top:20px}
h2{font-size:15px;margin:0 0 4px}.note{color:var(--dim);font-size:13px;margin:0 0 12px}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.pair figure{margin:0}.pair figcaption{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--dim);margin:0 0 6px}
.pair img{width:100%;height:auto;border:1px solid var(--line);border-radius:8px;display:block}
.only{grid-template-columns:1fr}
.changes{margin:0 0 32px;padding:0 0 0 18px;color:var(--ink);max-width:80ch}.changes li{margin:0 0 4px}.changes b{font-weight:600}
h1{letter-spacing:-.01em}
</style>
<h1>Visor Redesign Evidence</h1>
<p class="lead">Same fixtures, same theme (Midnight Purple), same 1512 × 982 point stage, rendered through the Design Lab at 2×. <strong>Before</strong> is the branch at the start of the redesign (builds 384–394); <strong>after</strong> is the current branch. Captures show layout, type, density and hierarchy. Focus, hover, caret, window ordering and the real notch's alignment are hardware checks and are not represented here. The two <em>study</em> pairs compare the shipping clarity direction with the retro study on identical content; the <em>reveal</em> and <em>practice</em> frames are quarter- and half-second sequences from the introduction.</p>
<ul class="changes">
<li><b>Tokens</b> — six type roles, 4pt spacing, controls at 24/28/32, radii by role, device-pixel hairlines, three surface levels, four motion presets.</li>
<li><b>Compact card</b> — the agent's identity leads; agent-first invitation with example requests; assistant replies unboxed at full measure; approvals on the accent.</li>
<li><b>Selectors</b> — one family for model, reasoning/speed, CLI model and agent; content-sized, then scrolling.</li>
<li><b>HUD</b> — conversation dominant at a 720pt measure; rails sized to content, collapsible, no borders; a thicker, darker glass.</li>
<li><b>Computer use</b> — task field in the composer's clothes; current action, numbered steps, Stop.</li>
<li><b>Introduction</b> — eight moments on the real product: wake, summon, connect, first task with approval, practice window, stop and continue, your turn, return.</li>
</ul>
HTML
for s in "${scenes[@]}"; do
  b="$BEFORE/$s.png"; a="$AFTER/$s.png"
  [ -f "$a" ] || continue
  echo "<section><h2>$s</h2>"
  note=$(python3 - "$AFTER/manifest.json" "$s" <<'PY'
import json,sys
try:
    for m in json.load(open(sys.argv[1])):
        if m.get("scenario")==sys.argv[2]: print(m.get("note","")); break
except Exception: pass
PY
)
  [ -n "$note" ] && echo "<p class=\"note\">$note</p>"
  if [ -f "$b" ]; then echo '<div class="pair">'; else echo '<div class="pair only">'; fi
  for side in before after; do
    if [ "$side" = before ]; then f="$b"; else f="$a"; fi
    [ -f "$f" ] || continue
    cp "$f" "$TMP/x.png"; sips -Z 1000 "$TMP/x.png" >/dev/null 2>&1
    data=$(base64 < "$TMP/x.png" | tr -d '\n')
    echo "<figure><figcaption>$side</figcaption><img alt=\"$s $side\" src=\"data:image/png;base64,$data\"></figure>"
  done
  echo "</div></section>"
done
} > "$OUT"
rm -rf "$TMP"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"

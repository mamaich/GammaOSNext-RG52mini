#!/bin/bash
# Обновляет один файл в форке через Contents API (берёт текущий sha и шлёт PUT).
# Дерево не трогается: там в это время может идти git lfs pull.
#   push-doc-update.sh <локальный файл> <путь в репозитории> <сообщение коммита>
set -euo pipefail

R=mamaich/GammaOSNext-RG52mini
BR=develop

F="$1"; P="$2"; MSG="$3"
[ -f "$F" ] || { echo "нет файла: $F" >&2; exit 1; }

ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$P")
SHA=$(gh api "repos/$R/contents/$ENC?ref=$BR" --jq .sha 2>/dev/null || true)

# Содержимое отдаём через --rawfile, а не аргументом командной строки: у
# отдельного аргумента предел 128 КБ, и файл покрупнее валил jq с
# "Argument list too long", а следом gh отвечал "Body should be a JSON object".
B64=$(mktemp)
trap 'rm -f "$B64"' EXIT
base64 -w0 "$F" > "$B64"

jq -n --arg m "$MSG

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" \
      --rawfile c "$B64" \
      --arg b "$BR" \
      --arg s "$SHA" \
      'if $s == "" then {message:$m, content:$c, branch:$b}
       else {message:$m, content:$c, branch:$b, sha:$s} end' \
  | timeout 240 gh api -X PUT "repos/$R/contents/$ENC" --input - --jq '.commit.sha'

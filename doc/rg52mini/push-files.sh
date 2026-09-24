#!/bin/bash
# Выкладывает несколько файлов одним коммитом через Git Data API.
# Рабочее дерево не трогается: в нём могут идти сборки и git lfs pull.
#
#   push-files.sh <owner/repo> <ветка> <сообщение> <локальный>:<путь в репо>[:режим] ...
set -euo pipefail

R="$1"; BR="$2"; MSG="$3"; shift 3
[ $# -gt 0 ] || { echo "нечего выкладывать" >&2; exit 1; }

BASE=$(gh api "repos/$R/git/ref/heads/$BR" --jq .object.sha)
TREE=$(gh api "repos/$R/git/commits/$BASE" --jq .tree.sha)
echo "база: $BASE (дерево $TREE)"

ENTRIES=$(mktemp); trap 'rm -f "$ENTRIES"' EXIT
: > "$ENTRIES"
for pair in "$@"; do
    LOC="${pair%%:*}"; REM="${pair#*:}"
    [ -f "$LOC" ] || { echo "нет файла: $LOC" >&2; exit 1; }
    # Режим не угадываем по файловой системе: на монтированном диске Windows
    # исполняемым выглядит всё. По умолчанию 100644, иначе третьим полем.
    MODE="${pair##*:}"
    case "$MODE" in 100644|100755) REM="${REM%:*}" ;; *) MODE=100644 ;; esac
    B64=$(mktemp); base64 -w0 "$LOC" > "$B64"
    BLOB=$(jq -n --rawfile c "$B64" '{content:$c, encoding:"base64"}' \
           | gh api -X POST "repos/$R/git/blobs" --input - --jq .sha)
    rm -f "$B64"
    echo "  blob $BLOB  $MODE  $REM"
    jq -nc --arg p "$REM" --arg m "$MODE" --arg s "$BLOB" \
       '{path:$p, mode:$m, type:"blob", sha:$s}' >> "$ENTRIES"
done

# --slurpfile отдаёт массив всех объектов из файла — это и есть tree.
NEWTREE=$(jq -n --arg b "$TREE" --slurpfile t "$ENTRIES" \
            '{base_tree:$b, tree:$t}' \
          | gh api -X POST "repos/$R/git/trees" --input - --jq .sha)
echo "новое дерево: $NEWTREE"

COMMIT=$(jq -n --arg m "$MSG

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" \
              --arg t "$NEWTREE" --arg p "$BASE" \
           '{message:$m, tree:$t, parents:[$p]}' \
         | gh api -X POST "repos/$R/git/commits" --input - --jq .sha)
echo "коммит: $COMMIT"

gh api -X PATCH "repos/$R/git/refs/heads/$BR" -f sha="$COMMIT" --jq .object.sha

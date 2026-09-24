#!/bin/bash
# Выкладывает несколько файлов одним коммитом через Git Data API.
# Рабочее дерево не трогается: в нём могут идти сборки и git lfs pull.
#
#   push-files.sh <owner/repo> <ветка> <сообщение> <локальный>:<путь в репо>[:режим] ...
set -euo pipefail

R="$1"; BR="$2"; MSG="$3"; shift 3
[ $# -gt 0 ] || { echo "нечего выкладывать" >&2; exit 1; }

# На большом репозитории создание дерева регулярно срывается по таймауту на
# стороне GitHub ("your request timed out", HTTP 422), причём загрузка блобов
# перед этим успевает пройти. Повторяем каждый шаг: блобы идемпотентны, повторная
# отправка того же содержимого даёт тот же sha.
retry() {
    local what="$1"; shift
    local i out
    for i in 1 2 3 4 5; do
        if out=$("$@" 2>&1); then printf '%s' "$out"; return 0; fi
        { echo "   $what: попытка $i не удалась"; echo "$out" | tail -1; } >&2
        sleep $(( i * 3 ))
    done
    return 1
}

BASE=$(retry "чтение ветки" gh api "repos/$R/git/ref/heads/$BR" --jq .object.sha)
TREE=$(retry "чтение дерева" gh api "repos/$R/git/commits/$BASE" --jq .tree.sha)
echo "база: $BASE (дерево $TREE)"

ENTRIES=$(mktemp); REQ=$(mktemp)
trap 'rm -f "$ENTRIES" "$REQ"' EXIT
: > "$ENTRIES"
for pair in "$@"; do
    LOC="${pair%%:*}"; REM="${pair#*:}"
    [ -f "$LOC" ] || { echo "нет файла: $LOC" >&2; exit 1; }
    # Режим не угадываем по файловой системе: на монтированном диске Windows
    # исполняемым выглядит всё. По умолчанию 100644, иначе третьим полем.
    MODE="${pair##*:}"
    case "$MODE" in 100644|100755) REM="${REM%:*}" ;; *) MODE=100644 ;; esac
    # Содержимое отдаём файлом, а не через конвейер: повтор должен иметь что
    # послать заново.
    base64 -w0 "$LOC" | jq -Rn --rawfile c /dev/stdin '{content:$c, encoding:"base64"}' > "$REQ"
    BLOB=$(retry "блоб $REM" gh api -X POST "repos/$R/git/blobs" --input "$REQ" --jq .sha)
    echo "  blob $BLOB  $MODE  $REM"
    jq -nc --arg p "$REM" --arg m "$MODE" --arg s "$BLOB" \
       '{path:$p, mode:$m, type:"blob", sha:$s}' >> "$ENTRIES"
done

# --slurpfile отдаёт массив всех объектов из файла — это и есть tree.
jq -n --arg b "$TREE" --slurpfile t "$ENTRIES" '{base_tree:$b, tree:$t}' > "$REQ"
NEWTREE=$(retry "создание дерева" gh api -X POST "repos/$R/git/trees" --input "$REQ" --jq .sha)
echo "новое дерево: $NEWTREE"

jq -n --arg m "$MSG

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" \
      --arg t "$NEWTREE" --arg p "$BASE" \
   '{message:$m, tree:$t, parents:[$p]}' > "$REQ"
COMMIT=$(retry "создание коммита" gh api -X POST "repos/$R/git/commits" --input "$REQ" --jq .sha)
echo "коммит: $COMMIT"

retry "перевод ветки" gh api -X PATCH "repos/$R/git/refs/heads/$BR" -f sha="$COMMIT" --jq .object.sha
echo

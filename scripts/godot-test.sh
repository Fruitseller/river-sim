#!/usr/bin/env bash

set -uo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
	echo "Aufruf: scripts/godot-test.sh <res://tests/…gd> <ERFOLGSMARKE>" >&2
	exit 2
fi
SKRIPT="$1"
MARKE="$2"

GODOT="${GODOT:-$(scripts/fetch-godot.sh --path)}"
if [[ ! -x "$GODOT" ]]; then
	echo "Godot nicht gefunden: $GODOT" >&2
	echo "Holen mit: scripts/fetch-godot.sh   (oder GODOT=/pfad/zu/godot setzen)" >&2
	exit 1
fi

if [[ "${GODOT_TEST_RENDER:-0}" == "1" ]]; then
	if command -v xvfb-run >/dev/null 2>&1; then
		RUNNER=(xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 "$GODOT" --path game --rendering-method gl_compatibility)
	else
		RUNNER=("$GODOT" --path game --rendering-method gl_compatibility)
	fi
else
	RUNNER=("$GODOT" --headless --path game)
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

"${RUNNER[@]}" --script "$SKRIPT" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

if grep -qE "FAIL[_A-Z]*:" "$LOG"; then
	echo "::error::$SKRIPT: Fehlschlag im Log gemeldet (Exit $RC) — der Test ist NICHT bestanden."
	[[ "$RC" -eq 0 ]] && RC=1
	exit "$RC"
fi

if grep -qF -- "$MARKE" "$LOG"; then
	if [[ "$RC" -ne 0 ]]; then
		echo "::warning::$SKRIPT: '$MARKE' gedruckt, Engine danach mit Exit $RC abgebrochen (Issue #61) — als bestanden gewertet."
	fi
	exit 0
fi

echo "::error::$SKRIPT: Erfolgsmarke '$MARKE' fehlt (Exit $RC) — der Test ist NICHT durchgelaufen."
[[ "$RC" -eq 0 ]] && RC=1
exit "$RC"

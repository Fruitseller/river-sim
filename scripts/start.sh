#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-stamp.sh --check

GODOT="${GODOT:-$(scripts/fetch-godot.sh --path)}"
if [[ ! -x "$GODOT" ]]; then
	echo "Godot nicht gefunden: $GODOT" >&2
	echo "Holen mit: scripts/fetch-godot.sh   (oder GODOT=/pfad/zu/godot setzen)" >&2
	exit 1
fi

LOCAL_LIBS="$PWD/.tools/debian-libs/usr/lib/x86_64-linux-gnu"
if [[ -d "$LOCAL_LIBS" ]]; then
	export LD_LIBRARY_PATH="$LOCAL_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

exec "$GODOT" --path game "$@"

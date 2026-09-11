#!/usr/bin/env bash
# view_run.sh — einen Lauf aus runs/ direkt im Viewer oeffnen.
#
# Pendant zu run_quadwild.sh: dort erzeugst du einen Lauf, hier siehst du
# ihn dir an, ohne den Pfad runs/<name>/output/<name>.obj von Hand
# zusammensuchen zu muessen.
#
# Der eigentliche Viewer (Evaluation/viewer.py) bleibt bewusst
# allgemein -- er kennt weder QuadWild noch runs/. Dieses Skript ist die
# Bruecke: es loest den Laufnamen zu den passenden Dateien auf und ruft
# viewer.py im richtigen venv damit auf.
#
# Aufruf:
#   ./view_run.sh <laufname>                zeigt output/<laufname>.obj
#   ./view_run.sh <laufname> --field         zeigt stattdessen die
#                                            *_rem.obj-Zwischendatei samt
#                                            Kreuzfeld (--rosy), so wie
#                                            beim Kreuzfeld-Anzeigen ueblich
#   ./view_run.sh <laufname> --ref           Eingabenetz zum Vergleich mit
#   ./view_run.sh                            listet verfuegbare Laeufe
#
# Alles ausser --field/--ref wird unveraendert an viewer.py durchgereicht
# (z.B. --curvature, --overlay, --rosy-stride).
#
# Pfade ggf. ueber QW_REPO / QW_RUNS / QW_EVAL setzen.

set -eo pipefail   # bewusst ohne -u: braucht hier Arrays, und macOS
                   # liefert nur Bash 3.2 aus (leere Arrays + set -u
                   # werfen dort "unbound variable")

REPO="${QW_REPO:-$HOME/dev/masterarbeit/quadwild-bimdf}"
RUNS="${QW_RUNS:-$REPO/runs}"
EVAL_DIR="${QW_EVAL:-$HOME/dev/masterarbeit/Evaluation}"
PYTHON="$EVAL_DIR/.venv/bin/python"

list_runs() {
    echo "Verfuegbare Laeufe unter $RUNS:" >&2
    if [ -d "$RUNS" ]; then
        for d in "$RUNS"/*/; do
            [ -d "$d" ] && echo "  $(basename "$d")" >&2
        done
    else
        echo "  (Verzeichnis existiert nicht)" >&2
    fi
}

if [ $# -eq 0 ]; then
    list_runs
    exit 0
fi

run_name="$1"; shift
run_dir="$RUNS/$run_name"

if [ ! -d "$run_dir" ]; then
    echo "view_run.sh: '$run_name' nicht gefunden unter $RUNS" >&2
    echo >&2
    list_runs
    exit 1
fi

result="$run_dir/output/${run_name}.obj"
if [ ! -f "$result" ]; then
    echo "view_run.sh: kein Endergebnis '$result' gefunden -- ist der Lauf" >&2
    echo "vollstaendig durchgelaufen?" >&2
    exit 1
fi

# Optionen einsammeln, Rest unveraendert an viewer.py weiterreichen
want_field=0
want_ref=0
extra=()
for a in "$@"; do
    case "$a" in
        --field) want_field=1 ;;
        --ref)   want_ref=1 ;;
        *)       extra+=("$a") ;;
    esac
done

args=("$result")

if [ "$want_field" = 1 ]; then
    rosy=$(find "$run_dir/output" -maxdepth 1 -iname "*_rem.rosy" 2>/dev/null | head -1)
    if [ -z "$rosy" ]; then
        echo "view_run.sh: kein Kreuzfeld (*_rem.rosy) in diesem Lauf gefunden," >&2
        echo "zeige stattdessen das Endergebnis." >&2
    else
        rem_obj="${rosy%.rosy}.obj"
        if [ -f "$rem_obj" ]; then
            args=("$rem_obj" --rosy "$rosy")
        fi
    fi
fi

if [ "$want_ref" = 1 ]; then
    ref=$(find "$run_dir/input" -maxdepth 1 -type f ! -iname "*.sharp" 2>/dev/null | head -1)
    if [ -z "$ref" ]; then
        echo "view_run.sh: keine Eingabedatei in $run_dir/input gefunden." >&2
    else
        case "$ref" in
            *.obj|*.off) args+=(--ref "$ref") ;;
            *) echo "view_run.sh: --ref uebersprungen -- Evaluation/meshio.py" >&2
               echo "kann nur .obj/.off laden, Eingabe ist $(basename "$ref")." >&2 ;;
        esac
    fi
fi

echo "Oeffne: ${args[0]}"
cd "$EVAL_DIR"
exec "$PYTHON" viewer.py "${args[@]}" "${extra[@]}"

#!/usr/bin/env bash
# view_run.sh — einen Lauf aus runs/ direkt im Viewer oeffnen.
#
# Pendant zu run_quadwild.sh: dort erzeugst du einen Lauf, hier siehst du
# ihn dir an, ohne den Pfad runs/<name>/output/<name>.obj von Hand
# zusammensuchen zu muessen.
#
# Der eigentliche Viewer (src/core/viewer.py) bleibt bewusst
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
EVAL_DIR="${QW_SRC:-${QW_EVAL:-$HOME/dev/masterarbeit/src}}"
PYTHON="$EVAL_DIR/.venv/bin/python"

# Laeufe liegen nach Eingabenetz gruppiert: runs/<netz>/<parameter>/.
# Ohne Argument werden die Netze aufgezaehlt, mit einem Netznamen dessen
# Laeufe -- sonst waere die Liste bei ueber hundert Laeufen unlesbar.
list_runs() {
    if [ ! -d "$RUNS" ]; then
        echo "  (Verzeichnis $RUNS existiert nicht)" >&2
        return
    fi
    if [ -n "${1:-}" ] && [ -d "$RUNS/$1" ]; then
        echo "Laeufe zu '$1':" >&2
        for d in "$RUNS/$1"/*/; do
            [ -d "$d" ] && echo "  $1/$(basename "$d")" >&2
        done
        return
    fi
    echo "Eingabenetze unter $RUNS (Aufruf: view_run.sh <netz>/<parameter>):" >&2
    for d in "$RUNS"/*/; do
        [ -d "$d" ] || continue
        n=$(find "$d" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d " ")
        printf "  %-56s %3s Laeufe\n" "$(basename "$d")" "$n" >&2
    done
}

if [ $# -eq 0 ]; then
    list_runs
    exit 0
fi

run_name="$1"; shift
run_dir="$RUNS/$run_name"

# Nur ein Netzname angegeben: dessen Laeufe auflisten statt zu scheitern.
if [ -d "$run_dir" ] && [ ! -d "$run_dir/output" ]; then
    list_runs "$run_name"
    exit 0
fi

if [ ! -d "$run_dir" ]; then
    echo "view_run.sh: '$run_name' nicht gefunden unter $RUNS" >&2
    echo >&2
    list_runs "${run_name%%/*}"
    exit 1
fi

# Das Endergebnis traegt Netz- und Parameternamen; der Ordner nur noch
# den Parameternamen, weil das Netz die Ebene darueber ist.
in_stem="$(basename "$(dirname "$run_dir")")"
result="$run_dir/output/${in_stem}__$(basename "$run_dir").obj"
[ -f "$result" ] || result="$run_dir/output/$(basename "$run_dir").obj"
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
    # input/ gibt es nur noch dort, wo die Datei sonst nirgends liegt --
    # die uebrigen Kopien sind entfallen, weil sie bitgleich in sources/
    # stehen. Deshalb dort nachsehen, wenn input/ fehlt.
    ref=$(find "$run_dir/input" -maxdepth 1 -type f ! -iname "*.sharp" 2>/dev/null | head -1)
    [ -n "$ref" ] || ref=$(ls "$REPO/sources/$in_stem".obj 2>/dev/null | head -1)
    if [ -z "$ref" ]; then
        echo "view_run.sh: keine Eingabe zu '$in_stem' gefunden." >&2
    else
        case "$ref" in
            *.obj|*.off) args+=(--ref "$ref") ;;
            *) echo "view_run.sh: --ref uebersprungen -- src/core/meshio.py" >&2
               echo "kann nur .obj/.off laden, Eingabe ist $(basename "$ref")." >&2 ;;
        esac
    fi
fi

echo "Oeffne: ${args[0]}"
cd "$EVAL_DIR"
# viewer.py liegt seit dem Paketumbau in core/, nicht mehr flach.
exec "$PYTHON" core/viewer.py "${args[@]}" "${extra[@]}"

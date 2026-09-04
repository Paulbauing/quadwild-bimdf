#!/usr/bin/env bash
#
# sweep_mainconfig.sh — dieselbe Geometrie mit mehreren main_config-Dateien
# durchrechnen und die Ergebnisse vergleichen.
#
# Duenne Schleife um run_quadwild.sh: Laufordner, Eingabekopie und
# Protokoll uebernimmt das Skript selbst. Hier kommt nur der Aufruf je
# Config dazu und am Ende eine Vergleichstabelle.
#
# Der Laufordner wird nicht geraten, sondern aus der Zeile "Laufordner:"
# der Ausgabe gelesen. run_quadwild.sh baut den Namen aus den gesetzten
# Parametern; ihn hier nachzubilden waere doppelte Buchfuehrung, die beim
# naechsten Schalter auseinanderlaeuft.
#
# AUFRUF
#   ./sweep_mainconfig.sh -i sources/plate.obj -noremesh -scale 6
#
# Alle Argumente gehen unveraendert an run_quadwild.sh, ergaenzt um
# -mainconfig je Durchlauf. Ein bereits gesetztes -mainconfig wird
# ueberschrieben.

set -uo pipefail

QUADWILD_SH="${QUADWILD_SH:-./run_quadwild.sh}"
REPO="${QW_REPO:-$HOME/dev/masterarbeit/quadwild-bimdf}"
CONFIG_DIR="$REPO/config/main_config"

# Nur .txt sind Hauptconfigs; die .json werden von ihnen referenziert.
#
# Was sich unterscheidet:
#   flow_noalign_lemon  Vorgabe von run_quadwild.sh. alignSingularities 0
#   flow                wie oben, aber alignSingularities 1
#   flow_virtual_half   dito, iso_weight 0.5 statt 1.0 in der JSON
#   flow_noalign        wie flow_noalign_lemon, Satsuma default statt lemon
#   ilp                 ILP statt Fluss, alignSingularities 1,
#                       fixedChartClusters 300
#   ilp_noalign         ILP ohne Singularitaetsausrichtung
#
# ZUR ERWARTUNG: die Eckenzahlen der Patches (3/4/5) entstehen im
# TRACING, also in Stufe 1, bevor eine dieser Configs ueberhaupt gelesen
# wird. Keine davon kann sie aendern. Was sie beeinflussen, ist die
# Zuweisung ganzzahliger Seitenlaengen in Stufe 2 — und damit, ob
# Patchseiten auf null kollabieren und Ecken verschmelzen.
CONFIGS=(
    flow_noalign_lemon
    flow
    flow_virtual_half
    ilp
    ilp_noalign
)

if [ $# -lt 1 ]; then
    echo "Aufruf: $0 -i <netz.obj> [weitere Argumente fuer run_quadwild.sh]" >&2
    exit 2
fi

# -mainconfig aus den durchgereichten Argumenten entfernen, falls gesetzt
ARGS=()
skip=0
for a in "$@"; do
    if [ $skip -eq 1 ]; then skip=0; continue; fi
    if [ "$a" = "-mainconfig" ]; then skip=1; continue; fi
    ARGS+=("$a")
done

SUMMARY=$(mktemp)
trap 'rm -f "$SUMMARY"' EXIT

for cfg in "${CONFIGS[@]}"; do
    cfgfile="$CONFIG_DIR/${cfg}.txt"
    if [ ! -f "$cfgfile" ]; then
        echo "[$cfg] uebersprungen: $cfgfile nicht vorhanden"
        continue
    fi

    echo "=============================================================="
    echo "[$cfg]"
    echo "=============================================================="

    start=$(date +%s)
    out=$("$QUADWILD_SH" "${ARGS[@]}" -mainconfig "$cfgfile" 2>&1)
    rc=$?
    end=$(date +%s)

    dir=$(printf '%s\n' "$out" | grep -a '^Laufordner:' | tail -1 \
          | sed 's/^Laufordner:[[:space:]]*//')

    if [ $rc -ne 0 ] || [ -z "$dir" ]; then
        echo "   FEHLGESCHLAGEN (rc=$rc)"
        printf '%s\n' "$out" | tail -20
        printf '%s\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' \
               "$cfg" "$((end - start))" >> "$SUMMARY"
        continue
    fi

    meta="$dir/run.meta.txt"
    echo "   fertig in $((end - start)) s"
    echo "   $dir"

    # QuadWild gibt die Statistik zweimal aus; der letzte Block gilt.
    g() { grep -a "$1" "$meta" 2>/dev/null | tail -1 | sed -E "s/.*$2.*/\1/"; }

    patches=$(g "Num Patches"            "Num Patches[[:space:]]+([0-9]+)")
    c3=$(g     "Patch with  3 corners"   "are:[[:space:]]*([0-9]+)")
    c4=$(g     "Patch with  4 corners"   "are:[[:space:]]*([0-9]+)")
    c5=$(g     "Patch with  5 corners"   "are:[[:space:]]*([0-9]+)")
    unsolv=$(g "FINAL THERE ARE"         "THERE ARE ([0-9]+) Unsolved")
    folds=$(g  "folds"                   "There are ([0-9]+) folds")
    iso=$(g    "Isometry term"           "Isometry term:[[:space:]]*([0-9.e+-]+)")
    sing=$(grep -a "Sing. alignment" "$meta" 2>/dev/null | tail -1 \
           | sed -E 's/.*alignment:[[:space:]]*([0-9]+ \/ [0-9]+).*/\1/')

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$cfg" "${patches:--}" "${c3:--}" "${c4:--}" "${c5:--}" \
        "${unsolv:--}" "${folds:--}" "${iso:--}" "${sing:--}" \
        "$((end - start))" >> "$SUMMARY"
done

echo
echo "=============================================================="
echo "Stufe 1 — Patchzerlegung (sollte ueber alle Configs GLEICH sein)"
echo "=============================================================="
printf '%-20s %6s %5s %5s %5s %7s\n' \
       "Config" "Patch" "3Eck" "4Eck" "5Eck" "Unsolv"
printf '%-20s %6s %5s %5s %5s %7s\n' \
       "--------------------" "------" "-----" "-----" "-----" "-------"
while IFS=$'\t' read -r cfg p c3 c4 c5 uns folds iso sing dur; do
    printf '%-20s %6s %5s %5s %5s %7s\n' "$cfg" "$p" "$c3" "$c4" "$c5" "$uns"
done < "$SUMMARY"

echo
echo "=============================================================="
echo "Stufe 2 — Quantisierung (hier wirkt die Config)"
echo "=============================================================="
printf '%-20s %10s %10s %6s %7s\n' \
       "Config" "SingAlign" "Isometry" "Folds" "Dauer"
printf '%-20s %10s %10s %6s %7s\n' \
       "--------------------" "----------" "----------" "------" "-------"
while IFS=$'\t' read -r cfg p c3 c4 c5 uns folds iso sing dur; do
    printf '%-20s %10s %10s %6s %6ss\n' "$cfg" "$sing" "$iso" "$folds" "$dur"
done < "$SUMMARY"

echo
echo "Weicht die obere Tabelle zwischen den Configs ab, hat die Config"
echo "frueher eingegriffen als erwartet — das waere fuer sich ein Befund."
echo
echo "Fuer moeglichst wenige EVs zaehlt, ob Patchseiten auf null"
echo "quantisiert werden und dadurch Ecken verschmelzen. Ein Anstieg"
echo "der Isometrie bei gleichzeitig weniger Faltungen deutet darauf"
echo "hin, dass die Quantisierung Struktur gegen Verzerrung getauscht"
echo "hat."
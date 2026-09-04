#!/usr/bin/env bash
# run_quadwild.sh — QuadWild (Bi-MDF-Fork) aufrufen und den Lauf protokollieren.
#
# Pendant zu Instant_Meshes_Paul/quadriflow/build/run_qf.sh: gleiche Idee,
# gleiche Handschrift, an QuadWilds zweistufige Pipeline angepasst.
#
# Jeder Lauf bekommt sein EIGENES Verzeichnis unter runs/, benannt nach
# Eingabedatei + den tatsaechlich gesetzten Parametern (kurze Kuerzel).
# Darin wieder getrennt: input/ (die Eingabekopie, zur Nachvollziehbarkeit)
# und output/ (alles, was QuadWild erzeugt -- Zwischenschritte mit ihren
# eigenen Suffixen plus EIN klar benanntes Endergebnis). Frueher landete
# alles lose nebeneinander in einem gemeinsamen Ordner; bei mehreren
# Parametervarianten war dann nicht mehr zu sehen, was zu welchem Lauf
# gehoert.
#
# Aufruf:
#   ./run_quadwild.sh -i input.obj \
#       [-sharp 35] [-alpha 0.01] [-alpha2 0.005] [-scale 1] [-noremesh] \
#       [-prepconfig DATEI] [-mainconfig DATEI] [-tag LABEL]
#
# Ergebnis liegt danach unter:
#   runs/<eingabename>__<parameter-kuerzel>/output/<derselbe-name>.obj
# (ohne gesetzte Parameter einfach runs/<eingabename>/...). Ein erneuter
# Lauf mit denselben Parametern ueberschreibt denselben Ordner --
# reproduzierbar statt anwachsend. -tag haengt ein frei gewaehltes Label
# an, wenn zwei Laeufe mit identischen CLI-Parametern trotzdem
# auseinandergehalten werden sollen (z.B. nach Handaenderung an einer
# -mainconfig-Datei).
#
# Anzahl Faces steuern: QuadWild hat kein -f wie quadriflow. Der Hebel ist
# scaleFact (Zielkantenlaenge = avgEdge(mesh) * scaleFact) -- groesser =
# groebere/weniger Quads, kleiner = mehr/feinere Quads, Faceanzahl skaliert
# grob mit 1/scaleFact^2. Es gibt ZWEI unabhaengige scaleFact-Werte in
# diesem Fork (Stufe 1 misst avgEdge auf dem Original, Stufe 2 auf dem
# bereits geremeshten Netz) -- darum patcht -scale beide Configs.
#
# Baut vorher neu (cmake --build), damit Codeaenderung und Lauf nicht
# auseinanderfallen. Mit QW_NOBUILD=1 laesst sich das ueberspringen.
#
# Nicht alle quadriflow-Flags (-mcf, -sat, -corner, -bw, -lambda, -rstrength, ...)
# haben eine Entsprechung in QuadWild -- das sind Parameter von
# quadriflows Feld-Loeser, nicht von QuadWilds Pipeline. Statt sie
# vorzutaeuschen, exponiert dieses Skript QuadWilds eigene Stellschrauben
# unter eigenen Namen (s.u.). Der Bauschritt und das Protokoll folgen
# aber demselben Muster wie bei quadriflow.
#
# Pfade ggf. ueber QW_REPO / QW_BUILD / QW_RUNS setzen.
#
# Kuerzel-Aufbau bewusst als String, nicht als Bash-Array: macOS liefert
# nur Bash 3.2 aus, und leere Arrays unter 'set -u' werfen dort einen
# Fehler ("unbound variable") -- ein bekannter Stolperstein.

set -euo pipefail

REPO="${QW_REPO:-$HOME/dev/masterarbeit/quadwild-bimdf}"
BUILD="${QW_BUILD:-$REPO/build}"
RUNS="${QW_RUNS:-$REPO/runs}"
QUADWILD_BIN="$BUILD/Build/bin/quadwild"
QFP_BIN="$BUILD/Build/bin/quad_from_patches"

usage() {
    echo "Aufruf: $0 -i input.obj [Optionen]" >&2
    echo "  -sharp GRAD        sharp_feature_thr (Default: 35)" >&2
    echo "  -alpha WERT        alpha fuer Remesh/Feld-Stufe (Default: 0.01)" >&2
    echo "  -alpha2 WERT       alpha fuer Quantisierungs-Stufe (Default: 0.005)" >&2
    echo "  -scale WERT        scaleFact in BEIDEN Stufen, steuert die Faceanzahl:" >&2
    echo "                     groesser = groebere/weniger Quads, kleiner = mehr Quads" >&2
    echo "                     (Faceanzahl skaliert grob mit 1/scaleFact^2; Default: 1)" >&2
    echo "  -noremesh          Remesh-Schritt ueberspringen (do_remesh 0)" >&2
    echo "  -prepconfig DATEI  eigene prep_config-Datei statt der obigen Flags" >&2
    echo "  -mainconfig DATEI  eigene main_config-Datei (Default: flow_noalign_lemon.txt)" >&2
    echo "  -tag LABEL         Laufordner zusaetzlich mit LABEL kennzeichnen" >&2
    echo "                     (fuer zwei Laeufe mit sonst identischen Parametern)" >&2
    exit 1
}

# Pfade auflösen, BEVOR wir ins Repo wechseln -- relative Pfade des
# Aufrufers muessen ja vom urspruenglichen Arbeitsverzeichnis aus gelten.
abspath() {
    local p="$1" dir base
    if [ -e "$p" ]; then
        realpath "$p"
    else
        dir=$(dirname "$p"); base=$(basename "$p")
        mkdir -p "$dir"
        printf '%s/%s\n' "$(realpath "$dir")" "$base"
    fi
}

# Kuerzel fuer den Laufnamen an $tokens anhaengen -- nur was tatsaechlich
# gesetzt wurde, sonst waeren auch unveraenderte Defaultlaeufe mit einem
# langen Parameter-Rattenschwanz benannt.
add_token() {
    if [ -z "$tokens" ]; then
        tokens="$1"
    else
        tokens="${tokens}_$1"
    fi
}

in_mesh=""
sharp_thr=35 alpha1=0.01 alpha2=0.005 scale_fact=1 do_remesh=1
prep_config="" main_config="" tag="" tokens=""
alpha2_set=0 scale_set=0

while [ $# -gt 0 ]; do
    case "$1" in
        -i) in_mesh=$(abspath "$2"); shift 2 ;;
        -sharp) sharp_thr="$2"; add_token "sharp${2}"; shift 2 ;;
        -alpha) alpha1="$2"; add_token "alpha1-${2}"; shift 2 ;;
        -alpha2) alpha2="$2"; alpha2_set=1; add_token "alpha2-${2}"; shift 2 ;;
        -scale) scale_fact="$2"; scale_set=1; add_token "scale${2}"; shift 2 ;;
        -noremesh) do_remesh=0; add_token "noremesh"; shift ;;
        -prepconfig) prep_config=$(abspath "$2")
                    add_token "prep-$(basename "$2" .txt)"; shift 2 ;;
        -mainconfig) main_config=$(abspath "$2")
                    add_token "main-$(basename "$2" .txt)"; shift 2 ;;
        -tag) tag="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "run_quadwild.sh: unbekannte Option '$1'" >&2; usage ;;
    esac
done

[ -n "$in_mesh" ] || usage
[ -f "$in_mesh" ] || { echo "run_quadwild.sh: Eingabe '$in_mesh' nicht gefunden." >&2; exit 1; }

# Erst bauen. Ohne das laeuft man Gefahr, eine Codeaenderung zu bewerten,
# die gar nicht im Binary steckt.
if [ -z "${QW_NOBUILD:-}" ]; then
    if [ ! -d "$BUILD" ]; then
        cmake -S "$REPO" -B "$BUILD" -DSATSUMA_ENABLE_BLOSSOM5=0
    fi
    if ! cmake --build "$BUILD" -j; then
        echo >&2
        echo "run_quadwild.sh: Build fehlgeschlagen, Lauf abgebrochen." >&2
        exit 1
    fi
fi

# Laufname: Eingabename + Kuerzel der gesetzten Parameter, z.B.
# fandisk__scale0.5_sharp30. Ohne gesetzte Parameter einfach fandisk.
in_stem=$(basename "$in_mesh")
in_stem="${in_stem%.*}"
in_ext="${in_mesh##*.}"

run_name="$in_stem"
[ -n "$tokens" ] && run_name="${in_stem}__${tokens}"
[ -n "$tag" ] && run_name="${run_name}__${tag}"

run_dir="$RUNS/$run_name"
if [ -d "$run_dir" ]; then
    echo "run_quadwild.sh: '$run_name' existiert schon, wird ueberschrieben."
fi
rm -rf "$run_dir"
mkdir -p "$run_dir/input" "$run_dir/output"
echo "Laufordner: $run_dir"

# Reines Referenzexemplar der Eingabe -- unabhaengig davon, unter
# welchem Namen QuadWild intern arbeitet.
cp "$in_mesh" "$run_dir/input/$(basename "$in_mesh")"

# Arbeitskopie in output/: QuadWild haengt an den *Eingabe*-Dateinamen
# feste Suffixe (_rem, _rem_p0, ..._quadrangulation) und schreibt
# grundsaetzlich NEBEN die Eingabe -- darum arbeitet die Pipeline direkt
# in output/, damit alle Zwischenergebnisse dort ohne Umkopieren landen.
work_mesh="$run_dir/output/${in_stem}.${in_ext}"
cp "$in_mesh" "$work_mesh"

# prep_config fuer Stufe 1 (Remesh + Feld) erzeugen, falls keine eigene
# Datei angegeben wurde -- so bleiben -sharp/-alpha/-scale/-noremesh direkt
# auf der Kommandozeile nutzbar, wie quadriflows eigene Flags.
if [ -z "$prep_config" ]; then
    prep_config="$run_dir/output/${in_stem}.prep_config.txt"
    {
        echo "do_remesh $do_remesh"
        echo "sharp_feature_thr $sharp_thr"
        echo "alpha $alpha1"
        echo "scaleFact $scale_fact"
    } > "$prep_config"
fi

if [ -z "$main_config" ]; then
    main_config="$REPO/config/main_config/flow_noalign_lemon.txt"
fi

# scaleFact/alpha der Stufe-2-Config patchen, wenn -scale/-alpha2 explizit
# gesetzt wurden -- sonst bliebe die Faceanzahl unveraendert, weil quad_from_patches
# sein eigenes scaleFact aus DIESER Datei liest, nicht aus der prep_config.
if [ "$scale_set" = 1 ] || [ "$alpha2_set" = 1 ]; then
    patched_main_config="$run_dir/output/${in_stem}.main_config.txt"
    cp "$main_config" "$patched_main_config"
    if [ "$scale_set" = 1 ]; then
        if grep -q '^scaleFact ' "$patched_main_config"; then
            sed -i '' "s/^scaleFact .*/scaleFact $scale_fact/" "$patched_main_config"
        else
            echo "scaleFact $scale_fact" >> "$patched_main_config"
        fi
    fi
    if [ "$alpha2_set" = 1 ]; then
        if grep -q '^alpha ' "$patched_main_config"; then
            sed -i '' "s/^alpha .*/alpha $alpha2/" "$patched_main_config"
        else
            echo "alpha $alpha2" >> "$patched_main_config"
        fi
    fi
    main_config="$patched_main_config"
fi

meta="$run_dir/run.meta.txt"
hash=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "unbekannt")
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null || true)" ]; then
    hash="$hash (uncommittete Aenderungen)"
fi

{
    echo "Datum:        $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Commit:       $hash"
    echo "Eingabe:      $in_mesh"
    echo "Laufordner:   $run_dir"
    echo "prep_config:  $prep_config"
    echo "main_config:  $main_config"
    echo
    echo "--- Stufe 1: quadwild ---"
    echo "Aufruf: quadwild $work_mesh 2 $prep_config"
    echo
} > "$meta"

# quadwild und quad_from_patches loesen Pfade in ihren Config-Dateien
# (flow_config_filename, satsuma_config_filename) relativ zum
# Arbeitsverzeichnis auf -- deshalb muss die Pipeline mit cwd=REPO laufen.
cd "$REPO"
"$QUADWILD_BIN" "$work_mesh" 2 "$prep_config" 2>&1 | tee -a "$meta"

rem_p0="$run_dir/output/${in_stem}_rem_p0.obj"
if [ ! -f "$rem_p0" ]; then
    echo "run_quadwild.sh: Stufe 1 hat kein ${in_stem}_rem_p0.obj erzeugt, breche ab." >&2
    exit 1
fi

{
    echo
    echo "--- Stufe 2: quad_from_patches (Bi-MDF) ---"
    echo "Aufruf: quad_from_patches $rem_p0 123 $main_config"
    echo
} >> "$meta"

"$QFP_BIN" "$rem_p0" 123 "$main_config" 2>&1 | tee -a "$meta"

result="$run_dir/output/${in_stem}_rem_p0_123_quadrangulation_smooth.obj"
if [ ! -f "$result" ]; then
    echo "run_quadwild.sh: Stufe 2 hat kein Ergebnis erzeugt, breche ab." >&2
    exit 1
fi

# Ein klar benanntes Endergebnis zusaetzlich zu den QuadWild-eigenen
# Suffixnamen -- das .mtl daneben bleibt unter seinem alten Namen liegen
# und wird trotzdem gefunden (gleiches Verzeichnis, relativer mtllib-Pfad).
final="$run_dir/output/${run_name}.obj"
cp "$result" "$final"

echo
echo "Ergebnis:  $final"
echo "Protokoll: $meta"

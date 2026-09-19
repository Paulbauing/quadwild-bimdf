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
#       [-sharp 35] [-alpha 0.01] [-alpha2 0.005] [-alphacurv 0.3] [-scale 1] [-noremesh] \
#       [-sharpfile DATEI] [-creaseangle 25] [-prepconfig DATEI] \
#       [-mainconfig DATEI] [-tag LABEL]
#
# Harte Constraints: -sharpfile uebergibt eine .sharp-Datei mit fest
# vorgegebenen Feature-Kanten (Format: erste Zeile Anzahl, dann je Zeile
# "Typ,FaceIndex,KantenIndex" mit Typ 0=konkav/1=konvex, Kante 0..2 --
# Indizes beziehen sich auf DAS Eingabenetz). Damit schaltet quadwild die
# automatische Winkel-Erkennung ab (UpdateSharp=false in functions.cpp).
# Das Remeshing darf dabei anbleiben: -sharpfile setzt crease_angle auf 0,
# und nur dieses nachgelagerte Aufraeumen (UpdateCoherentSharp) hatte die
# Vorgaben bisher wieder verworfen. Der Remesher selbst haelt sie.
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
    echo "  -sharpfile DATEI   .sharp-Datei mit vorgegebenen Feature-Kanten als" >&2
    echo "                     harte Constraints, statt automatischer Erkennung" >&2
    echo "                     ueber -sharp. Setzt -creaseangle automatisch auf 0" >&2
    echo "                     (sonst verwirft der Remesher die Vorgaben wieder)" >&2
    echo "  -creaseangle GRAD  Diederwinkel, unter dem der Remesher markierte" >&2
    echo "                     Feature-Kanten NACH dem Remeshing wieder verwirft" >&2
    echo "                     (AutoRemesher::UpdateCoherentSharp). 0 schaltet das" >&2
    echo "                     Aufraeumen ab und erhaelt auch glatte Linien" >&2
    echo "                     ohne Knick. Default 25 wie in QuadWild" >&2
    echo "  -alpha WERT        alpha fuer Remesh/Feld-Stufe (Default: 0.01)" >&2
    echo "  -alpha2 WERT       alpha fuer Quantisierungs-Stufe (Default: 0.005)" >&2
    echo "  -alphacurv WERT    Gewicht des Kruemmungsterms in der Kreuzfeld-" >&2
    echo "                     Glaettung: 0 = kein direkter Kruemmungseinfluss," >&2
    echo "                     groesser = staerker an Hauptkruemmungsrichtung" >&2
    echo "                     ausgerichtet, auf Kosten der Glattheit (Default: 0.3)" >&2
    echo "  -scale WERT        scaleFact in BEIDEN Stufen, steuert die Faceanzahl:" >&2
    echo "                     groesser = groebere/weniger Quads, kleiner = mehr Quads" >&2
    echo "                     (Faceanzahl skaliert grob mit 1/scaleFact^2; Default: 1)" >&2
    echo "  -noremesh          Remesh-Schritt ueberspringen (do_remesh 0)" >&2
    echo "  -mergepatches F    Patches unter F Zielquadflaechen (Q^2) ihrem" >&2
    echo "                     Nachbarn zuschlagen, zwischen den Stufen." >&2
    echo "                     Verschmolzen wird nur ueber NICHT-Feature-" >&2
    echo "                     Grenzen; die Featurelinien bleiben. Ohne" >&2
    echo "                     den Schalter passiert nichts. Sinnvoll: 0.25" >&2
    echo "  -mergeinradius Q   zusaetzlich Patches verschmelzen, die an der" >&2
    echo "                     dicksten Stelle schmaler als 2xQ sind. Faengt" >&2
    echo "                     BAENDER, die jede Flaechenschwelle bestehen." >&2
    echo "                     Sinnvoll: 0.5" >&2
    echo "  -noremoval         Pfad-Entfernung im Tracer ganz abschalten." >&2
    echo "                     Der Tracer entfernt sonst ueber die Haelfte" >&2
    echo "                     seiner Pfade wieder; Patchform spielt dabei" >&2
    echo "                     keine Rolle, deshalb entstehen lange Streifen." >&2
    echo "  -nofinalremoval    nur den abschliessenden Durchgang abschalten." >&2
    echo "  -minval N          kleinste erlaubte Zahl Patchecken (fest 3)." >&2
    echo "  -maxval N          groesste erlaubte Zahl Patchecken (fest 5)." >&2
    echo "  -cclark F          Catmull-Clark-Schwelle (fest 1)." >&2
    echo "  -drift F           erlaubte Abweichung vom Feld (fest 100)." >&2
    echo "  -sampleratio F     Dichte der Kandidaten-Emitter (fest 0.01)." >&2
    echo "                     Diese fuenf entscheiden die Patch-AUFTEILUNG," >&2
    echo "                     die danach unveraenderlich ist." >&2
    echo "  -patchsmooth N     Schritte der Patchrand-Glaettung im Tracer" >&2
    echo "                     (fest verdrahtet 10). Sie haelt die" >&2
    echo "                     Featurelinien punktgenau fest und bewegt nur" >&2
    echo "                     die uebrigen Patchgrenzen -- der Hebel fuer" >&2
    echo "                     ungeschickt liegende Patches. 0 schaltet ab." >&2
    echo "  -fixfeatures       beim Glaetten der Patchraender die von" >&2
    echo "                     aussen vorgegebenen Featurelinien FEST" >&2
    echo "                     halten und nur die uebrigen Patchraender" >&2
    echo "                     verschieben. Ohne den Schalter fasst die" >&2
    echo "                     Glaettung alle Patchraender an, denn sie" >&2
    echo "                     erkennt sie an IsFaceEdgeS -- und das" >&2
    echo "                     markiert Featurekanten mit." >&2
    echo "  -keepborder        beim Remeshing den Netzrand festhalten." >&2
    echo "                     Ohne das zieht collapseSurvivingMicroEdges" >&2
    echo "                     Randvertices auf die Kantenmitte, also ins" >&2
    echo "                     Innere -- gemessen 72 von 293 Randvertices" >&2
    echo "                     verschoben, mittlerer Randknick 5.0 -> 15.9" >&2
    echo "                     Grad. Wirkt nur mit aktivem Remesher." >&2
    echo "  -prepconfig DATEI  eigene prep_config-Datei statt der obigen Flags" >&2
    echo "  -patchscale DATEI  Faktor je Patch auf die Zielkantenlaenge." >&2
    echo "                     Erste Zeile die Patchzahl, dann ein Faktor je" >&2
    echo "                     Zeile in der Reihenfolge der .patch-Datei." >&2
    echo "                     1 laesst den Patch unveraendert, groesser macht" >&2
    echo "                     ihn groeber. Wird neben das _rem_p0.obj gelegt" >&2
    echo "                     und dort von quad_from_patches gelesen." >&2
    echo "  -chartsmooth N     Glaettungsdurchlaeufe je Patch nach der" >&2
    echo "                     Quadrangulierung, Patchrand fest (Default 0)" >&2
    echo "  -quadsmooth N      Glaettung der ganzen Quadrangulierung mit" >&2
    echo "                     FESTEN Patchraendern, also unter Erhalt der" >&2
    echo "                     Feature-Linien (Default 0)" >&2
    echo "  -finalsmooth N     Schritte der ABSCHLIESSENDEN Glaettung" >&2
    echo "                     (MultiCostraintSmooth, Vorgabe 30). Andere" >&2
    echo "                     Stufe als -chartsmooth und -quadsmooth:" >&2
    echo "                     die laufen in quadrangulationFromPatches," >&2
    echo "                     diese danach in main und kostet den" >&2
    echo "                     Grossteil der Laufzeit." >&2
    echo "  -minedge F         Untergrenze fuer die kuerzeste Kante einer" >&2
    echo "                     Facette beim Glaetten, als Anteil der" >&2
    echo "                     Zielkantenlaenge (Vorgabe 0.25). Greift nur" >&2
    echo "                     mit -foldguard. Zu klein laesst Vierecke am" >&2
    echo "                     Rand zusammendruecken." >&2
    echo "  -foldguard         Faltenpruefung in der abschliessenden" >&2
    echo "                     Glaettung: eine Vertexverschiebung, die ein" >&2
    echo "                     Viereck nicht-konvex macht oder umklappt," >&2
    echo "                     wird zurueckgenommen. Ohne sie entstehen die" >&2
    echo "                     Bowties genau hier -- gemessen 0 Bowties vor" >&2
    echo "                     und 6 nach dieser Stufe." >&2
    echo "  -quadsmoothfree N  dasselbe ohne feste Raender -- glaettet" >&2
    echo "                     staerker, verschiebt aber die Features" >&2
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
sharp_thr=35 alpha1=0.01 alpha2=0.005 alpha_curv=0.3 scale_fact=1 do_remesh=1
# Randvertices beim Remeshing festhalten (collapseSurvivingMicroEdges in
# AutoRemesher.h). Aus Vorgabe = bisheriges Verhalten.
keep_border=0 fix_features=0 patch_smooth=-1
trace_minval=-1 trace_maxval=-1 trace_cclark=-1 trace_drift=-1 trace_sampleratio=-1
trace_final_removal=-1 trace_pre_remove=-1
# Zwergpatches zwischen den beiden Stufen verschmelzen (patch_merge.py).
# Leer = aus; sonst die Flaechenschwelle in Q^2.
merge_patches=""
merge_inradius=""
# Glaettung der fertigen Quadrangulierung. Standen in quad_from_patches
# fest auf 0; chart_smooth laeuft je Patch mit festem Patchrand und
# zieht in sich gefaltete Vierecke wieder auf.
chart_smooth=0 quad_smooth_fixed=0 quad_smooth_free=0
# Abschliessende Glaettung (MultiCostraintSmooth in main.cpp). Andere Stufe
# als die drei obigen: die laufen in quadrangulationFromPatches, diese
# danach. 30 Schritte ohne Faltenpruefung waren fest verdrahtet.
final_smooth=30 fold_guard=0 min_edge=0.25
crease_angle=25 crease_set=0
prep_config="" main_config="" sharp_file="" patch_scale="" tag="" tokens=""
alpha2_set=0 scale_set=0

while [ $# -gt 0 ]; do
    case "$1" in
        -i) in_mesh=$(abspath "$2"); shift 2 ;;
        -sharp) sharp_thr="$2"; add_token "sharp${2}"; shift 2 ;;
        -sharpfile) sharp_file=$(abspath "$2"); add_token "SHARPFILETOKEN"; shift 2 ;;
        -patchscale) patch_scale=$(abspath "$2"); add_token "pscale"; shift 2 ;;
        -alpha) alpha1="$2"; add_token "alpha1-${2}"; shift 2 ;;
        -alpha2) alpha2="$2"; alpha2_set=1; add_token "alpha2-${2}"; shift 2 ;;
        -alphacurv) alpha_curv="$2"; add_token "acurv${2}"; shift 2 ;;
        -creaseangle) crease_angle="$2"; crease_set=1; add_token "crease${2}"; shift 2 ;;
        -scale) scale_fact="$2"; scale_set=1; add_token "scale${2}"; shift 2 ;;
        -chartsmooth) chart_smooth="$2"; add_token "csm${2}"; shift 2 ;;
        -quadsmooth) quad_smooth_fixed="$2"; add_token "qsm${2}"; shift 2 ;;
        -quadsmoothfree) quad_smooth_free="$2"; add_token "qsmf${2}"; shift 2 ;;
        -finalsmooth) final_smooth="$2"; add_token "fsm${2}"; shift 2 ;;
        -foldguard) fold_guard=1; add_token "fg"; shift ;;
        -minedge) min_edge="$2"; add_token "me${2}"; shift 2 ;;
        -noremesh) do_remesh=0; add_token "noremesh"; shift ;;
        -keepborder) keep_border=1; add_token "kb"; shift ;;
        -fixfeatures) fix_features=1; add_token "ff"; shift ;;
        -patchsmooth) patch_smooth="$2"; add_token "ps${2}"; shift 2 ;;
        -minval) trace_minval="$2"; add_token "mv${2}"; shift 2 ;;
        -maxval) trace_maxval="$2"; add_token "xv${2}"; shift 2 ;;
        -cclark) trace_cclark="$2"; add_token "cc${2}"; shift 2 ;;
        -drift) trace_drift="$2"; add_token "dr${2}"; shift 2 ;;
        -sampleratio) trace_sampleratio="$2"; add_token "sr${2}"; shift 2 ;;
        -noremoval) trace_final_removal=0; trace_pre_remove=0; add_token "norm"; shift ;;
        -nofinalremoval) trace_final_removal=0; add_token "nofr"; shift ;;
        -mergepatches) merge_patches="$2"; add_token "mp${2}"; shift 2 ;;
        -mergeinradius) merge_inradius="$2"; add_token "mi${2}"; shift 2 ;;
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

# Das -sharpfile-Kuerzel haengt vom Eingabenamen ab, der erst hier
# feststeht -- darum beim Parsen nur ein Platzhalter, der die Position
# in der Kuerzelkette (und damit die Reihenfolge der Flags) haelt.
if [ -n "$sharp_file" ]; then
    sharp_stem=$(basename "$sharp_file" .sharp)
    # Begleitdatei zum Netz (gleicher Stem) -> "sharpfile" reicht, sonst
    # waere der Name doppelt. Abweichender Stem -> mitnehmen, sonst ist
    # nicht erkennbar, welche Vorgabe im Lauf steckt.
    if [ "$sharp_stem" = "$in_stem" ]; then
        tokens="${tokens/SHARPFILETOKEN/sharpfile}"
    else
        tokens="${tokens/SHARPFILETOKEN/sharpfile-${sharp_stem}}"
    fi
fi

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
if [ -n "$sharp_file" ]; then
    cp "$sharp_file" "$run_dir/input/$(basename "$sharp_file")"
fi

# Arbeitskopie in output/: QuadWild haengt an den *Eingabe*-Dateinamen
# feste Suffixe (_rem, _rem_p0, ..._quadrangulation) und schreibt
# grundsaetzlich NEBEN die Eingabe -- darum arbeitet die Pipeline direkt
# in output/, damit alle Zwischenergebnisse dort ohne Umkopieren landen.
work_mesh="$run_dir/output/${in_stem}.${in_ext}"
cp "$in_mesh" "$work_mesh"

# Nicht der Remesher selbst verwirft vorgegebene Feature-Kanten -- er
# haelt sie (userSelectedCreases=true in AutoRemesher.h). Es ist das
# Aufraeumen DANACH: UpdateCoherentSharp loescht jede markierte Kante,
# deren Diederwinkel unter creaseAngle liegt. Glatte Ridge-Linien haben
# Winkel 0 und fallen damit komplett heraus. Gemessen an einem Testnetz:
# Feature-Laenge 10.79 vorher -> 4.10 mit creaseAngle 25, aber 10.68 mit 0,
# und das bei aktivem Remeshing (min. Innenwinkel 0.0 -> 14.1 Grad, keine
# entarteten Dreiecke mehr). Darum bei -sharpfile automatisch auf 0,
# solange nichts anderes verlangt wurde.
if [ -n "$sharp_file" ] && [ "$crease_set" = "0" ]; then
    crease_angle=0
    echo "run_quadwild.sh: -sharpfile gesetzt -> crease_angle 0 (sonst wuerde"
    echo "der Remesher die vorgegebenen Feature-Kanten nachtraeglich verwerfen)."
fi

# prep_config fuer Stufe 1 (Remesh + Feld) erzeugen, falls keine eigene
# Datei angegeben wurde -- so bleiben -sharp/-alpha/-scale/-noremesh direkt
# auf der Kommandozeile nutzbar, wie quadriflows eigene Flags.
if [ -z "$prep_config" ]; then
    prep_config="$run_dir/output/${in_stem}.prep_config.txt"
    {
        echo "do_remesh $do_remesh"
        echo "keep_border $keep_border"
        echo "fix_feature_borders $fix_features"
        echo "patch_smooth $patch_smooth"
        echo "trace_minval $trace_minval"
        echo "trace_maxval $trace_maxval"
        echo "trace_cclark $trace_cclark"
        echo "trace_drift $trace_drift"
        echo "trace_sampleratio $trace_sampleratio"
        echo "trace_final_removal $trace_final_removal"
        echo "trace_pre_remove $trace_pre_remove"
        echo "sharp_feature_thr $sharp_thr"
        echo "alpha $alpha1"
        echo "scaleFact $scale_fact"
        echo "alpha_curv $alpha_curv"
        echo "crease_angle $crease_angle"
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
    for zeile in "chartSmoothingIterations $chart_smooth" \
                 "quadrangulationFixedSmoothingIterations $quad_smooth_fixed" \
                 "quadrangulationNonFixedSmoothingIterations $quad_smooth_free" \
                 "finalSmoothSteps $final_smooth" \
                 "finalSmoothFoldGuard $fold_guard" \
                 "finalSmoothMinEdge $min_edge"; do
        schluessel=${zeile%% *}
        if grep -q "^$schluessel " "$patched_main_config"; then
            sed -i '' "s/^$schluessel .*/$zeile/" "$patched_main_config"
        else
            echo "$zeile" >> "$patched_main_config"
        fi
    done

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
# Die .sharp-Datei erkennt quadwild an der Endung unter den optionalen
# Positionsargumenten ab Index 3 (quadwild.cpp), nicht ueber die Config.
if [ -n "$sharp_file" ]; then
    "$QUADWILD_BIN" "$work_mesh" 2 "$prep_config" "$sharp_file" 2>&1 | tee -a "$meta"
else
    "$QUADWILD_BIN" "$work_mesh" 2 "$prep_config" 2>&1 | tee -a "$meta"
fi

rem_p0="$run_dir/output/${in_stem}_rem_p0.obj"
# quad_from_patches sucht die Faktordatei als Geschwisterdatei des Netzes,
# also <netz>.patchscale -- deshalb erst hier kopieren, nach Stufe 1.
if [ -n "$patch_scale" ]; then
    cp "$patch_scale" "$run_dir/output/${in_stem}_rem_p0.patchscale"
    cp "$patch_scale" "$run_dir/input/$(basename "$patch_scale")"
fi
if [ ! -f "$rem_p0" ]; then
    echo "run_quadwild.sh: Stufe 1 hat kein ${in_stem}_rem_p0.obj erzeugt, breche ab." >&2
    exit 1
fi

# --- Zwergpatches verschmelzen (zwischen den Stufen) ---------------------
#
# QuadWilds Tracer prueft die GROESSE eines Patches nie -- beurteilt werden
# Eckenzahl, Genus, Emitter und Catmull-Clark-Tauglichkeit. Entsprechend
# entstehen Patches aus zwei Dreiecken, die trotzdem quantisiert werden
# muessen (MIN_SUBDIVISION_VALUE 1) und die duennen Quads erzeugen.
# patch_merge.py schlaegt sie ihrem Nachbarn zu -- ueber eine NICHT-Feature-
# Grenze, die Featurelinien bleiben also unangetastet.
if [ -n "$merge_patches" ] || [ -n "$merge_inradius" ]; then
    [ -n "$merge_patches" ] || merge_patches=0
    # patch_merge.py liegt in diesem Repo (tools/) und kommt mit numpy aus.
    # Frueher lag es im Auswertungs-Repo, und der Aufruf brauchte dessen
    # Pfad und dessen venv -- eine Abhaengigkeit ueber die Repogrenze fuer
    # ein Skript, das ausschliesslich hier gebraucht wird.
    merge_py="$REPO/tools/patch_merge.py"
    merge_bin="${QW_PYTHON:-python3}"
    if [ -f "$merge_py" ]; then
        {
            echo
            echo "--- Zwischenschritt: patch_merge.py ---"
            echo "Aufruf: patch_merge.py ${in_stem}_rem_p0 --min-area $merge_patches --scale $scale_fact"
            echo
        } >> "$meta"
        merge_args=(--min-area "$merge_patches" --scale "$scale_fact")
        [ -n "$merge_inradius" ] && merge_args+=(--min-inradius "$merge_inradius")
        "$merge_bin" "$merge_py" "$run_dir/output/${in_stem}_rem_p0" \
            "${merge_args[@]}" 2>&1 | tee -a "$meta"
    else
        echo "run_quadwild.sh: $merge_py nicht gefunden, ueberspringe -mergepatches" >&2
    fi
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

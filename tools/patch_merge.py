# -*- coding: utf-8 -*-
"""patch_merge.py -- Zwergpatches in ihren Nachbarn verschmelzen.

WOZU. QuadWilds Tracer prueft die GROESSE eines Patches nie. Beurteilt
werden Eckenzahl, Genus, Emitter und Catmull-Clark-Tauglichkeit; die
Flaeche kommt in keinem Kriterium vor (max_patch_area ist im Quelltext
auskommentiert, ein Minimum gibt es gar nicht). Entsprechend entstehen
Patches aus zwei Dreiecken. Quantisiert werden muessen sie trotzdem --
MIN_SUBDIVISION_VALUE 1 gibt jeder Patchseite mindestens eine
Unterteilung -- und daraus werden die duennen Quads.

Gemessen an der Sickenplatte (scale 3, Q = 3 x mittlere Kantenlaenge):
8 von 68 Patches liegen unter 1 Q^2, vier davon unter 0.05 Q^2. Diese
vier bestehen aus 2 bis 5 Dreiecken, haben je GENAU EINEN Nachbarn
ueber eine Nicht-Feature-Grenze, und ihre drei Ecken liegen untereinander
weniger als eine halbe Quadkante auseinander.

FLAECHE IST DAS FALSCHE MASS ALLEIN. Ein Patch kann gross und trotzdem
unbrauchbar sein: gemessen ein Band von 3.04 Q^2 Flaeche bei 18.6 Q
Umfang -- ein halbes Quad breit und acht lang. Es faellt durch jede
Flaechenschwelle und ist doch der schlechteste Patch des Netzes.
Deshalb gibt es zwei Kriterien, und eines genuegt:

  --min-area       Flaeche in Q^2
  --min-inradius   groesster Abstand einer Facettenmitte zum Patchrand,
                   in Q. Das ist die halbe Breite an der dicksten Stelle;
                   unter 0.5 Q passt quer keine einzige Quadreihe hinein.

WAS HIER PASSIERT. Ein Zwerg wird seinem einzigen freien Nachbarn
zugeschlagen: seine Facetten bekommen dessen Patchnummer. Die
Featuregrenzen des Zwergs bleiben damit Grenzen des vergroesserten
Patches -- die Featurelinien werden NICHT angetastet, nur die
kuenstliche Trennlinie quer dazu verschwindet.

Verschmolzen wird nur, wenn der Zwerg GENAU EINEN freien Nachbarn hat.
Bei mehreren waere die Wahl willkuerlich und koennte den Patch in eine
ungeschickte Form ziehen; solche Faelle bleiben stehen.

ECKEN. Der vergroesserte Patch erbt die Vereinigung beider Eckensaetze,
beschraenkt auf das, was danach noch auf seinem Rand liegt -- und DANN
werden die Ecken gestrichen, an denen der Rand gar nicht mehr abknickt.

Der zweite Schritt ist nicht Kosmetik. Ohne ihn erbt jeder vergroesserte
Patch sechs Ecken, darunter die, die allein wegen des Zwergs existierte,
und ein Sechseck erzwingt mehr Singularitaeten als ein Fuenfeck und ein
Dreieck zusammen. Gemessen ohne diesen Schritt: 4 Zwerge verschmolzen,
dafuer die irregulaeren Vertices von 47 auf 65 und acht nicht-konvexe
Vierecke, wo vorher keines war -- ein Verlustgeschaeft.

UNTERGRENZE. Gestrichen wird nur, solange genug Ecken uebrig bleiben.
Ohne diese Bremse kam ein verschmolzener Patch mit NULL Ecken heraus --
sein Rand lief nach dem Merge ueberall glatt durch, also fiel jede
Kandidatenecke durch die Knickpruefung. Ein Patch ohne Ecken hat keine
Seiten, die sich quantisieren liessen; Stufe 2 haette ihn nicht
verarbeiten koennen. Behalten werden deshalb immer die mit dem
groessten Knick, mindestens min_corners viele.

Die Schwelle 45 Grad ist QuadWilds eigene: FindCorners entscheidet
nicht ueber einen Winkel, sondern darueber, ob die beiden anliegenden
Randkanten auf DIESELBE Kreuzfeldachse schnappen (HasOrthogonalCross in
edge_direction_table.h). Die Snapgrenze von GetClosestDirTo liegt bei
45 Grad -- darunter laeuft der Rand gerade durch, darueber knickt er.

Aufruf:
    python patch_merge.py PREFIX [--min-area 0.25] [--scale 3] [--dry-run]

PREFIX ist der Pfad ohne Endung, also z.B.
    .../output/netz_rem_p0
Gelesen werden PREFIX.obj/.patch/.corners/.feature, geschrieben werden
PREFIX.patch und PREFIX.corners (die alten als .patch.bak/.corners.bak).
"""

import argparse
import collections
import shutil
import sys
from pathlib import Path

import numpy as np



def load_obj(pfad):
    """Wavefront-OBJ lesen; nur v- und f-Zeilen, Indizes ab 0.

    ABSICHTLICH DOPPELT. Dieselbe Funktion steht als meshio.load_obj im
    Auswertungs-Repo, und dort ist meshio die einzige Stelle, die
    Dateiformate kennt. Dieses Skript ruft run_quadwild.sh zwischen
    QuadWilds beiden Stufen auf -- es soll ohne das andere Repo und ohne
    dessen venv laufen, und dafuer sind sechsundzwanzig Zeilen
    OBJ-Parser der guenstigere Preis als eine Abhaengigkeit ueber die
    Repogrenze. numpy genuegt damit als einzige Voraussetzung.

    Wer das Format aendert, muss beide Stellen anfassen. Das Format
    aendert sich nicht.
    """
    vertices, faces = [], []
    with open(pfad, encoding="utf-8", errors="replace") as fh:
        for zeile in fh:
            teile = zeile.split()
            if not teile or teile[0].startswith("#"):
                continue
            if teile[0] == "v":
                vertices.append([float(teile[1]), float(teile[2]), float(teile[3])])
            elif teile[0] == "f":
                faces.append([int(t.split("/")[0]) - 1 for t in teile[1:]])
    if not vertices:
        raise ValueError(f"keine Vertices in {pfad!r}")
    return {"vertices": np.asarray(vertices, dtype=np.float64), "faces": faces}



def lies_patch(pfad):
    tok = Path(pfad).read_text().split()
    n = int(tok[0])
    return np.array([int(x) for x in tok[1:1 + n]], dtype=np.int64)


def lies_corners(pfad):
    vals = [int(x) for x in Path(pfad).read_text().split()]
    i, n = 1, vals[0]
    out = []
    for _ in range(n):
        k = vals[i]; i += 1
        out.append(list(vals[i:i + k])); i += k
    return out


def schreib_patch(pfad, patch):
    with open(pfad, "w") as fh:
        fh.write(f"{len(patch)}\n")
        for p in patch:
            fh.write(f"{int(p)}\n")


def schreib_corners(pfad, corners):
    with open(pfad, "w") as fh:
        fh.write(f"{len(corners)}\n")
        for c in corners:
            fh.write(f"{len(c)}\n")
            for v in c:
                fh.write(f"{int(v)}\n")


def lies_feature(pfad, F):
    kanten = set()
    with open(pfad) as fh:
        fh.readline()
        for zeile in fh:
            t = zeile.strip().split(",")
            if len(t) < 2:
                continue
            f, e = int(t[0]), int(t[1])
            tri = F[f]
            kanten.add(frozenset((tri[e], tri[(e + 1) % 3])))
    return kanten


def randkanten(F):
    """Kante -> Liste der anliegenden Facetten."""
    ef = collections.defaultdict(list)
    for i, f in enumerate(F):
        for j in range(3):
            ef[frozenset((f[j], f[(j + 1) % 3]))].append(i)
    return ef


def rand_nachbarn(ef, menge):
    """Randvertex -> seine Nachbarn ENTLANG des Randes der Facettenmenge."""
    nb = collections.defaultdict(set)
    for k, fl in ef.items():
        drin = (fl[0] in menge) if len(fl) == 1 \
            else ((fl[0] in menge) != (fl[1] in menge))
        if not drin:
            continue
        a, b = tuple(k)
        nb[a].add(b)
        nb[b].add(a)
    return nb


def randknick(V, nb, v):
    """Knickwinkel des Patchrandes an v; 180 bei mehr als zwei Nachbarn.

    Mehr als zwei Randnachbarn heisst: dort treffen drei Patchraender
    zusammen. Eine solche Ecke ist strukturell und wird nie gestrichen,
    deshalb der Maximalwert.
    """
    ns = list(nb.get(v, ()))
    if len(ns) != 2:
        return 180.0
    d1 = V[ns[0]] - V[v]
    d2 = V[ns[1]] - V[v]
    n1, n2 = np.linalg.norm(d1), np.linalg.norm(d2)
    if n1 < 1e-14 or n2 < 1e-14:
        return 180.0
    c = float(np.dot(d1 / n1, d2 / n2))
    return 180.0 - np.degrees(np.arccos(min(max(c, -1.0), 1.0)))


def ecken_waehlen(V, nb, kandidaten, grenze_grad, min_corners=4):
    """Kandidaten auf die echten Ecken eindampfen, aber nie unter
    min_corners. Behalten wird nach Knick, groesster zuerst."""
    bew = sorted(((randknick(V, nb, v), v) for v in kandidaten), reverse=True)
    behalten = [v for w, v in bew if w > grenze_grad]
    for w, v in bew:
        if len(behalten) >= min_corners:
            break
        if v not in behalten:
            behalten.append(v)
    return sorted(behalten)


def patch_rand(ef, patch, menge):
    """Randvertices der Facettenmenge (als Patch aufgefasst)."""
    rand = set()
    for k, fl in ef.items():
        if len(fl) == 1:
            if fl[0] in menge:
                rand.update(k)
        elif (fl[0] in menge) != (fl[1] in menge):
            rand.update(k)
    return rand


def merge(prefix, min_area, scale, corner_angle=45.0, min_inradius=0.0,
          min_corners=4, verbose=True):
    prefix = Path(prefix)
    sh = load_obj(str(prefix.with_suffix(".obj")))
    V, F = sh["vertices"], sh["faces"]
    patch = lies_patch(prefix.with_suffix(".patch"))
    corners = lies_corners(prefix.with_suffix(".corners"))
    featE = lies_feature(prefix.with_suffix(".feature"), F)

    P = V[np.asarray(F)]
    flaeche = 0.5 * np.linalg.norm(
        np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0]), axis=1)
    kante = np.mean([np.linalg.norm(P[:, i] - P[:, (i + 1) % 3], axis=1).mean()
                     for i in range(3)])
    Q = scale * kante
    npat = int(patch.max()) + 1
    A = np.array([flaeche[patch == p].sum() / (Q * Q) for p in range(npat)])

    ef = randkanten(F)

    # Inradius je Patch: groesster Abstand einer Facettenmitte zum Rand.
    mitte = P.mean(axis=1)
    grenz = collections.defaultdict(list)
    for k, fl in ef.items():
        if len(fl) == 1:
            grenz[patch[fl[0]]].append(k)
        elif patch[fl[0]] != patch[fl[1]]:
            grenz[patch[fl[0]]].append(k)
            grenz[patch[fl[1]]].append(k)
    inradius = np.zeros(npat)
    for q in range(npat):
        idx = np.nonzero(patch == q)[0]
        if len(idx) == 0 or not grenz[q]:
            continue
        RA = np.array([V[tuple(k)[0]] for k in grenz[q]])
        RB = np.array([V[tuple(k)[1]] for k in grenz[q]])
        RAB = RB - RA
        C = mitte[idx]
        t = np.clip(((C[:, None, :] - RA[None]) * RAB[None]).sum(2)
                    / np.maximum((RAB * RAB).sum(1)[None], 1e-30), 0, 1)
        d = np.linalg.norm(C[:, None, :] - (RA[None] + t[..., None] * RAB[None]),
                           axis=2).min(axis=1)
        inradius[q] = d.max() / Q

    frei = collections.defaultdict(collections.Counter)
    for k, fl in ef.items():
        if len(fl) != 2 or k in featE:
            continue
        a, b = patch[fl[0]], patch[fl[1]]
        if a != b:
            frei[a][b] += 1
            frei[b][a] += 1

    if verbose:
        print(f"{npat} Patches, Q = {Q:.5f} (scale {scale:g})")
        print(f"Flaeche in Q^2: Median {np.median(A):.2f}, min {A.min():.3f}, "
              f"unter {min_area:g}: {int((A < min_area).sum())}")

    def schlecht(q):
        return A[q] < min_area or (min_inradius > 0 and inradius[q] < min_inradius)

    n_merge = 0
    # duennste zuerst -- ein Band verschmilzt besser, solange seine
    # Nachbarn noch unveraendert sind
    for p in sorted(range(npat), key=lambda q: (inradius[q], A[q])):
        if not schlecht(p) or not (patch == p).any():
            continue
        nb = [q for q in frei[p] if patch[patch == q].size > 0]
        if len(nb) != 1:
            if verbose:
                print(f"   Patch {p} ({A[p]:.2f} Q^2, Inradius {inradius[p]:.2f} Q): "
                      f"{len(nb)} freie Nachbarn -- uebersprungen")
            continue
        ziel = nb[0]
        menge = set(np.nonzero((patch == p) | (patch == ziel))[0])
        rand = patch_rand(ef, patch, menge)
        kand = sorted((set(corners[p]) | set(corners[ziel])) & rand)
        nb = rand_nachbarn(ef, menge)
        neu = ecken_waehlen(V, nb, kand, corner_angle, min_corners)
        if verbose:
            print(f"   Patch {p} ({A[p]:.2f} Q^2, Inradius {inradius[p]:.2f} Q, "
                  f"{int((patch == p).sum())} Dreiecke) -> Patch {ziel}; "
                  f"Ecken {len(corners[p])}+{len(corners[ziel])} -> {len(kand)}"
                  f" -> {len(neu)} nach Knickpruefung")
        patch[patch == p] = ziel
        corners[ziel] = neu
        corners[p] = []
        n_merge += 1

    if n_merge == 0:
        if verbose:
            print("nichts zu verschmelzen")
        return patch, corners, 0

    # leere Patches entfernen und luecklos neu nummerieren
    lebt = [p for p in range(npat) if (patch == p).any()]
    um = {p: i for i, p in enumerate(lebt)}
    patch = np.array([um[p] for p in patch], dtype=np.int64)
    corners = [corners[p] for p in lebt]
    if verbose:
        print(f"{n_merge} verschmolzen, {npat} -> {len(lebt)} Patches")
        k = [len(c) for c in corners]
        print(f"Ecken je Patch: min {min(k)}, max {max(k)}, "
              f"Verteilung {dict(sorted(collections.Counter(k).items()))}")
    return patch, corners, n_merge


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("prefix", help="Pfad ohne Endung, z.B. .../netz_rem_p0")
    p.add_argument("--min-area", type=float, default=0.25,
                   help="Patches unter dieser Flaeche (in Q^2) verschmelzen. "
                        "Q ist die Zielkantenlaenge. Vorgabe 0.25.")
    p.add_argument("--scale", type=float, default=3.0,
                   help="scaleFact des Laufs -- bestimmt Q. Vorgabe 3.")
    p.add_argument("--min-inradius", type=float, default=0.0, metavar="Q",
                   help="Patches, die an ihrer dicksten Stelle schmaler als "
                        "2 x diesen Wert sind, ebenfalls verschmelzen. In "
                        "Zielkantenlaengen. Faengt BAENDER, die jede "
                        "Flaechenschwelle bestehen: gemessen 3.04 Q^2 bei "
                        "18.6 Q Umfang und 0.23 Q Inradius. 0 schaltet ab.")
    p.add_argument("--corner-angle", type=float, default=45.0, metavar="GRAD",
                   help="Ecken des vergroesserten Patches streichen, an denen "
                        "der Rand um weniger als so viel abknickt. 45 ist "
                        "QuadWilds eigene Schwelle (Snapgrenze des "
                        "Kreuzfeldes). 0 behaelt alle Ecken.")
    p.add_argument("--min-corners", type=int, default=4, metavar="N",
                   help="so viele Ecken behaelt ein verschmolzener Patch "
                        "mindestens, auch wenn sein Rand glatt durchlaeuft. "
                        "Unter 3 kann Stufe 2 nicht quantisieren.")
    p.add_argument("--dry-run", action="store_true",
                   help="nur rechnen, nichts schreiben")
    args = p.parse_args(argv)

    patch, corners, n = merge(args.prefix, args.min_area, args.scale,
                              args.corner_angle, args.min_inradius,
                              args.min_corners)
    if n == 0 or args.dry_run:
        if args.dry_run:
            print("(--dry-run, nichts geschrieben)")
        return 0
    pre = Path(args.prefix)
    for e in (".patch", ".corners"):
        shutil.copy(pre.with_suffix(e), str(pre.with_suffix(e)) + ".bak")
    schreib_patch(pre.with_suffix(".patch"), patch)
    schreib_corners(pre.with_suffix(".corners"), corners)
    print(f"geschrieben: {pre.with_suffix('.patch')}\n"
          f"             {pre.with_suffix('.corners')}\n"
          f"(Sicherungen mit Endung .bak)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# -*- coding: utf-8 -*-
"""region_field.py -- Kreuzfeld je Featureregion ohne ueberzaehlige Singularitaeten.

WOZU. QuadWilds Tracer legt Separatrizen nur dort, wo das Kreuzfeld eine
Singularitaet hat (sie ist ein Emitter, und ein Patch mit Emitter gilt als
ungueltig). Am verbreiterten 175er-Blech (scale 4) lagen 38.4 der 44.4 Q
Separatrizen in Regionen, die von ihren Ecken her GAR KEINE Singularitaet
brauchen -- vier Ecken, Index 0 --, im Feld aber ein Paar Valenz 3 + Valenz
5 trugen. Diese Dipole sind ein Artefakt der Feldglaettung: der gleich
geformte Quadrant gegenueber hat keinen.

Fuer Stufe 2 spielt das Feld keine Rolle mehr, Bi-MDF quantisiert nur
Patches und Ecken. Also genuegt es, dem Tracer ein Feld zu geben, das in
jeder Region genau die Singularitaeten traegt, die Poincare-Hopf verlangt.

WIE. Je Region wird der Feldwinkel theta als REELLE, stetige Groesse
harmonisch interpoliert (Paralleltransport ueber jede gemeinsame Kante),
mit dem Randwinkel als Vorgabe: Dreiecke mit Feature- oder Randkante
folgen deren Richtung. Eine reelle harmonische Funktion auf einer
Scheibe hat keine Singularitaet. Siehe reell().

DER NAHELIEGENDE WEG GEHT NICHT. u = exp(4 i theta) komplex harmonisch
zu interpolieren (harmonisch()) ist genau das, was QuadWilds Glaettung
schon tut -- gemessen auf 1e-4 Grad dasselbe Feld, mit denselben Dipolen.
Eine komplexwertige harmonische Funktion darf Nullstellenpaare haben.

WELCHE REGIONEN. Die, deren Randknicke sich zu genau vier Ecken runden
lassen (ecken(); nachgestellt werden nur uneindeutige Knicke zwischen 30
und 75 Grad) und deren QuadWild-Feld trotzdem eine Singularitaet traegt.
Regionen, die von ihren Ecken her Singularitaeten brauchen (3 oder 5
Ecken), und Ringe (zwei Randschleifen) behalten QuadWilds Feld.

GEMESSEN (scale 4, -noremesh), ohne -> mit:
  verbreitertes 175er-Blech  Patches 75 -> 56, 4-Eck-Anteil 47 -> 84 %,
                             irregulaere Vertices 59 -> 31, kleinster
                             Winkel 14.0 -> 37.6, Separatrizen 44 -> 4 Q,
                             Feature-Abstand p90 0.35 -> 0.38 h
  175er 1105                 irregulaer 51 -> 33, kleinster Winkel
                             17.7 -> 27.5, aber 2 Quads mit SV > 5 und
                             Feature-Abstand p90 0.38 -> 0.42 h
  Sickenplatte               nur 2 Regionen geaendert, Ergebnis
                             SCHLECHTER (nicht-konvex 2 -> 9). Die Stelle
                             liegt in einem Ring, dessen Feld unveraendert
                             ist -- das Tracing dort aendert sich, weil die
                             Pfadentfernung global laeuft.

Aufruf:
    python region_field.py STEM [--alle] [--aus DATEI]

STEM ist der Pfad ohne Endung, z.B. .../output/netz_rem. Gelesen werden
STEM.obj, STEM.sharp und STEM.rosy; geschrieben wird STEM.rosy (das alte
als STEM.rosy.bak) oder --aus.
"""

import argparse
import collections
import shutil
import sys
from pathlib import Path

import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spla


def load_obj(pfad):
    V, F = [], []
    with open(pfad, encoding="utf-8", errors="replace") as fh:
        for zeile in fh:
            t = zeile.split()
            if not t:
                continue
            if t[0] == "v":
                V.append([float(t[1]), float(t[2]), float(t[3])])
            elif t[0] == "f":
                F.append([int(s.split("/")[0]) - 1 for s in t[1:]])
    return np.asarray(V, float), np.asarray(F, np.int64)


def lies_sharp(pfad, F):
    """.sharp: Anzahl, dann je Zeile typ,facette,kante."""
    kanten = set()
    zeilen = Path(pfad).read_text().split()
    for z in zeilen[1:]:
        t = z.split(",")
        if len(t) < 3:
            continue
        f, e = int(t[1]), int(t[2])
        kanten.add(frozenset((int(F[f][e]), int(F[f][(e + 1) % 3]))))
    return kanten


def lies_rosy(pfad):
    tok = Path(pfad).read_text().split()
    n = int(tok[0])
    return np.asarray(tok[2:2 + 3 * n], float).reshape(n, 3)


def schreib_rosy(pfad, U):
    with open(pfad, "w") as fh:
        fh.write(f"{len(U)}\n4\n")
        for u in U:
            fh.write(f"{u[0]:.6f} {u[1]:.6f} {u[2]:.6f}\n")


class Netz:
    """Rahmen, Kantennachbarschaft und Transport je Dreieck."""

    def __init__(self, V, F):
        self.V, self.F = V, F
        P = V[F]
        n = np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0])
        self.N = n / np.linalg.norm(n, axis=1, keepdims=True)
        # Rahmen an EINER globalen Richtung ausrichten (x-Achse in die
        # Dreiecksebene projiziert). Mit der ersten Kante als Rahmen ist der
        # Versatz zwischen Nachbarn beliebig; einzeln auf +-180 Grad
        # gefaltet, summiert er sich um einen Vertex zu 2 pi m statt zum
        # Winkeldefekt, und das reelle Feld bekommt dort eine
        # Scheinsingularitaet. Mit gemeinsamer Bezugsrichtung sind die
        # Versaetze klein. Voraussetzung: kein Dreieck steht senkrecht zur
        # x-Achse -- fuer die Bleche (Hoehenfelder) erfuellt; sonst wird
        # auf die y-Achse ausgewichen.
        X = np.array([1.0, 0.0, 0.0])
        Y = np.array([0.0, 1.0, 0.0])
        e1 = X - (self.N @ X)[:, None] * self.N
        schlecht = np.linalg.norm(e1, axis=1) < 0.3
        e1[schlecht] = (Y - (self.N[schlecht] @ Y)[:, None] * self.N[schlecht])
        self.E1 = e1 / np.linalg.norm(e1, axis=1, keepdims=True)
        self.E2 = np.cross(self.N, self.E1)
        self.ef = collections.defaultdict(list)
        for i, f in enumerate(F):
            for j in range(3):
                self.ef[frozenset((int(f[j]), int(f[(j + 1) % 3])))].append(i)

    def winkel(self, f, d):
        """Winkel des 3D-Vektors d im Rahmen von Dreieck f."""
        return np.arctan2(d @ self.E2[f], d @ self.E1[f])

    def kantenwinkel(self, f, k):
        # feste Richtung (kleiner -> groesser): tuple(frozenset) liefert die
        # Enden nicht in fester Reihenfolge, die Richtung kippte sonst je
        # nach Dreieck um 180 Grad -- fuer u = exp(4 i theta) unsichtbar,
        # fuer den reellen Winkel ein echter Sprung
        a, b = sorted(k)
        return self.winkel(f, self.V[b] - self.V[a])


def regionen(netz, feat):
    F = netz.F
    par = np.arange(len(F))

    def fd(x):
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x

    for k, fl in netz.ef.items():
        if len(fl) == 2 and k not in feat:
            a, b = fd(fl[0]), fd(fl[1])
            if a != b:
                par[a] = b
    wurzel = np.array([fd(i) for i in range(len(F))])
    _, reg = np.unique(wurzel, return_inverse=True)
    return reg


def singularitaeten(netz, theta, feat):
    """Index je Innenvertex (in Vierteln), aus dem Feld theta je Dreieck.

    Um jeden Vertex werden die Dreiecke im Kreis abgelaufen; je Uebergang
    zaehlt die Drehung des Kreuzes gegenueber dem Paralleltransport,
    auf (-45, 45] Grad gefaltet. Summe plus Winkeldefekt = 2 pi x Index.
    Vertices auf Feature- oder Randkanten werden uebergangen: dort ist
    das Feld festgelegt, und QuadWild behandelt sie als Ecken.
    """
    V, F = netz.V, netz.F
    gesperrt = set()
    for k, fl in netz.ef.items():
        if len(fl) == 1 or k in feat:
            gesperrt.update(k)
    vf = collections.defaultdict(list)
    for i, f in enumerate(F):
        for v in f:
            vf[int(v)].append(i)
    out = {}
    for v, fs in vf.items():
        if v in gesperrt:
            continue
        # Faecher in Reihenfolge bringen: ueber Kanten, die v enthalten
        nb = collections.defaultdict(list)
        for f in fs:
            for w in F[f]:
                w = int(w)
                if w != v:
                    nb[frozenset((v, w))].append(f)
        # gegen den Uhrzeigersinn um v (bezogen auf die Dreiecksnormale):
        # im Dreieck (v, a, b) geht es ueber die Kante v-b ins naechste.
        # Eine erste Fassung waehlte die Kante beliebig; die Drehrichtung
        # und damit das Vorzeichen des Index waren dann Zufall.
        start = fs[0]
        ring, kanten = [start], []
        cur = start
        ok = True
        while True:
            ids = [int(w) for w in F[cur]]
            j = ids.index(v)
            k = frozenset((v, ids[(j + 2) % 3]))
            nxt = [g for g in nb[k] if g != cur]
            if len(nxt) != 1:
                ok = False
                break
            kanten.append(k)
            cur = nxt[0]
            if cur == start:
                break
            ring.append(cur)
            if len(ring) > len(fs):
                ok = False
                break
        if not ok:
            continue
        s = 0.0
        winkelsumme = 0.0
        for f in ring:
            ids = list(F[f])
            j = ids.index(v)
            a = V[ids[(j + 1) % 3]] - V[v]
            b = V[ids[(j + 2) % 3]] - V[v]
            winkelsumme += np.arccos(np.clip(a @ b / np.linalg.norm(a) / np.linalg.norm(b), -1, 1))
        for i, f in enumerate(ring):
            g = ring[(i + 1) % len(ring)]
            k = kanten[i]
            d = (theta[g] - netz.kantenwinkel(g, k)) - (theta[f] - netz.kantenwinkel(f, k))
            d = (d + np.pi / 4) % (np.pi / 2) - np.pi / 4
            s += d
        defekt = 2 * np.pi - winkelsumme
        idx = int(round((s + defekt) / (np.pi / 2)))
        if idx:
            out[v] = idx
    return out


def harmonisch(netz, faces, feat):
    """u = exp(4 i theta) auf den Dreiecken `faces` (eine Region)."""
    faces = list(faces)
    fset = set(faces)
    fest = {}
    for f in faces:
        us = []
        for j in range(3):
            k = frozenset((int(netz.F[f][j]), int(netz.F[f][(j + 1) % 3])))
            if len(netz.ef[k]) == 1 or k in feat:
                us.append(np.exp(4j * netz.kantenwinkel(f, k)))
        if us:
            m = np.mean(us)
            fest[f] = m / abs(m) if abs(m) > 1e-9 else us[0]
    frei = [f for f in faces if f not in fest]
    u = np.zeros(len(netz.F), complex)
    for f, w in fest.items():
        u[f] = w
    if not frei:
        return u, fest
    idx = {f: i for i, f in enumerate(frei)}
    rows, cols, vals = [], [], []
    rhs = np.zeros(len(frei), complex)
    for f in frei:
        i = idx[f]
        diag = 0.0
        for j in range(3):
            k = frozenset((int(netz.F[f][j]), int(netz.F[f][(j + 1) % 3])))
            fl = netz.ef[k]
            if len(fl) != 2 or k in feat:
                continue
            g = fl[0] if fl[1] == f else fl[1]
            if g not in fset:
                continue
            # Transport g -> f
            c = np.exp(4j * (netz.kantenwinkel(f, k) - netz.kantenwinkel(g, k)))
            diag += 1.0
            if g in idx:
                rows.append(i); cols.append(idx[g]); vals.append(-c)
            else:
                rhs[i] += c * u[g]
        rows.append(i); cols.append(i); vals.append(diag if diag > 0 else 1.0)
    A = sp.csr_matrix((vals, (rows, cols)), shape=(len(frei), len(frei)))
    x = spla.spsolve(A.tocsc(), rhs)
    for f, i in idx.items():
        u[f] = x[i]
    return u, fest


def _transport(netz, f, g, k):
    """Winkelversatz g -> f ueber die gemeinsame Kante k: eine Richtung mit
    Winkel phi im Rahmen von g hat im Rahmen von f den Winkel
    phi + _transport(f, g, k)."""
    d = netz.kantenwinkel(f, k) - netz.kantenwinkel(g, k)
    return (d + np.pi) % (2 * np.pi) - np.pi


def randumlauf(netz, faces, feat):
    """Geordneter Randumlauf einer Region: Vertices, Dreieck je Randkante,
    Kantenvektoren und Knickwinkel (Bogenmass, links positiv). None, wenn
    die Region nicht genau eine Randschleife hat."""
    F, V = netz.F, netz.V
    nxt = {}
    kf = {}
    for f in faces:
        for j in range(3):
            a, b = int(F[f][j]), int(F[f][(j + 1) % 3])
            k = frozenset((a, b))
            if len(netz.ef[k]) == 1 or k in feat:
                if a in nxt:
                    return None          # Vertex zweimal auf dem Rand
                nxt[a] = b
                kf[a] = f
    if not nxt:
        return None
    s0 = next(iter(nxt))
    loop = [s0]
    x = nxt[s0]
    while x != s0:
        if x not in nxt or len(loop) > len(nxt):
            return None
        loop.append(x)
        x = nxt[x]
    if len(loop) != len(nxt):
        return None                      # mehr als eine Randschleife
    m = len(loop)
    d = [V[nxt[v]] - V[v] for v in loop]            # Kante i: loop[i] -> loop[i+1]
    nv = [netz.N[kf[v]] for v in loop]
    knick = np.zeros(m)
    for i in range(m):
        d1, d2 = d[i - 1], d[i]
        n = nv[i - 1] + nv[i]
        knick[i] = np.arctan2(n @ np.cross(d1, d2) / np.linalg.norm(n), d1 @ d2)
    return loop, kf, d, knick


def ecken(knick, soll=4, frei_von=30.0, frei_bis=75.0):
    """Eckenzahl je Randvertex (k = Knick / 90 gerundet), so nachgestellt,
    dass sum k = soll. Nachstellen darf nur an uneindeutigen Knicken
    zwischen frei_von und frei_bis Grad (Betrag) -- eine echte 90-Grad-Ecke
    wird nie weggerechnet. None, wenn soll so nicht erreichbar ist: die
    Region braucht dann eine Singularitaet."""
    q = knick / (np.pi / 2)
    k = np.round(q).astype(int)
    rest = soll - k.sum()
    if rest == 0:
        return k
    w = np.degrees(np.abs(knick))
    frei = np.nonzero((w > frei_von) & (w < frei_bis))[0]
    if rest > 0:
        kand = [i for i in frei if k[i] == 0 and q[i] > 0]
        kand.sort(key=lambda i: -q[i])
    else:
        kand = [i for i in frei if k[i] == 1]
        kand.sort(key=lambda i: q[i])
    if len(kand) < abs(rest):
        return None
    for i in kand[:abs(rest)]:
        k[i] += int(np.sign(rest))
    return k


def reell(netz, faces, feat, frei_kanten=3, knick_frei=20.0):
    """Winkel theta als REELLE, stetige Groesse harmonisch interpolieren.

    Die u-Darstellung (komplex, harmonisch) ist genau das, was QuadWilds
    Glaettung schon rechnet -- gemessen identisch auf 1e-4 Grad -- und sie
    erzeugt die Dipole selbst: eine komplexwertige harmonische Funktion
    darf Nullstellenpaare haben. Eine REELLE harmonische Funktion auf einer
    Scheibe hat dagegen keine Singularitaet.

    Dazu muss der Randwinkel stetig fortgesetzt werden. Das geschieht
    einmal geordnet um den Rand herum: an jedem Randvertex knickt der Rand
    um einen Winkel w; das Kreuz folgt der glatten Drehung, eine Ecke
    (k = round(w / 90) = +-1) wird geschluckt. Die Fortsetzung schliesst
    sich genau dann ohne Singularitaet, wenn sum k = 4 ist (Tangente dreht
    360 Grad, alles davon in den Ecken). Knicke um 45 Grad sind
    uneindeutig -- Ecke oder glatte Drehung? Ergibt das Runden nicht 4,
    werden die k an den uneindeutigsten Knicken (Rest am naechsten an
    0.5) um 1 nachgestellt.

    Eine erste Fassung setzte die Randwerte per Dijkstra fort, jeweils auf
    das naechstgelegene Vielfache. An diesen 45-Grad-Knicken rundete sie
    beliebig und hinterliess genau dort eine Singularitaet.

    Nur fuer Regionen, deren Knicke sich zu vier Ecken runden lassen
    (ecken()), und mit genau einer Randschleife; sonst None.
    """
    faces = list(faces)
    fset = set(faces)
    F = netz.F
    rd = randumlauf(netz, faces, feat)
    if rd is None:
        return None
    loop, kf, d, knick = rd
    m = len(loop)
    k = ecken(knick)
    if k is None:
        return None
    # Kreuzwinkel je Randkante, im Rahmen ihres Dreiecks, stetig
    ziel_l = collections.defaultdict(list)
    phi_prev = None
    K = 0
    for i in range(m):
        f = kf[loop[i]]
        if i > 0:
            K += k[i]
        roh = netz.winkel(f, d[i])
        if phi_prev is None:
            phi = roh
        else:
            soll_phi = phi_prev + knick[i]
            phi = roh + 2 * np.pi * np.round((soll_phi - roh) / (2 * np.pi))
        phi_prev = phi
        ziel_l[f].append(phi - K * np.pi / 2)
    ziel = {f: float(np.mean(w)) for f, w in ziel_l.items()}
    # Knicke, die KEINE Ecke sind (k = 0) und doch deutlich abknicken: das
    # Feld kann einer Knickdrehung von z.B. 66 Grad in einem Punkt nicht
    # folgen, ohne dort eine Randsingularitaet zu bilden. Die Bindung
    # wird auf frei_kanten Kanten zu beiden Seiten aufgegeben; die
    # Interpolation verteilt die Drehung dann ueber die Umgebung.
    for i in range(m):
        if k[i] == 0 and abs(knick[i]) > np.radians(knick_frei):
            for j in range(i - frei_kanten, i + frei_kanten):
                ziel.pop(kf[loop[j % m]], None)
    nachbarn = collections.defaultdict(list)
    for f in faces:
        for j in range(3):
            kk = frozenset((int(F[f][j]), int(F[f][(j + 1) % 3])))
            fl = netz.ef[kk]
            if len(fl) == 2 and kk not in feat:
                g = fl[0] if fl[1] == f else fl[1]
                if g in fset:
                    nachbarn[f].append((g, kk))
    frei = [f for f in faces if f not in ziel]
    theta = np.zeros(len(netz.F))
    for f, w in ziel.items():
        theta[f] = w
    if frei:
        idx = {f: i for i, f in enumerate(frei)}
        rows, cols, vals = [], [], []
        rhs = np.zeros(len(frei))
        for f in frei:
            i = idx[f]
            for g, k in nachbarn[f]:
                t = _transport(netz, f, g, k)
                rows.append(i); cols.append(i); vals.append(1.0)
                rhs[i] += t
                if g in idx:
                    rows.append(i); cols.append(idx[g]); vals.append(-1.0)
                else:
                    rhs[i] += theta[g]
        A = sp.csr_matrix((vals, (rows, cols)), shape=(len(frei), len(frei)))
        x = spla.spsolve(A.tocsc(), rhs)
        for f, i in idx.items():
            theta[f] = x[i]
    return theta


def rechne(stem, alle=False, aus=None, verbose=True):
    stem = Path(stem)
    V, F = load_obj(str(stem) + ".obj")
    feat = lies_sharp(str(stem) + ".sharp", F)
    U0 = lies_rosy(str(stem) + ".rosy")
    assert len(U0) == len(F), f"{len(U0)} Feldvektoren fuer {len(F)} Dreiecke"
    netz = Netz(V, F)
    reg = regionen(netz, feat)
    theta0 = np.array([netz.winkel(f, U0[f]) for f in range(len(F))])
    sing0 = singularitaeten(netz, theta0, feat)

    vreg = {}
    for i, f in enumerate(F):
        for v in f:
            vreg.setdefault(int(v), reg[i])
    s_je = collections.defaultdict(list)
    for v, k in sing0.items():
        s_je[vreg[v]].append(k)

    nreg = reg.max() + 1
    # Neu gerechnet wird jede Region, die von ihren Ecken her KEINE
    # Singularitaet braucht (Knicke lassen sich zu genau vier Ecken
    # runden), deren QuadWild-Feld aber eine traegt. Eine erste Fassung
    # nahm nur Regionen mit Singularitaeten beider Vorzeichen und
    # Netto-Index 0 -- das verfehlte Regionen mit vier sauberen
    # 90-Grad-Ecken, in denen QuadWilds Feld zwei Valenz-3 traegt (netto
    # +2/4; moeglich, weil das Feld am Rand nicht ueberall anliegt).
    geeignet = {}
    for r in range(nreg):
        rd = randumlauf(netz, np.nonzero(reg == r)[0], feat)
        geeignet[r] = rd is not None and ecken(rd[3]) is not None
    neu = [r for r in range(nreg) if geeignet[r] and (alle or s_je[r])]
    brauchen = [r for r in range(nreg) if not geeignet[r] and s_je[r]]
    if verbose:
        n3 = sum(1 for k in sing0.values() if k > 0)
        n5 = sum(1 for k in sing0.values() if k < 0)
        print(f"{len(F)} Dreiecke, {nreg} Featureregionen, QuadWild-Feld: "
              f"{n3} x Valenz 3, {n5} x Valenz 5")
        print(f"neu gerechnet: {len(neu)} Regionen (vier Ecken, aber Singularitaet im Feld)")
        for r in brauchen:
            c = collections.Counter(s_je[r])
            print(f"   Region {r:>3}: braucht Singularitaeten (nicht vier Ecken), "
                  f"QuadWild-Feld bleibt: {c[1]} x V3 + {c[-1]} x V5")

    theta = theta0.copy()
    for r in list(neu):
        faces = np.nonzero(reg == r)[0]
        t = reell(netz, faces, feat)
        if t is not None:
            theta[faces] = t[faces]

    sing1 = singularitaeten(netz, theta, feat)
    s1_je = collections.defaultdict(list)
    for v, k in sing1.items():
        s1_je[vreg[v]].append(k)
    if verbose:
        for r in neu:
            a, b = collections.Counter(s_je[r]), collections.Counter(s1_je[r])
            print(f"   Region {r:>3} ({int((reg == r).sum())} Dreiecke): "
                  f"vorher {a[1]} x V3 + {a[-1]} x V5 -> nachher {b[1]} x V3 + {b[-1]} x V5")
        n3 = sum(1 for k in sing1.values() if k > 0)
        n5 = sum(1 for k in sing1.values() if k < 0)
        print(f"neues Feld: {n3} x Valenz 3, {n5} x Valenz 5")

    U = (np.cos(theta)[:, None] * netz.E1 + np.sin(theta)[:, None] * netz.E2)
    ziel = Path(aus) if aus else Path(str(stem) + ".rosy")
    if ziel == Path(str(stem) + ".rosy"):
        shutil.copy(ziel, str(ziel) + ".bak")
    schreib_rosy(ziel, U)
    if verbose:
        print(f"geschrieben: {ziel}")
    return len(neu)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("stem", help="Pfad ohne Endung, z.B. .../netz_rem")
    p.add_argument("--alle", action="store_true",
                   help="jede Region neu rechnen, nicht nur die mit Dipol")
    p.add_argument("--aus", help="Zieldatei (Vorgabe: STEM.rosy, alte als .bak)")
    a = p.parse_args(argv)
    rechne(a.stem, a.alle, a.aus)
    return 0


if __name__ == "__main__":
    sys.exit(main())

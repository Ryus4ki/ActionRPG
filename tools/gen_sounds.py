"""Génère des effets sonores placeholders (WAV 22 kHz mono 16 bits) par synthèse simple.
Usage : python tools/gen_sounds.py  → assets/sounds/*.wav
"""
import math, random, struct, wave, os

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sounds")


def write(name, samples):
    os.makedirs(OUT, exist_ok=True)
    peak = max(1e-6, max(abs(s) for s in samples))
    norm = 0.9 / peak if peak > 0.9 else 1.0
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * norm)) * 32767)) for s in samples))
    print("  ", name, "%.2fs" % (len(samples) / SR))


def env(t, dur, attack=0.005, decay=None):
    decay = decay if decay is not None else dur
    a = min(1.0, t / attack) if attack > 0 else 1.0
    d = max(0.0, 1.0 - (t / decay))
    return a * d * d


def noise():
    return random.uniform(-1, 1)


def lowpass(samples, alpha):
    out, y = [], 0.0
    for s in samples:
        y += alpha * (s - y)
        out.append(y)
    return out


def tone(freq_fn, dur, amp_fn=lambda t: 1.0, wave_fn=math.sin):
    out, phase = [], 0.0
    for i in range(int(dur * SR)):
        t = i / SR
        phase += 2 * math.pi * freq_fn(t) / SR
        out.append(wave_fn(phase) * amp_fn(t))
    return out


def mix(*parts):
    n = max(len(p) for p in parts)
    return [sum(p[i] if i < len(p) else 0.0 for p in parts) for i in range(n)]


def square(x):
    return 1.0 if math.sin(x) >= 0 else -1.0


random.seed(7)
print("sons")
# Coup d'épée : souffle de bruit filtré, montée rapide.
d = 0.25
write("swing", lowpass([noise() * env(t / SR, d, 0.03) for t in range(int(d * SR))], 0.25))
# Impact : bruit court + basse percussive.
d = 0.22
write("hit", mix(lowpass([noise() * env(t / SR, d, 0.002, 0.12) for t in range(int(d * SR))], 0.35),
                 tone(lambda t: 110 * (1 - t * 2), d, lambda t: env(t, d, 0.002))))
# Coup bloqué : clang métallique.
d = 0.35
write("block", mix(tone(lambda t: 1850, d, lambda t: 0.6 * env(t, d, 0.001)),
                   tone(lambda t: 2470, d, lambda t: 0.4 * env(t, d, 0.001, 0.2)),
                   lowpass([noise() * env(t / SR, d, 0.001, 0.05) for t in range(int(d * SR))], 0.6)))
# Raté : léger souffle.
d = 0.18
write("miss", lowpass([noise() * 0.4 * env(t / SR, d, 0.02) for t in range(int(d * SR))], 0.15))
# Lancer de sort : glissando montant scintillant.
d = 0.45
write("cast", mix(tone(lambda t: 400 + 900 * t, d, lambda t: 0.6 * env(t, d, 0.01)),
                  tone(lambda t: 800 + 1800 * t, d, lambda t: 0.3 * env(t, d, 0.01), square)))
# Explosion (boule de feu) : bruit grave long.
d = 0.9
write("explosion", mix(lowpass([noise() * env(t / SR, d, 0.005) for t in range(int(d * SR))], 0.08),
                       tone(lambda t: 60 * (1 - t * 0.5), d, lambda t: 0.8 * env(t, d, 0.005))))
# Flèche : sifflement.
d = 0.3
write("arrow", lowpass([noise() * env(t / SR, d, 0.01) for t in range(int(d * SR))], 0.5))
# Blessé (grognement) : basse modulée.
d = 0.3
write("hurt", tone(lambda t: 160 - 60 * t, d, lambda t: env(t, d, 0.01), lambda x: math.sin(x) + 0.3 * math.sin(2 * x)))
# Mort : grognement descendant plus long.
d = 0.7
write("death", tone(lambda t: 140 - 90 * t, d, lambda t: env(t, d, 0.02), lambda x: math.sin(x) + 0.4 * math.sin(3 * x)))
# Potion : glouglou (deux bulles).
write("potion", mix(tone(lambda t: 500 + 300 * t, 0.12, lambda t: env(t, 0.12, 0.01)),
                    [0.0] * int(0.1 * SR) + tone(lambda t: 650 + 400 * t, 0.14, lambda t: env(t, 0.14, 0.01))))
# Ramassage : petit tintement.
write("pickup", mix(tone(lambda t: 1320, 0.25, lambda t: env(t, 0.25, 0.002)),
                    tone(lambda t: 1980, 0.2, lambda t: 0.5 * env(t, 0.2, 0.002))))
# Pièces : plusieurs tintements.
coins = []
for k in range(3):
    coins = mix(coins, [0.0] * int(0.06 * k * SR) + tone(lambda t, f=2200 + 300 * k: f, 0.2, lambda t: 0.6 * env(t, 0.2, 0.001)))
write("coins", coins)
# Levier : clic mécanique.
write("lever", mix(lowpass([noise() * env(t / SR, 0.08, 0.001) for t in range(int(0.08 * SR))], 0.5),
                   [0.0] * int(0.1 * SR) + tone(lambda t: 220, 0.15, lambda t: env(t, 0.15, 0.001), square)))
# Porte : grondement de pierre.
d = 1.6
write("door", lowpass([noise() * env(t / SR, d, 0.2, 1.4) for t in range(int(d * SR))], 0.04))
# Piège : déclic + pointes.
write("trap", mix(lowpass([noise() * env(t / SR, 0.3, 0.001, 0.15) for t in range(int(0.3 * SR))], 0.7),
                  tone(lambda t: 900 - 600 * t, 0.3, lambda t: 0.5 * env(t, 0.3, 0.001))))
# Flammes.
d = 0.8
write("flames", lowpass([noise() * env(t / SR, d, 0.05) for t in range(int(d * SR))], 0.2))
# Repos au feu : accord doux.
write("rest", mix(tone(lambda t: 262, 1.2, lambda t: 0.5 * env(t, 1.2, 0.05)),
                  tone(lambda t: 330, 1.2, lambda t: 0.4 * env(t, 1.2, 0.1)),
                  tone(lambda t: 392, 1.2, lambda t: 0.4 * env(t, 1.2, 0.15))))
# Montée de niveau : arpège.
lvl = []
for k, f in enumerate([523, 659, 784, 1047]):
    lvl = mix(lvl, [0.0] * int(0.12 * k * SR) + tone(lambda t, f=f: f, 0.5, lambda t: 0.5 * env(t, 0.5, 0.005)))
write("levelup", lvl)
# Victoire : fanfare.
vic = []
for k, f in enumerate([392, 523, 659, 784, 784, 1047]):
    vic = mix(vic, [0.0] * int(0.18 * k * SR) + tone(lambda t, f=f: f, 0.6, lambda t: 0.5 * env(t, 0.6, 0.01), lambda x: math.sin(x) + 0.3 * math.sin(2 * x)))
write("victory", vic)
# Boss : cor grave.
write("boss", mix(tone(lambda t: 98, 1.4, lambda t: env(t, 1.4, 0.05), lambda x: math.sin(x) + 0.5 * math.sin(2 * x) + 0.25 * math.sin(3 * x)),
                  tone(lambda t: 147, 1.4, lambda t: 0.5 * env(t, 1.4, 0.3))))
# À terre : coup sourd.
write("downed", tone(lambda t: 70 - 30 * t, 0.6, lambda t: env(t, 0.6, 0.005)))
# Ambiance de donjon : drone grave + souffle, 12 s (relancé en boucle par le jeu).
d = 12.0
amb = mix(tone(lambda t: 55 + 0.3 * math.sin(t * 0.7), d, lambda t: 0.25 * (0.5 + 0.5 * math.sin(t * 0.4))),
          tone(lambda t: 82.5, d, lambda t: 0.12 * (0.5 + 0.5 * math.sin(t * 0.23 + 1))),
          lowpass([noise() * 0.5 for _ in range(int(d * SR))], 0.02))
# fondu aux extrémités pour éviter le clic
n = len(amb); f = int(0.5 * SR)
amb = [s * min(1.0, i / f, (n - i) / f) for i, s in enumerate(amb)]
write("ambient", amb)
print("ok")

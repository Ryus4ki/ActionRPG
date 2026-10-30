# Action RPG — prototype coop LAN

Action-RPG en vue TPS inspiré de *Baldur's Gate: Dark Alliance*, règles D&D (SRD 5.1), coop à 2 en réseau local.
Moteur : **Godot 4.7** (GDScript). Détails et jalons : [PLAN.md](PLAN.md).

## Jouer / tester sur un autre PC

1. Installer [Git](https://git-scm.com/download/win) et télécharger **Godot 4.7 standard** (pas la version .NET) sur [godotengine.org](https://godotengine.org/download/windows/).
2. Dans un terminal :
   ```
   git clone https://github.com/Ryus4ki/ActionRPG.git
   ```
3. Copier `Godot_v4.7-stable_win64.exe` **dans le dossier `ActionRPG`** (ou définir la variable d'environnement `GODOT` vers son chemin).
4. Double-cliquer sur **`jouer.bat`** : il récupère la dernière version (`git pull`) puis lance le jeu.
   Le premier lancement est plus long (import des modèles).

Pour jouer à deux : l'un clique *Héberger une partie (LAN)*, l'autre voit la partie dans la liste (ou saisit l'adresse IP affichée dans le lobby de l'hôte). Si Windows demande d'autoriser Godot dans le pare-feu, accepter sur *réseau privé*.

## Commandes

| Action | Touche |
|---|---|
| Se déplacer | ZQSD / flèches |
| Caméra | Souris |
| Attaquer | Clic gauche |
| Garde au bouclier (guerrier) | Clic droit maintenu |
| Esquiver | Espace |
| Relever un coéquipier | E |
| Libérer la souris | Échap |
| Retour au menu | Maj + Échap |
| Debug : invulnérable / soin | F1 / F2 |

## Développement

- Tests : `tools\run_tests.bat` (règles D&D, chargement des données, arène solo, hôte + client headless).
- Placeholders 3D : `tools\gen_placeholders.py` (Blender) → `assets/models/*.glb`.
- Publier une mise à jour : `git add -A`, `git commit -m "..."`, `git push`.

Contenu issu du SRD 5.1 (CC-BY-4.0, Wizards of the Coast). Aucun nom de propriété intellectuelle protégée n'est utilisé.

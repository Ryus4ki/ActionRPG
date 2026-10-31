# RELAIS — Action RPG (état au 31/10/2026, après journal de session + banc d'équilibrage)

Document de passation pour reprendre le projet (par Grég ou par une nouvelle session Claude) sans relire
tout l'historique. Le plan détaillé est dans `PLAN.md` (aussi dans le Projet Claude, `claude/PLAN.md`).

## 1. Le projet en une page

- **Jeu** : action-RPG coop à 2 (LAN), vue TPS, règles D&D SRD 5e, **combat façon Final Fantasy XI**
  (cible verrouillée, auto-attaque au délai de l'arme, TP et weapon skills, menu de commandes, incantations
  interruptibles, monstres avec TP et compétences annoncées).
- **Moteur** : Godot 4.7 (GDScript typé). Projet à la racine de `E:\Projet\ActionRPG` (Grég) ; dépôt GitHub
  `Ryus4ki/ActionRPG` (public, branche `main`). `publier.bat` = commit+push (Grég le lance lui-même),
  `jouer.bat` = pull + import + lancement sur le PC du coéquipier (Godot Steam, `godot.windows.opt.tools.64.exe`).
- **Contenu** : village de Brumeval (4 PNJ, boutique, 4 quêtes) → Prairie (lapins, abeilles, sangliers) → Forêt des
  Loups (loups en meute, sangliers, gobelins) → Donjon « Cavernes gobelines » (7 salles, leviers, pièges, énigmes
  de runes, feu de camp, boss à 2 phases) ; arène de test à part. 2 classes (Guerrier, Magicien), 3 races, 6 sorts,
  10 monstres, 16 objets, 5 weapon skills.
- **Jalons** : M0 → M4 (dont M4b combat FFXI, M4c monde extérieur) terminés ; M5 en cours : options, navigation
  manette, rééquilibrage FFXI + repos, **personnages façon MMO** (sauvegarde par personnage, coffre partagé) faits
  (31/10). **Reste** : interpolation réseau pour Internet, export `.exe`.

## 2. Comment on travaille (conventions à respecter)

- Grég parle français, clavier **AZERTY**, manette PS5. Il joue dans l'éditeur Godot ; Claude travaille dans un
  conteneur Linux avec une copie du projet et un Godot 4.7 headless, puis **livre les fichiers directement sur le
  PC de Grég** (outil de fichiers du bureau). Ne jamais committer à sa place.
- **Après toute modification de `project.godot`** (touches, autoloads) : lui dire « Projet → Recharger le projet
  actuel ». Pour les scripts : il accepte le rechargement proposé par Godot (ou ferme les onglets avant).
- Claude ne peut pas supprimer de fichiers sur son PC : déplacer dans `_to_delete/` (ignoré par git).
- **Jamais l'exe Godot dans le dépôt** (`*.exe`, `*.pck` dans `.gitignore`).
- **Avant de toucher à l'équilibrage** : lire `logs/derniere_session.txt` sur le PC de Grég, puis lancer le banc
  `--balance` avant / après.
- **Tests avant livraison**, tous verts : `tests/run_tests.gd` (17 unitaires) et `tests/net_smoke.tscn` avec
  `-- --wizard`, `-- --boss`, `-- --dungeon`, `-- --outdoor`, `-- --ui`, `-- --chars`, sans argument (solo), et hôte+client
  (`-- --host` puis `-- --join 127.0.0.1`). Commande : `godot --headless --path . res://tests/net_smoke.tscn -- --outdoor`.
  Les tests réseau forcent l'arène sauf `--dungeon` / `--outdoor`.
- Pièges GDScript rencontrés : les lambdas capturent les variables locales **par valeur** (compteurs → variables
  membres) ; `const` n'accepte pas de valeur calculée (→ `static var`) ; annoter les types quand l'inférence
  échoue (`var x: bool = …`) ; Godot headless perd la sortie standard si on tue le processus (utiliser `printerr`
  ou laisser quitter) ; les classes `class_name` exigent `--headless --import` après un clone.
- `godot --headless --import` ne signale PAS les erreurs d'analyse des scripts : seuls les tests (qui chargent le HUD,
  etc.) les révèlent. Boucles sur un `Dictionary` non typé : annoter (`for i: int in …`, `var idx: int = i`).
- Les tests écrivent dans des fichiers à part (`user://settings_test.cfg`, `user://test_characters*/`) : jamais dans
  les réglages ni les personnages de Grég.
- Les abonnements au bus d'événements (`EventBus`) doivent survivre aux changements de zone : méthodes de nœud
  (auto-déconnectées) ou vérification `is_instance_valid` ; le HUD se déconnecte dans `_exit_tree`.

## 3. Architecture (où chercher quoi)

| Sujet | Fichiers |
|---|---|
| Règles D&D pures (dés, attaque, sauvegarde, dégâts) | `src/rules/` + tests unitaires |
| Résolution des coups, sorts | `src/combat/combat_resolver.gd`, `spell_caster.gd`, `projectile.gd`, `loot.gd` |
| Joueur | `src/entities/player/player_character.gd` (entrées, mouvement, PNJ/boutique/quêtes, persistance, **jobs** : `class_id` = job actuel, `start_class`, `jobs`, `change_job`, `equip_index`) et `player_combat.gd` (cible, engagement, auto-attaque, TP, WS, capacités, incantation, fuite) |
| Monstres | `src/entities/enemies/enemy.gd` (IA, repli limité des archers, laisse, meute, flânerie, TP et compétences annoncées, phases de boss) ; bestiaire `data/monsters/monsters.json` |
| Composants | `src/entities/components/` : stat_block, health, spell_book, inventory, quest_log |
| Modèles | `.glb` placeholders (`tools/gen_placeholders.py`, Blender) ; animaux **procéduraux** `src/entities/quadruped_model.gd` (`model: "proc:wolf"`) |
| Monde | `src/world/game.gd` (spawns, réapparition, changement de zone, état du groupe, statistiques), `outdoor.gd` (zones extérieures depuis JSON), `dungeon.gd` (donjon depuis JSON), `zone_line.gd`, `npc.gd`, `door/lever/campfire/trap/rune_puzzle/chest/loot_drop.gd` |
| Données | `data/levels/*.json` (village, prairie, forest, dungeon_01), `data/quests/quests.json`, `data/combat/balance.json` (rythme global), `data/combat/weapon_skills.json`, `data/classes/*.json` (capacités dans `features`), `data/spells/spells.json`, `data/items/items.json` + `loot_tables.json` |
| Réseau | `src/net/network_manager.gd` (autoload `Net`) : hôte autoritaire, découverte LAN UDP 7778, port 7777, `LEVELS`, `change_zone`, `party_state` |
| Interface | `src/ui/hud.gd` (cadre perso + TP, cible, barre d'incantation, menu de commandes, journal de combat, inventaire, feuille (C), journal de quêtes (J), dialogue PNJ/boutique, écran de fin, barre de boss, aide (H)), `floating_text.gd`, `lobby.gd`, `main_menu.gd` |
| Son | `src/core/sound_manager.gd` (autoload `Sound`, bus `SFX` et `Ambiance`), sons synthétisés `tools/gen_sounds.py` |
| Réglages | `src/core/settings.gd` (autoload `Settings`, **chargé en premier**) : `user://settings.cfg`, vidéo/son/commandes, touches modifiées (section `bindings`, événements sérialisés), Croix/Rond ajoutés à `ui_accept`/`ui_cancel` à l'exécution ; liste des actions modifiables `REBINDABLE` |
| Personnages | `src/core/characters.gd` (autoload `Characters`) : `user://characters/<id>.json` (nom, classe, race, zone, `state` = `save_state()` + `pos`, `progress`, temps de jeu), coffre partagé `user://shared_chest.json` (objets + or, **local au PC du joueur**), `quit_game()` sauvegarde avant de quitter (fermeture de fenêtre interceptée). Menu principal : liste / création / suppression ; lobby : « Reprendre — zone » ; `Net.set_my_character` envoie le perso à l'hôte ; `game.gd` : `save_party` (toutes les 30 s, à chaque zone, au départ), `_deliver_save` → propriétaire, `world_has_progress` (progression de l'hôte), reprise à la position sauvegardée (`Net.fresh_start`) |
| Coffre partagé / échanges | `src/world/shared_chest.gd` (placé par `outdoor.gd` via `shared_chests` du plan JSON, village près de l'auberge) ; actions `chest_*`, `give_item`, `give_gold`, `revive`, `talk` dans `player_character.gd` ; fenêtres coffre et menu joueur dans `hud.gd` (même panneau que les dialogues) |
| Options / focus | `src/ui/options_menu.gd` (écran d'options en code, 4 onglets), `src/ui/ui_theme.gd` (contour de focus doré, helpers `focus_first`/`focusables`) ; menu système dans `hud.gd` (`open_system_menu`) |

Flux : l'hôte simule tout (physique, IA, dés) ; les clients envoient direction/caméra en continu et des actions
ponctuelles (`request_action("…")`) ; état répliqué par `MultiplayerSynchronizer` (voir les `.tscn`).

## 4. Touches (disposition FFXI, clavier AZERTY — révisées le 31/10)

Pavé 8/2 ou Z/S avancer-reculer, Q/D pas de côté, 4/6 pivoter, `/` marche-course ; **A / E = caméra** (et flèches
quand aucun menu n'est ouvert) ; Pg↑/Pg↓ ou pavé 9/3 zoom ; pavé 5 ou V vue 1re/3e personne ;
**F = Entrée = Croix = touche d'action contextuelle** (`hud.context_open` / `player.context_kind`) : ennemi
sélectionné → menu de combat, PNJ → dialogue, autre joueur → son menu (donner objet / or, relever), objet à portée
→ interagir, sinon menu de combat ; dans un menu : valider. **G potion**, R repos, Échap ou pavé − = annuler ;
Tab / pavé 0 cibler (hors combat : aussi PNJ et joueurs), F8 le plus proche ; clic gauche sur un ennemi = cibler
(re-clic : engager) ; clic droit maintenu = caméra ; I inventaire, C feuille, J quêtes, Espace esquive, H aide,
Échap (rien d'ouvert) = menu système. Le **menu de commandes reste ouvert** après une action (sauf Fuir / Cesser /
Se reposer) et **on peut bouger** menu ouvert (`player.menu_open` ≠ `player.ui_blocked`). Manette : Croix action/valider, Carré engager, Rond retour/interagir,
Triangle potion, L1/R1 cible, L2 garde, R2 esquive, croix directionnelle menus/inventaire/feuille, Options = menu
système. **Ce sont les touches par défaut** : Grég peut les changer (Options → Touches) ; le panneau d'aide (H)
reste en texte fixe. Fenêtres modales (dialogue, menu système, options) : le personnage est bloqué, déblocage
0,2 s après la fermeture (Rond = aussi « interagir »).

## 5. Réglages de rythme (révisés le 31/10)

`data/combat/balance.json` : PV monstres ×8, PV joueurs ×6 (× `hp_mult` de la classe : magicien 1,4), précision des
monstres +3 (`monster_hit_bonus`, uniquement les attaques de monstres), cadence monstres ×1,6, soins ×3, TP des monstres
(20 par coup porté, 10 par coup reçu), préparation des compétences 1,5 s, repos (`rest_*`). Délais d'armes et WS dans
`items.json` et `weapon_skills.json` ; temps d'incantation dans `spells.json` (1 s + 0,5 s par niveau). Simulation de
référence (Python, hors compétences) : guerrier niv. 1 vs lapin 18 s / −10 % PV, vs loup 35 s / −60 %.
Repos (`player_character.gd`, `start_rest`/`_tick_rest`, action `rest` = R, entrée du menu de commandes) : état
`resting` envoyé au propriétaire par RPC pour le HUD (« au repos »).

## 6. Dernières demandes de Grég (toutes livrées)

31/10 11 h 40 : clic gauche + clic droit maintenus = avancer en dirigeant à la souris ; gain d'XP affiché dans le
journal de combat à chaque monstre vaincu (`notify_xp`) ; orientation à l'arrivée dans une zone
(`outdoor.player_spawn_yaw` : regard vers le centre, surchargeable par `player_spawn_yaw` dans le plan JSON ;
la reprise de sauvegarde garde aussi l'orientation `yaw`). 1re session journalisée de Grég (magicien, prairie) :
sans Armure du mage (CA 12) un lapin l'a touché 11 fois sur 11 et lui a pris 58 % des PV.

31/10 11 h : « le magicien est vachement dur » + « un système pour que Claude ait un retour sur les sessions » →
- **Journal de session** (`src/core/session_log.gd`, autoload `SessionLog`) : sur chaque PC, pour le joueur local,
  `logs/session_*.jsonl` (combats détaillés, morts, niveaux, jobs, zones, notes, **erreurs de script** via `Logger`,
  instantané toutes les 60 s) + `logs/derniere_session.txt` (résumé lisible par type de combat). `logs/` dans le
  projet en éditeur (ignoré par git et par Godot via `.gdignore`). **À lire en début de session** :
  `E:\Projet\ActionRPG\logs\derniere_session.txt`. Désactivé en headless sauf `-- --session-log`.
- **Notes de test en jeu** : menu système (Échap) → champ « Retour de test » → ajouté à `Retour de test.txt` avec
  heure, zone, job, niveau, PV, position.
- **Banc d'équilibrage** : `godot --headless --path . res://tests/net_smoke.tscn -- --balance --n 4 [--job wizard]
  [--verbose]` (bots guerrier / magicien niv. 1 contre lapin, abeille, sanglier, loup, gobelin ; temps accéléré ×6 ;
  ~5 min). Résultat dans `logs/balance_dernier.txt`. L'horloge de jeu `GameData.now()` suit `Engine.time_scale`
  (recharges, conditions, provocations).
- **Bug majeur trouvé par le banc** : au corps à corps, les projectiles naissaient DANS la capsule du monstre et
  le traversaient sans toucher (`hit_from_inside`) → le magicien ratait la plupart de ses sorts au contact.
- `spell_damage_mult` = 1,25 (sorts des joueurs). Banc après réglage (niv. 1, reposé, Armure du mage) :
  Guerrier — lapin 17 s / −13 %, abeille 14 s / −39 %, sanglier 31 s / −20 %, loup 42 s / −41 %, gobelin 20 s / −20 % ;
  Magicien — lapin 16 s / −20 %, abeille 9 s / −41 %, sanglier 26 s / −34 %, loup 25 s / −62 %, gobelin 13 s / −17 %.

31/10 10 h 30 : **fin de combat** — le menu se ferme seul quand la cible meurt et qu'aucun monstre n'attaque ; sinon
la cible passe sur un attaquant (pas d'engagement auto) ; panneau « Vous attaquent » (icône-pastille, nom, PV, clic,
L1/R1 priorisent les attaquants ; `Enemy.target_peer` répliqué, `hud.attackers()`). **Jobs façon FFXI** : le job suit
l'arme (`"job"` dans `items.json` : épée/masse/hache → fighter, bâton/dague → wizard), niveau + XP par job
(`player.jobs`, répliqué avec `class_id`), `start_class` = classe de création (caractéristiques + équipement de
départ), changement refusé en combat, `change_job` garde les PV en proportion, sorts du job (`_apply_job_spells`),
incantation impossible dans une armure / avec un bouclier non maîtrisés (`combat.armor_hindrance`). Corrigé au
passage : le guerrier ne gagnait pas de PV max en montant de niveau.

31/10 10 h (`Retour de test.txt`) : menu de combat persistant ; touches A/E caméra, F = Entrée contextuelle ;
sélection et menu d'un autre joueur (échanges) ; **personnages façon MMO** (création au menu, sauvegarde par
personnage, reprise là où on était, rejoindre avec son personnage, coffre partagé entre ses personnages,
progression de l'hôte qui fait foi : mécanisme `requires` sur les lignes de zone, aucune porte définie pour l'instant).

31/10 (fichier `Retour de test.txt`) : l'aide (H) réapparaissait à chaque changement de zone → choix mémorisé
(`Settings.show_help`) ; difficulté façon FFXI → rééquilibrage ci-dessus + repos.

31/10 : **M5 options et manette** — écran d'options complet, menu système en jeu, touches modifiables, navigation
manette dans toutes les fenêtres (voir PLAN M5). Ajout de l'autoload `Settings` → recharger le projet.

Provocation à distance sur une cible unique (sortir un monstre d'un groupe) ; curseur visible, clic droit = caméra,
garde via le menu ; monde extérieur façon FFXI (village + marchands + quêtes, prairie, forêt, lapins/loups…) ;
correction du crash des textes flottants après un changement de zone.

## 7. Pistes ouvertes / à vérifier en jeu

- Retours visuels attendus de Grég : aspect des zones extérieures (arbres, densité, portiques), silhouettes des
  animaux procéduraux, lisibilité de l'interface à sa résolution.
- Avertissements d'analyse Godot restants (opérateur ternaire, division entière, paramètre `by` inutilisé) : à nettoyer.
- M5 : équilibrage (le donjon est dur seul au niveau 1 — voulu), interpolation réseau pour jouer par Internet,
  export Windows + lanceur. Options/manette à valider en jeu par Grég (rendu du focus, plein écran, manette PS5).
- Le panneau d'aide (H) affiche les touches par défaut : à générer depuis l'InputMap si Grég modifie beaucoup ses touches.
- Journal de quêtes et feuille de personnage : pas de défilement à la manette (pas d'élément focalisable).
- Client : sa dernière sauvegarde date d'au plus 30 s si l'hôte coupe brutalement (sinon sauvegarde au départ).
- Portes de progression à définir avec Grég (ex. Cavernes après la quête des loups) : `"requires": "quest:…"` dans `zone_lines`.
- Échanges : don simple (pas de fenêtre d'échange à deux validations).
- Idées notées : vente de matériaux en lot, plus de quêtes, PNJ dans les zones extérieures, cycle jour-nuit.

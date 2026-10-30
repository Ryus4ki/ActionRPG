# Action RPG — Plan de projet

> Jeu d'action-RPG en vue TPS inspiré de *Baldur's Gate: Dark Alliance*, règles D&D (SRD 5e simplifié), jouable en coop à 2 en réseau local.
> Moteur : **Godot 4.x / GDScript**. Dernière mise à jour : 2026-10-28.

---

## 1. Vision

**Pitch** : deux aventuriers explorent un donjon, combattent en temps réel des monstres issus du bestiaire D&D, montent de niveau, ramassent du butin et affrontent un boss. Caméra à l'épaule / trois-quarts, action lisible, sensation « hack & slash tactique ».

**Piliers de design**
1. **Combat temps réel lisible** — attaques, esquives, sorts avec feedback clair (hit-stop, chiffres de dégâts, jets critiques visibles).
2. **D&D sous le capot** — d20, CA, jets de sauvegarde, dés de dégâts. Le joueur *sent* les règles sans devoir les lire.
3. **Coop sans friction** — hébergement en un clic, découverte automatique sur le LAN, écran partagé ou deux PC.
4. **Progression satisfaisante** — niveaux 1→5 sur le prototype, choix de sorts/capacités, loot avec raretés.

**Ce que le prototype n'est PAS** : pas de monde ouvert, pas de dialogue ramifié, pas de PvP, pas de sauvegarde cloud, pas de matchmaking Internet (prévu plus tard).

---

## 2. Décisions techniques

| Sujet | Décision | Pourquoi |
|---|---|---|
| Moteur | Godot 4.7 (Forward+, physique Jolt) | Gratuit, GDScript ≈ Python, multijoueur haut niveau intégré |
| Langage | GDScript (typage statique activé) | Lisibilité, perf correcte, autocomplétion |
| Rendu | Forward+ | PC cible RTX 4060 Ti : largement suffisant |
| Réseau | ENet via `MultiplayerAPI`, modèle **hôte = serveur autoritaire** (listen server) — *validé* | Un joueur héberge, l'autre rejoint. Simple, robuste, pas de serveur dédié |
| Découverte LAN | Broadcast UDP (`PacketPeerUDP`) sur un port fixe | « Parties trouvées » automatiquement dans le menu |
| Synchro | `MultiplayerSynchronizer` pour position/état, `@rpc` pour les actions discrètes | Approche recommandée Godot 4 |
| Règles D&D | SRD 5.1 (CC-BY-4.0) simplifié | Licence libre, contenu suffisant (classes, sorts, monstres) |
| Données de jeu | Fichiers `.tres` (Resources) + JSON pour les tables (monstres, sorts, objets) | Modifiable sans toucher au code |
| Assets | Placeholders procéduraux générés par script (Blender → glTF) puis remplacement progressif | Zéro blocage artistique au départ |
| Versioning | Git + `.gitignore` Godot, dépôt local dans `E:\Projet\ActionRPG` | |

### Pourquoi pas Python / Unreal
Unreal n'expose Python que pour l'éditeur, pas pour le gameplay. Un moteur 100 % Python (Panda3D, Ursina) obligerait à réécrire réseau, animation et physique. Godot offre le compromis « syntaxe Python + moteur complet ».

---

## 3. Adaptation des règles D&D au temps réel

Principe : **une règle = une fonction pure** dans `rules/`, testable sans scène.

### Caractéristiques
- FOR / DEX / CON / INT / SAG / CHA, modificateur = `floor((score - 10) / 2)`.
- Bonus de maîtrise par niveau (SRD : +2 aux niveaux 1-4, +3 aux niveaux 5-8…).

### Jets
- **Attaque** : `d20 + mod carac + maîtrise ≥ CA cible`. 20 naturel = critique (dés de dégâts doublés), 1 naturel = échec auto.
- **Sauvegarde** : `d20 + mod carac (+ maîtrise si classe) ≥ DD du sort` (DD = 8 + maîtrise + mod du lanceur).
- **Dégâts** : dés de l'arme/sort + modificateur. Types de dégâts (tranchant, feu…) avec résistances/vulnérabilités (×0.5 / ×2).

### Temps réel au lieu de tours
- Les « actions » deviennent des **cooldowns** : attaque de base ≈ 0,8 s, action bonus ≈ 3 s, sorts selon niveau d'emplacement.
- **Emplacements de sorts** = ressource qui se recharge au repos (feu de camp dans le donjon) — fidèle au SRD.
- **Points de vie** : dés de vie par classe, +CON/niveau. 0 PV = à terre, le coéquipier peut relever (coop !). Si les deux sont à terre → retour au dernier checkpoint.
- **Initiative** supprimée ; **portée** et **zone d'effet** gérées par la géométrie 3D.
- **Avantage/désavantage** : attaque dans le dos = avantage (2d20 garde le meilleur).

### Contenu prototype
- **Classes** : Guerrier (Second souffle, Fougue, style Défense) et Magicien (Projectile magique, Mains brûlantes, Armure du mage, Boule de feu au niveau 5).
- **Races** : Humain, Elfe, Nain (bonus de caracs + un trait).
- **Monstres** (SRD) : Gobelin, Squelette, Araignée géante, Ogre ; boss : Chef gobelin ou Ogre élite.
- **Progression** : niveaux 1→5, XP selon table SRD, points de vie + nouveau sort/capacité par niveau.
- **Loot** : armes (épée longue, hache, bâton), armures (cuir, mailles), potions de soin, 3 raretés (commun / inhabituel / rare → +1/+2 magique). Loot **partagé, premier arrivé** (validé).

---

## 4. Architecture du projet

```
ActionRPG/
├── project.godot
├── PLAN.md
├── addons/                 # plugins éventuels
├── assets/
│   ├── models/             # glTF placeholders générés
│   ├── materials/
│   ├── audio/
│   └── ui/
├── data/                   # tables de jeu (JSON / .tres)
│   ├── classes/
│   ├── spells/
│   ├── monsters/
│   └── items/
├── src/
│   ├── core/               # autoloads : GameState, NetworkManager, EventBus
│   ├── rules/              # moteur D&D pur (dés, jets, calculs) — testable
│   ├── entities/
│   │   ├── player/         # PlayerCharacter, caméra TPS, input
│   │   ├── enemies/        # Enemy base + IA (StateMachine, NavigationAgent3D)
│   │   └── components/     # Health, StatBlock, Inventory, SpellBook, Hitbox
│   ├── combat/             # résolution attaque/sort côté serveur, effets, dégâts
│   ├── world/              # salles, portes, pièges, checkpoints, loot drops
│   ├── ui/                 # HUD, inventaire, feuille de perso, menus réseau
│   └── net/                # découverte LAN, lobby, spawn joueurs
├── scenes/
│   ├── main_menu.tscn
│   ├── lobby.tscn
│   ├── dungeon_01.tscn
│   └── test_arena.tscn
├── tests/                  # GUT ou gdUnit4 pour rules/
└── tools/                  # scripts Blender/Python générant les placeholders
```

### Flux réseau (hôte autoritaire)
1. Hôte crée la partie → `ENetMultiplayerPeer.create_server(port)` + diffusion UDP « ActionRPG|nom|joueurs ».
2. Client écoute le broadcast, affiche les parties, `create_client(ip, port)`.
3. Lobby : chaque joueur choisit classe/race → RPC vers l'hôte → spawn via `MultiplayerSpawner`.
4. En jeu : **inputs** du client envoyés à l'hôte, l'hôte simule, jets de dés et dégâts calculés **uniquement côté hôte**, résultats répliqués. Prédiction locale du mouvement pour la fluidité.
5. Déconnexion : le personnage du partant est conservé 60 s pour reconnexion, sinon retiré.

---

## 5. Placeholders (générés par Claude)

Script Python/Blender dans `tools/gen_placeholders.py` produisant des glTF low-poly texturés par couleur plate :
- Humanoïde articulé (un seul rig simple, réutilisé pour joueurs et gobelins/squelettes, échelle variable pour l'ogre).
- Animations clés minimales : idle, marche, course, attaque, lancer de sort, touché, mort, à terre.
- Armes : épée, hache, bâton, bouclier.
- Kit de donjon modulaire : sol 4×4 m, murs, porte, pilier, escalier, torche, coffre, autel.
- Props : tonneau, caisse, potion.

Convention : un seul `.blend` source, export par collection, nommage `sm_*` / `sk_*` / `anim_*`.

---

## 6. Jalons

### M0 — Fondations (1-2 semaines)
- [x] Projet Godot créé (4.7, Forward+, Jolt), Git initialisé, structure de dossiers.
- [x] Module `rules/` : dés, modificateurs, jet d'attaque, sauvegarde, dégâts — **avec tests unitaires** (`tools\run_tests.bat`, 17 tests).
- [x] Tables JSON : 2 classes, 3 races, 6 sorts, 6 monstres, 12 objets + autoload `GameData` avec validation croisée.
- [x] Placeholders v1 générés (`tools/gen_placeholders.py`, 20 .glb dans `assets/models/`) — import Godot à vérifier à l'ouverture.

### M1 — Un joueur dans une arène (2-3 semaines) — fait le 2026-10-28, test de fumée headless `tests/smoke_arena.tscn`
- [x] Contrôleur TPS : déplacement relatif caméra, SpringArm, esquive (Espace). Verrouillage de cible : reporté.
- [x] Attaque de mêlée (zone devant le joueur, impact à 0,4 s), `CombatResolver` → `rules/`, chiffres flottants (`FloatingText`).
- [x] Ennemis génériques depuis `monsters.json` (`Enemy`) : aggro, poursuite `NavigationAgent3D` (navmesh cuit au runtime), attaque, mort, XP. Arène : 2 gobelins + 1 squelette.
- [x] HUD : nom/niveau/CA, barre de PV, XP, journal de combat avec les jets. Emplacements de sorts : M3.

### M2 — Coop LAN (2-3 semaines) — code fait le 2026-10-30, reste le test sur 2 PC
- [x] Menu Héberger / Rejoindre / Solo, découverte UDP (broadcast port 7778, jeu port 7777), saisie d'IP.
- [x] Lobby avec choix classe/race et état prêt ; spawn via `MultiplayerSpawner` sur les `PlayerSpawns` du niveau.
- [x] Réplication (`MultiplayerSynchronizer`) : position, rotation, animation, garde, PV, états, XP/niveau ; entrées client → hôte par RPC ; événements de combat hôte → clients.
- [x] Relever un coéquipier à terre (touche E, 2,5 m). Relevé automatique seulement si aucun allié vivant.
- [ ] Test sur 2 PC réels (pas seulement 2 instances locales). Test automatisé : `tests/net_smoke.tscn` (hôte + client headless).

### M3 — Vraie boucle RPG (3-4 semaines)
- [x] Magicien : 6 sorts du SRD (trait de feu, projectile magique, mains brûlantes, armure du mage, rayon ardent, boule de feu), emplacements, montée de niveau → nouveaux sorts et PV. Repos au feu de camp : M4.
- [x] XP et montée de niveau (PV, maîtrise, sorts). Feuille de personnage : à faire.
- [ ] Inventaire, équipement, loot qui tombe des monstres et des coffres (partagé, premier arrivé).
- [ ] 4 types de monstres, 1 boss avec 2 phases.

### M4 — Donjon 01 (3-4 semaines)
- [ ] Niveau complet (~20 min) : 8-10 salles, 2 pièges, 1 énigme simple (leviers), checkpoints.
- [ ] Ambiance : éclairage torches, brouillard, musique/sons placeholders.
- [ ] Écran de fin, statistiques de la partie.

### M5 — Polish & export (2 semaines)
- [ ] Équilibrage (feuille de calcul des dégâts/PV par niveau).
- [ ] Options (résolution, touches, manette).
- [ ] Export Windows, test chez un ami en LAN.

**Après le prototype** : coop Internet (Steam/Noray/relay), 2 classes de plus (Voleur, Clerc), split-screen, sauvegarde de personnage, 2e donjon.

---

## 7. Risques et parades

| Risque | Parade |
|---|---|
| Réseau introduit tard → tout à refaire | Coop dès M2, toute logique de combat écrite « serveur-autoritaire » dès M1 |
| Règles D&D trop lourdes en temps réel | Module `rules/` isolé, on coupe ce qui n'est pas fun (initiative, actions complexes) |
| Blocage artistique | Placeholders générés, remplacement asset par asset plus tard |
| Scope creep | Chaque jalon a une liste fermée ; les idées vont dans `IDEES.md`, pas dans le jalon en cours |
| Licence D&D | Uniquement SRD 5.1 (CC-BY-4.0), attribution dans les crédits ; aucun nom de PI protégée (pas de « Baldur's Gate », « Drizzt », « Beholder »…) |

---

## 8. Prochaines actions immédiates

1. Installer Godot 4.x (version standard, pas .NET) et créer le projet dans `E:\Projet\ActionRPG`.
2. Session suivante avec Claude : générer la structure de dossiers, `rules/` + tests, et les tables JSON (M0).
3. Puis : script `tools/gen_placeholders.py` pour les meshes.

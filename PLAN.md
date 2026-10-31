# Action RPG — Plan de projet

> Jeu d'action-RPG en vue TPS inspiré de *Baldur's Gate: Dark Alliance*, règles D&D (SRD 5e simplifié), jouable en coop à 2 en réseau local.
> Moteur : **Godot 4.x / GDScript**. Dernière mise à jour : 2026-10-31.

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
| Moteur | Godot 4.x (dernière stable) | Gratuit, GDScript ≈ Python, multijoueur haut niveau intégré |
| Langage | GDScript (typage statique activé) | Lisibilité, perf correcte, autocomplétion |
| Rendu | Forward+ | PC cible RTX 4060 Ti : largement suffisant |
| Réseau | ENet via `MultiplayerAPI`, modèle **hôte = serveur autoritaire** (listen server) | Un joueur héberge, l'autre rejoint. Simple, robuste, pas de serveur dédié |
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

### Système de combat « à la Final Fantasy XI » (décision du 30/10/2026)
Le combat n'est plus un hack'n'slash au clic : il est **temps réel mais piloté par commandes**, comme FFXI.
- **Cible** : Tab / L1-R1 fait défiler les ennemis proches ; la cible a un marqueur au sol et un cadre dans le HUD.
- **Attaquer** (menu ou clic gauche / Carré) **engage** la cible : les coups partent **tout seuls** au rythme du
  **délai de l'arme** (dague 1,8 s, épée 2,4 s, masse 2,6 s, bâton 2,6 s, grande hache 3,2 s) tant qu'on est à
  portée et face à elle. Chaque coup = jet d'attaque D&D (d20 + mod + maîtrise vs CA). On se déplace librement.
- **TP** : chaque coup porté donne des TP (plus l'arme est lente, plus le gain est gros ; être touché en donne la moitié).
  À **100 %** on peut lancer une **weapon skill** (compétence d'arme) : un coup spécial au multiplicateur de dégâts,
  dont la puissance grimpe avec les TP accumulés jusqu'à 300 %. Une WS par type d'arme (`data/combat/weapon_skills.json`).
- **Compétences de classe** (recharge) : Second souffle, Fougue, Provocation, Garde (bouclier) pour le guerrier ;
  Restauration magique pour le magicien. Déclarées dans `features` des classes.
- **Magie** : les sorts ont un **temps d'incantation** (1 s pour un tour de magie, +0,5 s par niveau de sort) visible sur
  une barre ; **se déplacer interrompt** l'incantation. Le sort part vers la cible (ou soi-même pour les buffs).
- **Objets** : potions et consommables du sac, utilisables à tout moment.
- **Fuir** : désengage et donne +50 % de vitesse pendant 5 s (recharge 20 s). Un monstre qui s'éloigne trop de son poste
  (laisse de 30 m) abandonne, rentre et récupère ses PV.
- **Menu de commandes** (Entrée / Croix) : liste verticale *Attaquer · Compétences · Magie · Objets · Fuir*, navigation
  aux flèches / croix directionnelle, Échap / Rond pour revenir. Raccourcis conservés : F potion, I inventaire, C feuille.
- Les monstres gardent leur IA (attaques au contact ou à distance, délais propres) ; la **Provocation** force leur cible.
- **Rythme long** (révisé le 31/10 après le retour de test de Grég : « en FFXI les lapins pouvaient déjà nous tuer, mais
  les combats étaient plus longs, plus de PV des deux côtés ») : PV des monstres ×8, des joueurs ×6 (magicien ×1,4 en plus,
  `hp_mult` de la classe), **précision des monstres +3**, cadence des monstres ×1,6, soins ×3 (`data/combat/balance.json`).
  Lapin renforcé (2d4+1 PV, +3, 1d4). Simulation niveau 1 : guerrier vs lapin ~18 s (−10 % PV), vs sanglier ~30 s
  (−30 %), vs loup ~35 s (−60 %, parfois mortel) ; magicien nettement plus fragile seul (rôle de soutien en coop).
- **Repos façon /heal** (31/10) : hors combat et sans monstre aux trousses, R ou « Se reposer » dans le menu : après 4 s,
  soin toutes les 2 s de 4 % à 10 % des PV max (croissant), +1 emplacement de sort toutes les 12 s ; bouger, agir ou être
  touché relève le personnage.
- **Compétences de monstres** : chaque monstre gagne des TP (coups portés et reçus) ; à 100 il **annonce** une compétence
  (« ⚠ prépare : Bombe gobeline » dans le cadre de cible, texte flottant, journal) puis la lance 1,5 s plus tard. Types :
  zone (bombe, massue tournoyante), frappe (étourdit, empoisonne), tir (aveugle), soin, renfort des alliés, affaiblissement.
  Parades : **esquive** (roulade = immunité aux zones), **garde** (dégâts ÷2), s'éloigner, Provocation pour tenir l'aggro.
- **Conditions** : empoisonné (1d4 / 2 s), aveuglé (désavantage), étourdi (immobile 2 s), affaibli −2, renforcé +2, entravé.

### Temps réel au lieu de tours
- Les « actions » deviennent des **délais d'arme et des recharges** : attaque de base selon l'arme (voir ci-dessus),
  capacités avec temps de recharge, sorts avec temps d'incantation et emplacements.
- **Emplacements de sorts** = ressource qui se recharge au repos (feu de camp dans le donjon) — fidèle au SRD.
- **Points de vie** : dés de vie par classe, +CON/niveau. 0 PV = à terre, le coéquipier peut relever (coop !). Si les deux sont à terre → retour au dernier checkpoint.
- **Initiative** supprimée ; **portée** et **zone d'effet** gérées par la géométrie 3D.
- **Avantage/désavantage** : attaque dans le dos = avantage (2d20 garde le meilleur).

### Contenu prototype
- **Jobs** (façon FFXI, le job suit l'arme) : Guerrier (Second souffle, Fougue, style Défense) et Magicien (Projectile magique, Mains brûlantes, Armure du mage, Boule de feu au niveau 5).
- **Races** : Humain, Elfe, Nain (bonus de caracs + un trait).
- **Monstres** (SRD) : Gobelin, Squelette, Araignée géante, Ogre ; boss : Chef gobelin ou Ogre élite.
- **Progression** : niveaux 1→5, XP selon table SRD, points de vie + nouveau sort/capacité par niveau.
- **Loot** : armes (épée longue, hache, bâton), armures (cuir, mailles), potions de soin, 3 raretés (commun / inhabituel / rare → +1/+2 magique).

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

> **Bilan au 30/10/2026** : M0 à M4 terminés, combat refondu façon FFXI (M4b). Le prototype est jouable en solo et en coop LAN
> (testé sur 2 PC réels), à la manette PS5 ou au clavier AZERTY, avec guerrier et magicien, 6 monstres dont un boss
> à 2 phases, butin, inventaire et potions. Partagé via GitHub (`publier.bat` / `jouer.bat`).
> Le jeu commence au village de Brumeval (M4c). Prochaine étape : **M5, équilibrage, options et export**.

### M0 — Fondations ✅
- [x] Projet Godot 4.7 créé, Git initialisé (GitHub `Ryus4ki/ActionRPG`), structure de dossiers.
- [x] Module `rules/` : dés, modificateurs, jet d'attaque, sauvegarde, dégâts — **17 tests unitaires**.
- [x] Tables JSON : 2 classes, 3 races, 6 sorts, 6 monstres, 12 objets, tables de butin.
- [x] Placeholders générés par script Blender (`tools/gen_placeholders.py`) : humanoïde animé, araignée, armes, kit de donjon.

### M1 — Un joueur dans une arène ✅
- [x] Contrôleur TPS : déplacement, caméra souris / stick droit, esquive, garde au bouclier (clic droit).
- [x] Attaque de mêlée avec hitbox, dégâts via `rules/`, chiffres flottants, journal de combat.
- [x] Ennemi gobelin : attente, poursuite (`NavigationAgent3D`), attaque, mort.
- [x] HUD : cadre du personnage (PV, XP, or, potions), barre de sorts, fenêtre de journal façon MMO, aide (H).
- [x] Clavier AZERTY et manette PS5 (DualSense).

### M2 — Coop LAN ✅
- [x] Menu Héberger / Rejoindre, découverte UDP, IP de l'hôte affichée dans le lobby.
- [x] Lobby avec choix de classe/race, spawn des 2 joueurs.
- [x] Réplication mouvement, animations, attaques, PV, ennemis, projectiles, butin (hôte autoritaire).
- [x] Relever un coéquipier à terre (E).
- [x] Test sur 2 PC réels via GitHub (`jouer.bat` met à jour et lance le jeu).

### M3 — Vraie boucle RPG ✅
- [x] Magicien : 6 sorts (projectiles, zones, buff), emplacements par niveau, XP et montée de niveau.
- [x] Inventaire (I / croix gauche), équipement avec bonus magiques (+1…), potions (F / Triangle).
- [x] Butin des monstres (tables par rareté) et coffre (E), partagé premier arrivé.
- [x] 6 types de monstres : gobelin, archer gobelin (tir, garde ses distances), squelette, araignée géante
      (morsure empoisonnée, toile qui entrave), ogre (massue à recul), chef gobelin.
- [x] Boss à 2 phases : appelle 2 gobelins à la première blessure, puis 2 archers et frappe 30 % plus vite sous
      50 % de PV. Barre de boss à l'écran, message « Arène nettoyée ! » quand tout est mort.
- [ ] Repos au feu de camp (restaure PV et emplacements) → déplacé en M4 avec le donjon.
- [ ] Feuille de personnage détaillée (écran) → déplacé en M4.

### M4 — Donjon 01 ✅
- [x] Donjon « Les Cavernes gobelines » généré depuis un plan JSON (`data/levels/dungeon_01.json`) : 7 salles,
      couloirs, murs automatiques, porte verrouillée par 2 leviers, pièges (pointes, flammes), 2 coffres, 15 monstres.
- [x] Feu de camp réutilisable (recharge 30 s) : PV et sorts, point de réapparition ; le groupe réapparaît au dernier feu s'il tombe entier.
- [x] Pièges évitables : jet de Perception (Sagesse DD 12) en approchant pour les révéler, plaques étroites qu'on peut longer,
      et une **énigme de runes** par zone (3 runes à activer dans l'ordre d'une devinette) qui désamorce les pièges de la zone.
- [x] Feuille de personnage (C / croix droite). Choix du niveau dans le lobby (donjon ou arène).
- [x] Salle du boss en fin de donjon, écran de fin avec statistiques (temps, kills, dégâts, mises à terre, potions, or).
- [x] Ambiance : torches vacillantes, brouillard, 22 sons placeholders synthétisés (`tools/gen_sounds.py`), drone d'ambiance.
- [ ] Le niveau est court (~10 min) : à étoffer en M5 (salles supplémentaires, énigme) selon les retours de jeu.

### M4b — Refonte du combat façon FFXI ✅
- [x] Cible verrouillée (Tab / L1-R1, marqueur au sol, cadre HUD), engagement et auto-attaque au délai de l'arme.
- [x] TP et weapon skills (une par type d'arme, `data/combat/weapon_skills.json`), compétences de classe à recharge
      (Second souffle, Fougue, Provocation, Garde ; Restauration magique, Concentration).
- [x] Sorts avec temps d'incantation (barre), interruption au déplacement, ciblage sur la cible.
- [x] Menu de commandes vertical (Attaquer · Compétences · Magie · Objets · Fuir) clavier/manette/souris.
- [x] Fuir (désengagement + sprint 5 s) et laisse des monstres (retour au poste à 30 m, PV restaurés).
- [x] Tests headless adaptés (solo avec WS, mage avec incantation/interruption, hôte+client, boss, donjon avec menu).
- [x] Rythme FFXI (PV ×3 / ×2,5, cadences) et compétences de monstres avec annonce (13 compétences sur 6 monstres),
      conditions (poison, aveuglé, étourdi, affaibli, renforcé) ; esquive = immunité aux zones, garde = ÷2.

### M4c — Monde extérieur façon FFXI ✅ (31/10)
- [x] Zones interconnectées par des **lignes de zone** (tout le groupe change de zone ensemble, personnages conservés) :
      **Brumeval** (village) ↔ **Prairie de Brumeval** ↔ **Forêt des Loups** ↔ Cavernes gobelines (le donjon a une sortie).
- [x] Générateur de zones extérieures depuis un plan JSON (`data/levels/village|prairie|forest.json`) : sol, routes, bâtiments,
      arbres/rochers/buissons/barrières dispersés par graine, lisières, feux de camp, coffres.
- [x] Village : 4 PNJ — Ancienne Maëlle (quêtes), Brenn le forgeron (armes/armures + quête), Lise l'aubergiste (potions + quête),
      Garde Tomas (conseils). Dialogue, **boutique** (achat / vente à moitié prix), **quêtes** (chasse, collecte, prérequis).
- [x] Journal de quêtes (J), progression dans le journal de combat, récompenses (or, XP, objets).
- [x] Monstres de début : lapin (passif), loup (meute, hurlement), sanglier (charge), abeille géante (dard venimeux),
      modèles **procéduraux** animés (`QuadrupedModel`, pas de Blender nécessaire), flânerie autour du poste, **réapparition**.
- [x] Nouveaux objets : peau de lapin, croc de loup, défense de sanglier, rayon de miel. Test headless `--outdoor`.
- [ ] À venir : vendre les matériaux en lot, plus de quêtes, PNJ dans la prairie/forêt, météo/cycle jour-nuit.

### M5 — Polish & export (2 semaines)
- [~] Équilibrage : banc `--balance` en place (niveau 1) ; à étendre aux niveaux 2-5, au donjon et à la coop.
- [x] Options (31/10) : autoload `Settings` (`user://settings.cfg`), écran `OptionsMenu` depuis le menu principal et le
      **menu système** en jeu (Échap / Options) — affichage (mode, taille, V-Sync, limite i/s, taille de l'interface,
      résolution 3D, champ de vision), son (général / effets / ambiance, bus SFX et Ambiance), souris & manette
      (sensibilités, inversion Y, zone morte), **touches modifiables** (2 cases clavier + 1 manette par action).
- [x] Navigation à la manette (31/10) : focus doré visible, Croix valide / Rond revient, dialogues PNJ et boutique
      (le focus reste en place après un achat), inventaire, menu système, menu principal, lobby ; L1/R1 = onglets des options.
      Test headless `--ui`.
- [x] Touches AZERTY (31/10) : A/E caméra, F = Entrée = Croix = action contextuelle (combat / dialogue / menu joueur /
      interagir), G potion ; Tab hors combat sélectionne aussi PNJ et joueurs ; menu de combat persistant (on bouge menu ouvert).
- [x] Menu d'un autre joueur : donner un objet, de l'or, le relever.
- [x] Personnages façon MMO (31/10) : création / choix / suppression au menu principal, une sauvegarde par personnage
      (zone, position, niveau, sac, équipement, quêtes, progression), sauvegarde auto (30 s, changement de zone, départ,
      fermeture), reprise solo là où on était, rejoindre une partie avec son personnage (sauvegardé chez soi par l'hôte),
      **coffre partagé** entre ses personnages (village, près de l'auberge), progression de l'hôte qui ouvre le monde
      (`requires` sur les lignes de zone). Test headless `--chars`.
- [x] Fin de combat (31/10) : menu fermé automatiquement, bascule sur l'attaquant suivant, panneau des attaquants.
- [x] **Jobs façon FFXI** (31/10) : le job suit l'arme équipée, un niveau et une XP par job, la classe de création ne fixe
      que les caractéristiques et l'équipement de départ ; pas de changement en combat ; pas d'incantation en armure non maîtrisée.
- [x] Retours de jeu (31/10) : journal de session automatique (`logs/`), notes de test depuis le menu système,
      banc d'équilibrage par bots (`--balance`) ; correctif des projectiles à bout portant ; sorts ×1,25.
- [ ] Interpolation réseau pour jouer par Internet, export Windows (.exe), test chez un ami.

**Après le prototype** : coop Internet (relay), 2 classes de plus (Voleur, Clerc), sauvegarde de personnage, 2e donjon.

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

1. Grég teste les personnages (création, reprise, coffre), les touches AZERTY et le menu persistant ; retours dans `Retour de test.txt`.
2. M5 : équilibrage via `data/combat/balance.json`, interpolation réseau pour Internet, export `.exe`.
3. Reprise d'une session : lire `RELAIS.md` (passation complète : conventions, architecture, touches, tests).

extends Node
## Autoload « EventBus » : signaux globaux découplés (HUD, effets, sons…).
## Les émetteurs ne connaissent pas les récepteurs.

## Une attaque a été résolue (touché ou raté). `result` vient de CombatResolver.
signal hit_resolved(target: Node3D, result: Dictionary)

## Une créature est morte (monstre) ou à terre (joueur).
signal creature_died(creature: Node3D)
signal creature_downed(creature: Node3D)

## Le joueur local a été créé (le HUD s'y connecte).
signal local_player_ready(player: Node3D)

## Le joueur local a ramassé un objet ({id, qty, rarity}).
signal item_picked(entry: Dictionary)

## Un boss entre dans une nouvelle phase (0 = première). Émis sur toutes les machines.
signal boss_phase(boss: Node3D, phase: int)

## Tous les monstres du niveau sont morts.
signal level_cleared()

## Message système à afficher dans le journal (porte verrouillée, repos, réapparition…).
signal system_message(text: String)

## Fin de partie : résumé {level_name, duration, players: [{name, class, level, kills, …}]}.
signal run_finished(summary: Dictionary)

## Un monstre prépare une compétence (délai de réaction avant l'effet).
signal monster_skill(monster: Node3D, skill_name: String)

## Arrivée dans une zone (bandeau).
signal zone_entered(zone_name: String)

## Un PNJ ouvre son dialogue sur cette machine (id du PNJ dans le plan de la zone).
signal npc_dialog(npc_id: String)

## Journal de quêtes : une quête a avancé / été acceptée / rendue (message local).
signal quest_updated(text: String)

## Le coffre partagé (commun aux personnages de ce PC) s'ouvre sur cette machine.
signal shared_chest_open

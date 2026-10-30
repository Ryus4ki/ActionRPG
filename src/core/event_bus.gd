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

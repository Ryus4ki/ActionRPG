class_name Health
extends Node
## Points de vie d'une créature. Modifié uniquement côté hôte ; les propriétés sont répliquées
## par le MultiplayerSynchronizer et les setters réémettent les signaux côté client.

signal changed(hp: int, max_hp: int)
signal damaged(amount: int, damage_type: int, crit: bool, source: Node)
signal healed(amount: int)
signal died
signal downed
signal revived

var max_hp := 10:
	set(v):
		max_hp = v
		changed.emit(hp, max_hp)
var hp := 10:
	set(v):
		hp = v
		changed.emit(hp, max_hp)
## Joueurs : à 0 PV ils tombent « à terre » (relevables) au lieu de mourir.
var can_be_downed := false
var is_dead := false:
	set(v):
		var was := is_dead
		is_dead = v
		if v and not was:
			died.emit()
var is_downed := false:
	set(v):
		var was := is_downed
		is_downed = v
		if v and not was:
			downed.emit()
		elif was and not v and not is_dead:
			revived.emit()
## Debug / tests : ignore tous les dégâts.
var invulnerable := false


func setup(p_max_hp: int) -> void:
	max_hp = maxi(p_max_hp, 1)
	hp = max_hp
	is_dead = false
	is_downed = false


func is_alive() -> bool:
	return not is_dead and not is_downed


func take_damage(amount: int, damage_type: int = 0, crit: bool = false, source: Node = null) -> void:
	if is_dead or amount <= 0 or invulnerable:
		return
	hp = maxi(hp - amount, 0)
	damaged.emit(amount, damage_type, crit, source)
	if hp == 0:
		if can_be_downed and not is_downed:
			is_downed = true
		elif not can_be_downed:
			is_dead = true


func heal(amount: int) -> void:
	if is_dead or amount <= 0:
		return
	var before := hp
	hp = mini(hp + amount, max_hp)
	if hp > before:
		healed.emit(hp - before)


## Relève un joueur à terre avec un pourcentage de ses PV max.
func revive(hp_pct: float = 0.25) -> void:
	if not is_downed:
		return
	hp = maxi(int(max_hp * hp_pct), 1)
	is_downed = false


## Mort définitive d'un joueur à terre (ex. temps écoulé).
func kill() -> void:
	if is_dead:
		return
	hp = 0
	is_dead = true
	is_downed = false

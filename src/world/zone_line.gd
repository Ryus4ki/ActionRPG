class_name ZoneLine
extends Area3D
## Ligne de zone (façon FFXI) : la traverser emmène tout le groupe dans la zone `target_level`,
## au point d'apparition `target_spawn`. Détection côté hôte uniquement.

@export var target_level := ""
@export var target_spawn := "default"
@export var label_text := "Vers…"
## Progression exigée (ex. "quest:q_wolves", "boss:goblin_boss") : c'est celle de l'HÔTE qui compte.
@export var requires := ""
@export var requires_text := ""

var _refused_until := 0.0

@onready var label: Label3D = $Label

var _fired := false


func _ready() -> void:
	add_to_group("zone_lines")
	label.text = "→ %s" % label_text
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if _fired or not (body is PlayerCharacter) or not body.health.is_alive():
		return
	var game := get_tree().get_first_node_in_group("game")
	if requires != "" and game and game.has_method("world_has_progress") and not game.world_has_progress(requires):
		var now := Time.get_ticks_msec() / 1000.0
		if now >= _refused_until:
			_refused_until = now + 4.0
			game.system_message("Le passage est fermé : %s (progression de l'hôte)." % (requires_text if requires_text != "" else requires))
		return
	if game and game.has_method("change_zone"):
		_fired = true
		game.change_zone(target_level, target_spawn, body)

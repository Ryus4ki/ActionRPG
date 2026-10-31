class_name Rune
extends StaticBody3D
## Une rune murale appartenant à une RunePuzzle. E pour l'activer.

var rune_index := 0
var rune_name := "Rune"
var puzzle: Node = null

@onready var label: Label3D = $Label
@onready var stone: MeshInstance3D = $Stone
var _mat: StandardMaterial3D


func _ready() -> void:
	add_to_group("interactables")
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.3, 0.3, 0.36)
	stone.material_override = _mat
	refresh()


func interact(by: Node) -> bool:
	if puzzle == null:
		return false
	return puzzle.press(rune_index, by)


func refresh() -> void:
	if not is_node_ready() or puzzle == null:
		return
	var lit: bool = puzzle.is_lit(rune_index)
	label.text = rune_name.to_upper() + ("" if lit or puzzle.solved else "  (F)")
	label.modulate = Color(1.0, 0.85, 0.4) if lit else Color(0.75, 0.75, 0.85)
	_mat.emission_enabled = lit
	_mat.emission = Color(1.0, 0.6, 0.2)
	_mat.emission_energy_multiplier = 1.5

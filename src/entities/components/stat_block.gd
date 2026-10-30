class_name StatBlock
extends Node
## Caractéristiques D&D d'une créature (joueur ou monstre).
## Source de vérité côté hôte ; en M2 ce nœud sera répliqué (level, xp, abilities).

signal level_changed(new_level: int)

var display_name := "Créature"
var abilities := {"str": 10, "dex": 10, "con": 10, "int": 10, "wis": 10, "cha": 10}
## level et xp sont répliqués (setter → signal côté client aussi).
var level := 1:
	set(v):
		var changed := v != level
		level = v
		if changed:
			level_changed.emit(level)
var xp := 0
var hit_die := 8
var speed := 30  # pieds par round (SRD) → converti en m/s par la créature

var base_ac := 10          # (monstres / compat) base sans armure
var armor_base_ac := 0     # CA de base de l'armure portée (0 = aucune armure)
var armor_type := "none"
var shield_bonus := 0
var equipment_ac_bonus := 0  # bonus magique de l'armure / du bouclier
var ac_bonus := 0          # bonus divers (sorts, buffs)
var mage_armor := false    # Armure du mage : base 13 si aucune armure
var defense_style := false # Style de combat Défense : +1 CA si armure portée
var fixed_ac := -1         # monstres : CA fixe du bestiaire

var save_proficiencies: Array = []
var fixed_attack_bonus := -999  # monstres : bonus d'attaque fixe

var damage_resistances: Array[int] = []
var damage_vulnerabilities: Array[int] = []
var damage_immunities: Array[int] = []

var class_id := ""
var race_id := ""
var monster_id := ""
var xp_value := 0  # XP donnée à la mort (monstres)


# ---------------------------------------------------------------- init

func setup_from_class(p_class_id: String, p_race_id: String) -> void:
	class_id = p_class_id
	race_id = p_race_id
	var cls: Dictionary = GameData.player_class(p_class_id)
	var race: Dictionary = GameData.race(p_race_id)
	display_name = "%s %s" % [race.get("name", ""), cls.get("name", "")]
	abilities = cls.get("default_abilities", abilities).duplicate()
	for a in race.get("ability_bonuses", {}):
		abilities[a] = abilities.get(a, 10) + race["ability_bonuses"][a]
	hit_die = cls.get("hit_die", 8)
	speed = race.get("speed", 30)
	save_proficiencies = cls.get("saving_throws", [])
	for trait_data in race.get("traits", []):
		for r in trait_data.get("damage_resistances", []):
			damage_resistances.append(damage_type_from_string(r))
	# Style de combat Défense : +1 CA si armure portée (appliqué par l'équipement en M3 ;
	# pour l'instant on l'applique si la classe a la capacité au niveau 1).
	var feats: Array = cls.get("features_by_level", {}).get("1", [])
	defense_style = "fighting_style_defense" in feats


func setup_from_monster(p_monster_id: String) -> void:
	monster_id = p_monster_id
	var m: Dictionary = GameData.monster(p_monster_id)
	display_name = m.get("name", p_monster_id)
	abilities = m.get("abilities", abilities).duplicate()
	fixed_ac = m.get("ac", 10)
	speed = m.get("speed", 30)
	xp_value = m.get("xp", 0)
	level = maxi(1, int(ceil(float(m.get("cr", 1)))))
	for r in m.get("damage_resistances", []):
		damage_resistances.append(damage_type_from_string(r))
	for v in m.get("damage_vulnerabilities", []):
		damage_vulnerabilities.append(damage_type_from_string(v))
	for i in m.get("damage_immunities", []):
		damage_immunities.append(damage_type_from_string(i))


## Applique l'équipement (dictionnaires de items.json ; null = rien).
func set_armor(item: Dictionary) -> void:
	armor_base_ac = int(item.get("base_ac", 0)) if not item.is_empty() else 0
	armor_type = item.get("armor_type", "none") if not item.is_empty() else "none"


func set_shield(item: Dictionary) -> void:
	shield_bonus = int(item.get("ac_bonus", 0)) if not item.is_empty() else 0


# ---------------------------------------------------------------- calculs

func ability_mod(ability: String) -> int:
	return Rules.ability_mod(abilities.get(ability, 10))


func proficiency() -> int:
	return Rules.proficiency_bonus(level)


func armor_class() -> int:
	if fixed_ac >= 0:
		return fixed_ac + ac_bonus
	var base := armor_base_ac
	var atype := armor_type
	if base <= 0:
		base = 13 if mage_armor else base_ac
		atype = "none"
	var ac := Rules.armor_class(base, ability_mod("dex"), atype, shield_bonus)
	ac += equipment_ac_bonus + ac_bonus
	if defense_style and armor_base_ac > 0:
		ac += 1
	return ac


func attack_bonus(ability: String = "str", magic_bonus: int = 0) -> int:
	if fixed_attack_bonus > -999:
		return fixed_attack_bonus + magic_bonus
	return Rules.attack_bonus(ability_mod(ability), proficiency(), true, magic_bonus)


func save_bonus(ability: String) -> int:
	var bonus := ability_mod(ability)
	if ability in save_proficiencies:
		bonus += proficiency()
	return bonus


func spell_save_dc(casting_ability: String = "int") -> int:
	return Rules.spell_save_dc(proficiency(), ability_mod(casting_ability))


func spell_attack_bonus(casting_ability: String = "int") -> int:
	return ability_mod(casting_ability) + proficiency()


func max_hp() -> int:
	if monster_id != "":
		var m: Dictionary = GameData.monster(monster_id)
		var hp: int = m.get("hp_fixed", 10)
		if m.get("is_boss", false):
			hp = int(hp * m.get("hp_boss_multiplier", 1.0))
		return hp
	return Rules.max_hp(hit_die, level, ability_mod("con"))


## Vitesse de déplacement en m/s : 30 pieds/round (6 s) ≈ 1,5 m/s en marche ;
## on multiplie pour un rythme action (course ≈ ×3,5).
func move_speed_mps(running: bool = true) -> float:
	var base := speed * 0.3048 / 6.0
	return base * (3.5 if running else 1.6)


## Ajoute de l'XP ; renvoie vrai si un niveau a été gagné.
func add_xp(amount: int) -> bool:
	xp += amount
	var new_level := Rules.level_for_xp(xp)
	if new_level > level:
		level = new_level
		return true
	return false


static func damage_type_from_string(s: String) -> int:
	var key := s.to_upper()
	var keys: Array = CombatRules.DamageType.keys()
	var idx := keys.find(key)
	if idx < 0:
		push_warning("Type de dégâts inconnu : " + s)
		return CombatRules.DamageType.BLUDGEONING
	return idx

class_name Rules
extends RefCounted
## Règles de base du SRD 5.1 : caractéristiques, maîtrise, XP, points de vie.
## Fonctions pures, sans état, testables hors scène.

const ABILITIES: Array[String] = ["str", "dex", "con", "int", "wis", "cha"]

## XP cumulée nécessaire pour atteindre le niveau (index + 1). Niveaux 1 à 10 (SRD).
const XP_TABLE: Array[int] = [0, 300, 900, 2700, 6500, 14000, 23000, 34000, 48000, 64000]

const MAX_LEVEL := 10


## Modificateur de caractéristique : floor((score - 10) / 2).
static func ability_mod(score: int) -> int:
	return floori((score - 10) / 2.0)


## Bonus de maîtrise : +2 aux niveaux 1-4, +3 aux 5-8, +4 aux 9-12…
static func proficiency_bonus(level: int) -> int:
	return 2 + (clampi(level, 1, 20) - 1) / 4


## Niveau atteint pour une XP cumulée donnée.
static func level_for_xp(xp: int) -> int:
	var level := 1
	for i in XP_TABLE.size():
		if xp >= XP_TABLE[i]:
			level = i + 1
	return mini(level, MAX_LEVEL)


## XP cumulée requise pour le niveau suivant (ou -1 au niveau max).
static func xp_for_next_level(level: int) -> int:
	if level >= MAX_LEVEL or level >= XP_TABLE.size():
		return -1
	return XP_TABLE[level]


## Points de vie max : niveau 1 = dé de vie max + CON ; niveaux suivants = moyenne fixe
## (dé/2 + 1) + CON par niveau. Minimum 1 PV gagné par niveau.
static func max_hp(hit_die: int, level: int, con_mod: int) -> int:
	var hp := maxi(hit_die + con_mod, 1)
	for _lvl in range(2, level + 1):
		hp += maxi(hit_die / 2 + 1 + con_mod, 1)
	return hp


## DD de sauvegarde d'un sort : 8 + maîtrise + mod de la carac d'incantation.
static func spell_save_dc(proficiency: int, casting_mod: int) -> int:
	return 8 + proficiency + casting_mod


## Bonus d'attaque : mod de carac + maîtrise (si l'arme est maîtrisée) + bonus magique.
static func attack_bonus(ability_mod_value: int, proficiency: int, proficient: bool = true, magic_bonus: int = 0) -> int:
	return ability_mod_value + (proficiency if proficient else 0) + magic_bonus


## Classe d'armure : base de l'armure + DEX (plafonné selon le type) + bouclier.
## armor_type : "none", "light", "medium", "heavy".
static func armor_class(base_ac: int, dex_mod: int, armor_type: String = "none", shield_bonus: int = 0) -> int:
	var dex := dex_mod
	match armor_type:
		"medium":
			dex = mini(dex_mod, 2)
		"heavy":
			dex = 0
	return base_ac + dex + shield_bonus

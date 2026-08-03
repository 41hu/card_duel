extends Node
# ============================================================
# Config.gd — 静态数据入口（数据定义在 scripts/data/ 下各文件）
# ============================================================

# 从独立数据文件加载
const CardData = preload("res://scripts/data/card_data.gd")
const EquipData = preload("res://scripts/data/equip_data.gd")
const CharData = preload("res://scripts/data/character_data.gd")

# ---------- 枚举 ----------
enum CardCategory {
	NEAR = 0, RANGE = 1, MAGIC = 2,
	HEAVY_STRIKE = 3, PIERCE = 4, CHANT = 5,
	MOVE = 6, ATTRACT = 7, DETER = 8, FREEZE = 9,
	DESTROY = 10, SEIZE = 11, HEAL_3 = 12, HEAL_5 = 13,
	NEAR_BUFF = 14, RANGE_BUFF = 15, MAGIC_BUFF = 16,
	BLESSING = 17, TRAP = 18,
	NEAR_WEAPON = 19, RANGE_WEAPON = 20, MAGIC_WEAPON = 21,
	NEAR_ARMOR = 22, RANGE_ARMOR = 23, MAGIC_ARMOR = 24
}

enum Phase {
	MAIN_MENU = 0, BP_PHASE = 1, PLAYER_TURN = 2,
	RESPONSE_WINDOW = 3, RESURRECTING = 4, GAME_OVER = 5
}

enum APType { NONE = 0, ATTACK = 1, MOVE = 2, FUNCTION = 3 }

enum TurnPhase { JUDGMENT = 0, DRAW = 1, ACTION = 2, DISCARD = 3 }

enum DamageType { PHYSICAL = 0, RANGED = 1, MAGICAL = 2 }

enum ResponseType { BLOCK = 0, RESTRAIN = 1, DODGE = 2 }

# AI 难度档位（与 ai_player.gd 常量一致；地狱=内测全知+高复活）
const AI_DIFF_EASY = 0
const AI_DIFF_NORMAL = 1
const AI_DIFF_HARD = 2
const AI_DIFF_HELL = 3

# ---------- 卡牌数据（来自 card_data.gd）----------
var CARD_DB = CardData.CARD_DB
var CARD_COUNTS = CardData.CARD_COUNTS
var ATTACK_CARD_TYPES = CardData.ATTACK_CARD_TYPES
var RESPONDABLE_CARDS = CardData.RESPONDABLE_CARDS

# ---------- 响应规则（来自 equip_data.gd）----------
var RESPONSE_BY = EquipData.RESPONSE_BY
var RESPOND_AS = EquipData.RESPOND_AS

# ---------- 武器/防具定义（来自 equip_data.gd）----------
var WEAPON_DB = EquipData.WEAPON_DB
var ARMOR_DB = EquipData.ARMOR_DB

# ---------- 角色定义（来自 character_data.gd）----------
var CHARACTER_DB = CharData.CHARACTER_DB
var CHARACTER_IDS = CharData.CHARACTER_IDS

# ---------- 工具函数 ----------
func card_can_be_responded(type_id: String) -> bool:
	return type_id in RESPONDABLE_CARDS

func card_response_by(type_id: String) -> Array:
	return RESPONSE_BY.get(type_id, [])

func card_response_effect(card_id: String) -> String:
	return RESPOND_AS.get(card_id, "")

# 攻击卡对应的伤害类型
func get_damage_type(type_id: String) -> int:
	match type_id:
		"near", "heavy": return DamageType.PHYSICAL
		"range", "pierce": return DamageType.RANGED
		"magic", "chant": return DamageType.MAGICAL
	return -1

# 攻击卡对应的响应类型
func get_response_type(type_id: String) -> int:
	match type_id:
		"near", "heavy": return ResponseType.BLOCK
		"range", "pierce": return ResponseType.RESTRAIN
		"magic", "chant": return ResponseType.DODGE
	return -1

# ---------- 初始牌堆构建 ----------
func build_initial_deck() -> Array:
	var deck = []
	var uid_counter = 0
	for type_id in CARD_COUNTS:
		for _i in range(CARD_COUNTS[type_id]):
			deck.append({"uid": uid_counter, "type_id": type_id})
			uid_counter += 1
	return deck

# ---------- 按类型从武器库中随机选取 ----------
func get_random_weapon(weapon_type: String, used_ids: Array) -> Dictionary:
	var pool = []
	for wid in WEAPON_DB:
		if WEAPON_DB[wid].type == weapon_type and not used_ids.has(wid):
			pool.append(wid)
	if pool.is_empty():
		return {}
	var chosen = pool[randi() % pool.size()]
	return {"id": chosen, "data": WEAPON_DB[chosen]}

# ---------- 卡牌判定 ----------
func is_attack_card(type_id: String) -> bool:
	return ATTACK_CARD_TYPES.has(type_id)

func is_heal_card(type_id: String) -> bool:
	return type_id == "heal_3" or type_id == "heal_5"

# ---------- 查询 ----------
func card_name(type_id: String) -> String:
	if CARD_DB.has(type_id):
		return CARD_DB[type_id].name
	return type_id

func char_name(char_id: String) -> String:
	if CHARACTER_DB.has(char_id):
		return CHARACTER_DB[char_id].name
	return char_id

func get_card_ap_type(type_id: String) -> int:
	if CARD_DB.has(type_id):
		return CARD_DB[type_id].ap
	return APType.NONE

func get_card_ap_cost(type_id: String) -> int:
	if CARD_DB.has(type_id):
		return CARD_DB[type_id].cost
	return 0

func clamp_position(pos: int) -> int:
	return clamp(pos, 0, 10)

# 武器 type 是否匹配伤害类型（near→PHYSICAL, range→RANGED, magic→MAGICAL）
func weapon_matches_damage_type(weapon_type: String, damage_type: int) -> bool:
	match weapon_type:
		"near": return damage_type == DamageType.PHYSICAL
		"range": return damage_type == DamageType.RANGED
		"magic": return damage_type == DamageType.MAGICAL
	return false

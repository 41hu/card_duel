extends Node
# ============================================================
# Config.gd — 静态数据定义（卡牌库、角色库、武器库、防具库、枚举）
# ============================================================

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

# ---------- 卡牌定义 ----------
# type_id -> {name, category, ap_type, ap_cost, desc}
# APType: NONE=0(免费), ATTACK=1, MOVE=2, FUNCTION=3
var CARD_DB = {
	# 基础攻击 (各8张)
	"near":     {name="近战",   cat=CardCategory.NEAR,   ap=APType.ATTACK, cost=1, desc="贴脸物理攻击"},
	"range":    {name="远程",   cat=CardCategory.RANGE,  ap=APType.ATTACK, cost=1, desc="距离衰减远程攻击"},
	"magic":    {name="魔法",   cat=CardCategory.MAGIC,  ap=APType.ATTACK, cost=1, desc="无视距离魔法攻击"},

	# 强化攻击 (各3张)
	"heavy":    {name="重击",   cat=CardCategory.HEAVY_STRIKE, ap=APType.ATTACK, cost=2, desc="贴脸近战+3"},
	"pierce":   {name="穿心",   cat=CardCategory.PIERCE, ap=APType.ATTACK, cost=2, desc="远程结算后+3"},
	"chant":    {name="吟唱",   cat=CardCategory.CHANT,  ap=APType.ATTACK, cost=2, desc="无视距离魔法+3"},

	# 位移 (7张)
	"move":     {name="移动",   cat=CardCategory.MOVE,   ap=APType.MOVE, cost=1, desc="移动1格"},

	# 功能牌 (11张)
	"attract":  {name="吸引",   cat=CardCategory.ATTRACT, ap=APType.FUNCTION, cost=1, desc="拉对方1格"},
	"deter":    {name="威慑",   cat=CardCategory.DETER,   ap=APType.FUNCTION, cost=1, desc="推对方1格"},
	"freeze":   {name="冻结",   cat=CardCategory.FREEZE,  ap=APType.FUNCTION, cost=1, desc="跳过对方下个出牌阶段"},
	"destroy":  {name="摧毁",   cat=CardCategory.DESTROY, ap=APType.FUNCTION, cost=1, desc="盲丢1手牌或摧毁1装备"},
	"seize":    {name="夺取",   cat=CardCategory.SEIZE,   ap=APType.FUNCTION, cost=1, desc="盲抽对方1手牌"},

	# 回复 (5张)
	"heal_3":   {name="回复+3", cat=CardCategory.HEAL_3,  ap=APType.NONE, cost=0, desc="回复3点HP"},
	"heal_5":   {name="回复+5", cat=CardCategory.HEAL_5,  ap=APType.NONE, cost=0, desc="回复5点HP"},

	# 面板强化 (各2张)
	"near_buf":  {name="近战+1", cat=CardCategory.NEAR_BUFF,  ap=APType.NONE, cost=0, desc="近战面板永久+1"},
	"range_buf": {name="远程+1", cat=CardCategory.RANGE_BUFF, ap=APType.NONE, cost=0, desc="远程面板永久+1"},
	"magic_buf": {name="魔法+1", cat=CardCategory.MAGIC_BUFF, ap=APType.NONE, cost=0, desc="魔法面板永久+1"},

	# 免费牌
	"blessing": {name="天赐",   cat=CardCategory.BLESSING, ap=APType.NONE, cost=0, desc="抽2张牌"},
	"trap":     {name="陷阱",   cat=CardCategory.TRAP,     ap=APType.NONE, cost=0, desc="在空格放置陷阱，触发造成3伤害"},

	# 武器牌 (各2张)
	"near_weapon":  {name="近战武器", cat=CardCategory.NEAR_WEAPON,  ap=APType.NONE, cost=0, desc="幻化随机近战武器"},
	"range_weapon": {name="远程武器", cat=CardCategory.RANGE_WEAPON, ap=APType.NONE, cost=0, desc="幻化随机远程武器"},
	"magic_weapon": {name="法术武器", cat=CardCategory.MAGIC_WEAPON, ap=APType.NONE, cost=0, desc="幻化随机法术武器"},

	# 防具牌 (各1张)
	"near_armor":  {name="近战防具", cat=CardCategory.NEAR_ARMOR,  ap=APType.NONE, cost=0, desc="装备近战防具(3耐久)"},
	"range_armor": {name="远程防具", cat=CardCategory.RANGE_ARMOR, ap=APType.NONE, cost=0, desc="装备远程防具(3耐久)"},
	"magic_armor": {name="法术防具", cat=CardCategory.MAGIC_ARMOR, ap=APType.NONE, cost=0, desc="装备法术防具(3耐久)"},
}

# ---------- 卡牌数量 ----------
var CARD_COUNTS = {
	"near": 8, "range": 8, "magic": 8,
	"heavy": 3, "pierce": 3, "chant": 3,
	"move": 7,
	"attract": 2, "deter": 2, "freeze": 2, "destroy": 3, "seize": 2,
	"heal_3": 3, "heal_5": 2,
	"near_buf": 2, "range_buf": 2, "magic_buf": 2,
	"blessing": 4, "trap": 3,
	"near_weapon": 2, "range_weapon": 2, "magic_weapon": 2,
	"near_armor": 1, "range_armor": 1, "magic_armor": 1,
}

# ---------- 攻击类卡牌 ---------- (用于响应判断)
var ATTACK_CARD_TYPES = ["near", "range", "magic", "heavy", "pierce", "chant"]

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

# ---------- 武器定义 ----------
var WEAPON_DB = {
	# 近战武器
	"flame_sword":    {name="烈焰剑",   type="near",  effect="melee_dmg",  value=2, desc="近战伤害+2"},
	"frost_bite":     {name="霜咬",     type="near",  effect="freeze_move", value=0, desc="命中后对方下回合位移=0"},
	"bloodthirst":    {name="嗜血",     type="near",  effect="vampire",    value=2, desc="近战≥3伤害时回复2HP"},
	"lunge":          {name="突刺",     type="near",  effect="lunge",      value=3, desc="近战+1，移动贴脸后额外+3"},

	# 远程武器
	"longbow":        {name="长弓",     type="range", effect="range_buff", value=1, desc="远程+1，距离衰减-1"},
	"repeater":       {name="连弩",     type="range", effect="restrain_penalty", value=2, desc="牵制额外-2"},
	"hawkeye":        {name="鹰眼",     type="range", effect="reveal_hand", value=0, desc="命中后查看对方手牌"},
	"toxic_fang":     {name="毒牙",     type="range", effect="poison",     value=2, desc="中毒-2×2回合"},

	# 法术武器
	"sage_book":      {name="贤者之书", type="magic", effect="magic_dmg",  value=2, desc="魔法伤害+2"},
	"scorch":         {name="灼烧",     type="magic", effect="burn",       value=1, desc="可叠加-1HP/回合"},
	"time_lag":       {name="时滞",     type="magic", effect="attack_down", value=1, desc="命中后对方下回合攻击-1"},
	"resonance":      {name="共鸣",     type="magic", effect="resonance",  value=2, desc="本回合已出过其他攻击则+2"},
}

# ---------- 防具定义 ----------
var ARMOR_DB = {
	"near_armor":  {name="近战防具", type="physical", desc="防近战/重击"},
	"range_armor": {name="远程防具", type="ranged",   desc="防远程/穿心"},
	"magic_armor": {name="法术防具", type="magical",  desc="防魔法/吟唱"},
}

# ---------- 角色定义 ----------
var CHARACTER_DB = {
	"swordsman":   {name="剑士",   hp=28, near=7, range=3, magic=2, skill="swordsman",   skill_desc="近战命中后：抽1牌或回2HP（每回合限一）"},
	"archer":      {name="弓手",   hp=24, near=2, range=8, magic=2, skill="archer",      skill_desc="每回合首次普通远程不消耗攻击点"},
	"mage":        {name="法师",   hp=22, near=2, range=2, magic=8, skill="mage",         skill_desc="弃1手牌，本次魔法+2（每回合限一）"},
	"paladin":     {name="圣骑士", hp=36, near=5, range=2, magic=2, skill="paladin",      skill_desc="每回合首次受伤-2（计算后，最低0）"},
	"assassin":    {name="刺客",   hp=22, near=7, range=5, magic=1, skill="assassin",     skill_desc="每回合免费移动1格（独立于位移点）"},
	"priest":      {name="牧师",   hp=28, near=2, range=4, magic=6, skill="priest",       skill_desc="使用回复卡额外+2"},
	"berserker":   {name="狂战士", hp=28, near=8, range=2, magic=2, skill="berserker",    skill_desc="受直接攻击后近战+1（持续2回合，可叠加）"},
	"warlock":     {name="术士",   hp=24, near=2, range=3, magic=7, skill="warlock",      skill_desc="功能点+1；未用功能牌则回合结束抽1张"},
}

# 角色ID列表 (按顺序)
var CHARACTER_IDS = ["swordsman", "archer", "mage", "paladin", "assassin", "priest", "berserker", "warlock"]

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

# ---------- 卡牌是否为攻击牌 ----------
func is_attack_card(type_id: String) -> bool:
	return ATTACK_CARD_TYPES.has(type_id)

# ---------- 卡牌是否为回复牌 ----------
func is_heal_card(type_id: String) -> bool:
	return type_id == "heal_3" or type_id == "heal_5"

# ---------- 工具函数 ----------
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

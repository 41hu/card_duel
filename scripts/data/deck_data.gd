# deck_data.gd — 自定义卡组数据层（构筑规则 / 套餐 / user:// 存档 / 校验）
# 构筑规则（方案 B 大池设计，玩家确认）：
#   40 张卡组，四大池总上限：
#     攻击池   17：普通攻击 + 强化攻击（强化攻击子上限 5，穿甲机制防堆叠）
#     战术池   14：移动 + 功能5种 + 天赐 + 陷阱
#     回复数值池 6：回复套餐 + 数值加成（套餐制，回复与数值互相挤占）
#     装备池    5：武器 3 + 防具 2
#   池上限之和 42 > 40，强制玩家跨池取舍 2 张。
# 单卡上限防极端：普通攻击 6（防 17 张全塞一种）、强化攻击 2、freeze 2、防具 1、其余默认 3。
# 战术卡放宽依据：每回合功能点有限（默认 1），控制卡使用速率被回合制锁死，堆叠边际收益递减。
extends RefCounted

const CardData = preload("res://scripts/data/card_data.gd")

const DECK_SIZE = 40           # 每副卡组张数
const SLOTS_PER_CHAR = 3       # 每角色卡组槽位数
const SAVE_PATH = "user://decks.json"

# ---------- 单卡上限 ----------
const CARD_LIMITS = {
	# 普通攻击：上限 6（攻击池 17 内防全塞一种）
	"near": 6, "range": 6, "magic": 6,
	# 强化攻击：上限 2（带穿甲机制，防单种堆叠）
	"heavy": 2, "pierce": 2, "chant": 2,
	# 冻结：最强控制（跳回合），保持 2
	"freeze": 2,
	# 移动：战术池内上限 4（位移是节奏核心，稍放宽）
	"move": 4,
	# 道具卡：上限 5（照顾道具流角色——猎人夹子堆叠/巫女鸟居，全靠 trap 卡）
	"trap": 5,
	# 防具：上限 1（原 78 池各 1 张）
	"near_armor": 1, "range_armor": 1, "magic_armor": 1,
}
# 默认 3：move / attract / deter / seize / destroy / blessing / trap / 武器
const DEFAULT_CARD_LIMIT = 3

# ---------- 大池总上限（玩家核心取舍机制） ----------
const CATEGORY_LIMITS = {
	"attack": {"cards": ["near", "range", "magic", "heavy", "pierce", "chant"], "max": 17},
	"tactics": {"cards": ["move", "attract", "deter", "freeze", "destroy", "seize", "blessing", "trap"], "max": 14},
	"sustain": {"cards": ["heal_3", "heal_5", "near_buf", "range_buf", "magic_buf"], "max": 6},
	"equipment": {"cards": ["near_weapon", "range_weapon", "magic_weapon", "near_armor", "range_armor", "magic_armor"], "max": 5},
}

# ---------- 池内子上限 ----------
const SUB_LIMITS = {
	"强化攻击": {"cards": ["heavy", "pierce", "chant"], "max": 5},
	"武器": {"cards": ["near_weapon", "range_weapon", "magic_weapon"], "max": 3},
	"防具": {"cards": ["near_armor", "range_armor", "magic_armor"], "max": 2},
}

# ---------- 回复套餐（回复卡组合 + 数值加成配额，回复与数值互相挤占） ----------
# A：回复最少、数值最多（4张可堆2）；B：均衡；C：回复最多、数值最少
const HEAL_PACKAGES = {
	"A": {"name": "A套餐", "desc": "回复+5×2（回10）｜数值加成最多4张，单卡≤2",
		"heal": {"heal_5": 2, "heal_3": 0}, "buf_max": 4, "buf_card_limit": 2},
	"B": {"name": "B套餐", "desc": "回复+5×1 + 回复+3×2（回11）｜数值加成最多3张，单卡≤1",
		"heal": {"heal_5": 1, "heal_3": 2}, "buf_max": 3, "buf_card_limit": 1},
	"C": {"name": "C套餐", "desc": "回复+3×4（回12）｜数值加成最多2张，单卡≤1",
		"heal": {"heal_5": 0, "heal_3": 4}, "buf_max": 2, "buf_card_limit": 1},
}
const DEFAULT_PACKAGE = "B"

const BUF_CARDS = ["near_buf", "range_buf", "magic_buf"]

# ---------- 武器幻化池（自定义卡组附带：每类型恰好 4 把） ----------

const WEAPON_POOL_TYPES = ["near", "range", "magic"]
const WEAPON_POOL_SIZE = 4

# 默认武器池 = 当前武器库全部武器（按类型分组，现在每类正好 4 把）
static func default_weapon_pool() -> Dictionary:
	var pool := {"near": [], "range": [], "magic": []}
	for wid in Config.WEAPON_DB:
		var t = str(Config.WEAPON_DB[wid].type)
		if pool.has(t):
			pool[t].append(wid)
	return pool

# 校验武器池：每类型恰好 4 个且都是该类型的合法武器
static func validate_weapon_pool(pool: Dictionary) -> bool:
	if not (pool is Dictionary): return false
	for t in WEAPON_POOL_TYPES:
		var ids = pool.get(t, [])
		if not (ids is Array) or ids.size() != WEAPON_POOL_SIZE:
			return false
		for wid in ids:
			if not Config.WEAPON_DB.has(str(wid)): return false
			if str(Config.WEAPON_DB[str(wid)].type) != t: return false
	return true

# 归一化：非法/缺字段 → 默认池（旧存档兼容）
static func normalize_weapon_pool(pool) -> Dictionary:
	if validate_weapon_pool(pool):
		return pool.duplicate(true)
	return default_weapon_pool()

# ---------- 卡池 ----------

# 卡池 type_id 列表（按 CARD_DB 定义顺序）
static func pool_ids() -> Array:
	return CardData.CARD_DB.keys()

static func is_valid_card(type_id: String) -> bool:
	return CardData.CARD_DB.has(type_id)

static func card_name(type_id: String) -> String:
	return CardData.CARD_DB.get(type_id, {}).get("name", type_id)

# 编辑界面显示名：道具卡（trap）统一显示"道具"（不同角色的道具种类不同：默认陷阱/猎人捕兽夹/巫女鸟居）
static func display_name(type_id: String) -> String:
	if type_id == "trap":
		return "道具"
	return card_name(type_id)

# 单卡上限（数值卡按套餐的 buf_card_limit，其余按 CARD_LIMITS/默认）
static func card_limit(type_id: String, package_id: String = DEFAULT_PACKAGE) -> int:
	if type_id in BUF_CARDS:
		var pkg: Dictionary = HEAL_PACKAGES.get(package_id, HEAL_PACKAGES[DEFAULT_PACKAGE])
		return int(pkg.get("buf_card_limit", 1))
	if type_id in ["heal_3", "heal_5"]:
		return 4  # 回复卡数量由套餐校验兜底（套餐固定组合），此处放宽单卡上限（套餐C需heal_3×4）
	return int(CARD_LIMITS.get(type_id, DEFAULT_CARD_LIMIT))

# ---------- 大池归属 ----------

static func category_of(type_id: String) -> String:
	for cat in CATEGORY_LIMITS:
		if type_id in CATEGORY_LIMITS[cat].cards:
			return cat
	return "attack"

static func category_max(cat: String) -> int:
	return int(CATEGORY_LIMITS.get(cat, {}).get("max", 0))

static func category_name(cat: String) -> String:
	match cat:
		"attack": return "攻击池"
		"tactics": return "战术池"
		"sustain": return "回复与数值"
		_: return "装备池"

# 卡牌分组（编辑界面按大池分组显示）
static func card_group(type_id: String) -> String:
	return category_of(type_id)

static func group_name(group: String) -> String:
	return "%s（上限%d）" % [category_name(group), category_max(group)]

# ---------- 标准卡组 ----------

# 标准卡组 = 默认 78 张的 type_id 列表（经典模式共享堆构成）
static func standard_deck() -> Array:
	var ids: Array = []
	for type_id in CardData.CARD_COUNTS:
		for _i in range(CardData.CARD_COUNTS[type_id]):
			ids.append(type_id)
	return ids

# 默认 40 张卡组（自定义卡组模式的「默认卡组」选项；套餐 B）
# 构成：攻击16 + 战术13 + 回复数值6(套餐B) + 装备5 = 40
static func default_deck() -> Array:
	var plan := {
		"near": 4, "range": 4, "magic": 3, "heavy": 2, "pierce": 2, "chant": 1,  # 攻击 16（强化5）
		"move": 4,
		"attract": 2, "deter": 2, "freeze": 1, "destroy": 1, "seize": 1, "blessing": 1, "trap": 1,  # 战术 13
		"heal_5": 1, "heal_3": 2,  # 套餐 B 回复 3
		"near_buf": 1, "range_buf": 1, "magic_buf": 1,  # 数值 3
		"near_weapon": 1, "range_weapon": 1, "magic_weapon": 1,  # 武器 3
		"near_armor": 1, "range_armor": 1,  # 防具 2
	}
	var ids: Array = []
	for type_id in plan:
		for _i in range(plan[type_id]):
			ids.append(type_id)
	return ids

# ---------- 校验 ----------

# 校验一副卡组：{ok, msg, count, over:{type_id:数量}}
# 检查顺序：非法卡 → 张数 → 单卡上限 → 大池总上限 → 子上限 → 套餐规则
static func validate_deck(cards: Array, package_id: String = DEFAULT_PACKAGE) -> Dictionary:
	var over := {}
	var counts := {}
	for c in cards:
		var tid = str(c)
		if not is_valid_card(tid):
			return {"ok": false, "msg": "包含非法卡: %s" % tid, "count": cards.size(), "over": {}}
		counts[tid] = int(counts.get(tid, 0)) + 1
		var lim = card_limit(tid, package_id)
		if int(counts[tid]) > lim:
			over[tid] = int(counts[tid])
	if cards.size() != DECK_SIZE:
		return {"ok": false, "msg": "卡组需 %d 张，当前 %d 张" % [DECK_SIZE, cards.size()], "count": cards.size(), "over": {}}
	if not over.is_empty():
		var parts: Array = []
		for tid in over:
			parts.append("%s×%d（上限%d）" % [card_name(tid), over[tid], card_limit(tid, package_id)])
		return {"ok": false, "msg": "超出单卡上限：" + "，".join(parts), "count": cards.size(), "over": over}
	# 大池总上限
	var cat_counts := {}
	for tid in counts:
		var cat = category_of(tid)
		cat_counts[cat] = int(cat_counts.get(cat, 0)) + counts[tid]
	for cat in CATEGORY_LIMITS:
		var used = int(cat_counts.get(cat, 0))
		var mx = int(CATEGORY_LIMITS[cat].max)
		if used > mx:
			return {"ok": false, "msg": "%s超出：%d/%d" % [category_name(cat), used, mx], "count": cards.size(), "over": {}}
	# 子上限
	for sub in SUB_LIMITS:
		var used2 := 0
		for tid in SUB_LIMITS[sub].cards:
			used2 += int(counts.get(tid, 0))
		var mx2 = int(SUB_LIMITS[sub].max)
		if used2 > mx2:
			return {"ok": false, "msg": "%s超出：%d/%d" % [sub, used2, mx2], "count": cards.size(), "over": {}}
	# 套餐规则：回复卡必须恰好等于套餐组合；数值卡总数 ≤ 配额
	var pkg: Dictionary = HEAL_PACKAGES.get(package_id, HEAL_PACKAGES[DEFAULT_PACKAGE])
	for tid in pkg.heal:
		var want = int(pkg.heal[tid])
		var have = int(counts.get(tid, 0))
		if have != want:
			return {"ok": false, "msg": "%s 要求 %s×%d（当前×%d）" % [pkg.name, card_name(tid), want, have], "count": cards.size(), "over": {}}
	var buf_total := 0
	for tid in BUF_CARDS:
		buf_total += int(counts.get(tid, 0))
	if buf_total > int(pkg.buf_max):
		return {"ok": false, "msg": "%s 数值加成最多 %d 张（当前 %d）" % [pkg.name, pkg.buf_max, buf_total], "count": cards.size(), "over": {}}
	return {"ok": true, "msg": "", "count": cards.size(), "over": {}}

# 统计卡组构成：{大池: 数量}（编辑界面显示预算）
static func summarize(cards: Array) -> Dictionary:
	var g := {}
	for c in cards:
		var cat = category_of(str(c))
		g[cat] = int(g.get(cat, 0)) + 1
	return g

# ---------- user:// 存档 ----------
# 结构：{char_id: {"1": {name, package, cards:[type_id...]}, "2": ..., "3": ...}}

static func _empty_char_entry() -> Dictionary:
	var entry := {}
	for i in range(1, SLOTS_PER_CHAR + 1):
		entry[str(i)] = {"name": "", "package": DEFAULT_PACKAGE, "cards": [], "weapon_pool": default_weapon_pool()}
	return entry

static func load_all() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var f = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary:
		return data
	return {}

static func save_all(data: Dictionary) -> bool:
	var f = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[DeckData] 无法写入存档: %s" % SAVE_PATH)
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true

# 读某角色的全部槽位（无记录返回 3 个空槽；旧存档补 package/weapon_pool 字段）
static func get_char_decks(char_id: String) -> Dictionary:
	var all = load_all()
	if not all.has(char_id):
		return _empty_char_entry()
	var entry: Dictionary = all[char_id]
	for s in entry:
		if entry[s] is Dictionary:
			if not entry[s].has("package"):
				entry[s]["package"] = DEFAULT_PACKAGE
			entry[s]["weapon_pool"] = normalize_weapon_pool(entry[s].get("weapon_pool", {}))
	return entry

# 读某槽位：{name, package, cards}（无配置返回 {}）
static func get_deck(char_id: String, slot: int) -> Dictionary:
	var entry = get_char_decks(char_id)
	return entry.get(str(slot), {})

# 写某槽位；cards 不合法时拒绝写入（weapon_pool 非法自动回默认池）
static func set_deck(char_id: String, slot: int, name: String, package_id: String, cards: Array, weapon_pool: Dictionary = {}) -> Dictionary:
	var v = validate_deck(cards, package_id)
	if not v.ok:
		return v
	var all = load_all()
	if not all.has(char_id):
		all[char_id] = _empty_char_entry()
	all[char_id][str(slot)] = {
		"name": name, "package": package_id, "cards": cards.duplicate(),
		"weapon_pool": normalize_weapon_pool(weapon_pool),
	}
	save_all(all)
	return {"ok": true, "msg": "已保存"}

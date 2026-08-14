# deck_data.gd — 自定义卡组数据层（限额规则 / user:// 存档 / 校验）
# 归属说明：
#   · 限额常量（DECK_SIZE / CARD_LIMITS / SLOTS_PER_CHAR）属于数值层 —— 平衡性开发者调整
#   · 存档读写 / 校验逻辑为基础功能 —— 主维护者维护
# 卡组构成：每副 DECK_SIZE 张，从 78 张卡池中选取，受单卡上限约束。
# 密度控制原理：原 78 张共享堆整副循环，单卡出现密度 = 数量/78。
#   自定义 40 张卡组若带满 3 张，密度 7.5% 是原版（2.6%~10.3%）的高位，
#   永久成长牌与强干扰牌必须收紧上限，避免节奏失衡（见 CARD_LIMITS 注释）。
extends RefCounted

const CardData = preload("res://scripts/data/card_data.gd")

const DECK_SIZE = 40           # 每副卡组张数
const SLOTS_PER_CHAR = 3       # 每角色卡组槽位数
const SAVE_PATH = "user://decks.json"

# 单卡数量上限：默认 3（玩家已确认）；以下特例收紧：
#   · 永久成长牌（近战+1/远程+1/魔法+1）限 1 —— 原 78 张堆各 2 张(密度2.6%)，40 张带 1 张(2.5%) 贴近原节奏；
#     若放 3 张则密度 7.5%，面板成长速度翻近 3 倍，对局失衡。
#   · 强干扰牌（冻结/夺取/吸引/威慑/摧毁）限 2 —— 原各 2~3 张(2.6%~3.8%)，40 张带 2 张(5%) 略高可接受；
#     放 3 张则 7.5%，控制链过强。
const CARD_LIMITS = {
	"near_buf": 1, "range_buf": 1, "magic_buf": 1,
	"freeze": 2, "seize": 2, "attract": 2, "deter": 2, "destroy": 2,
}
const DEFAULT_CARD_LIMIT = 3

# ---------- 卡池 ----------

# 卡池 type_id 列表（按 CARD_DB 定义顺序）
static func pool_ids() -> Array:
	return CardData.CARD_DB.keys()

static func is_valid_card(type_id: String) -> bool:
	return CardData.CARD_DB.has(type_id)

static func card_name(type_id: String) -> String:
	return CardData.CARD_DB.get(type_id, {}).get("name", type_id)

static func card_limit(type_id: String) -> int:
	return int(CARD_LIMITS.get(type_id, DEFAULT_CARD_LIMIT))

# 卡牌分类（编辑界面分组显示）：attack / move / function / heal / buff / free / equip
static func card_group(type_id: String) -> String:
	if type_id in ["near", "range", "magic", "heavy", "pierce", "chant"]:
		return "attack"
	if type_id == "move":
		return "move"
	if type_id in ["attract", "deter", "freeze", "destroy", "seize"]:
		return "function"
	if type_id in ["heal_3", "heal_5"]:
		return "heal"
	if type_id in ["near_buf", "range_buf", "magic_buf"]:
		return "buff"
	if type_id in ["blessing", "trap"]:
		return "free"
	return "equip"

static func group_name(group: String) -> String:
	match group:
		"attack": return "攻击"
		"move": return "位移"
		"function": return "功能"
		"heal": return "回复"
		"buff": return "永久强化"
		"free": return "免费牌"
		_ : return "装备"

# ---------- 标准卡组 ----------

# 标准卡组 = 默认 78 张的 type_id 列表（经典模式共享堆构成）
static func standard_deck() -> Array:
	var ids: Array = []
	for type_id in CardData.CARD_COUNTS:
		for _i in range(CardData.CARD_COUNTS[type_id]):
			ids.append(type_id)
	return ids

# 默认 40 张卡组（自定义卡组模式的「默认卡组」选项；初版配比，平衡性开发者精调）
# 配比思路：按原 78 张各牌类比例 × 40/78 缩放，密度与原版接近：
#   攻击17(42.5%) 移动3(7.5%) 功能6(15%) 回复4(10%) 成长3(7.5%) 免费3(7.5%) 武器3(7.5%) 防具1(2.5%)
static func default_deck() -> Array:
	var plan := {
		"near": 3, "range": 3, "magic": 3, "heavy": 3, "pierce": 3, "chant": 2,
		"move": 3,
		"attract": 2, "deter": 1, "freeze": 1, "destroy": 1, "seize": 1,
		"heal_3": 2, "heal_5": 2,
		"near_buf": 1, "range_buf": 1, "magic_buf": 1,
		"blessing": 2, "trap": 1,
		"near_weapon": 1, "range_weapon": 1, "magic_weapon": 1,
		"near_armor": 1,
	}
	var ids: Array = []
	for type_id in plan:
		for _i in range(plan[type_id]):
			ids.append(type_id)
	return ids

# ---------- 校验 ----------

# 校验一副卡组：{ok, msg, count, over:{type_id:数量}}  over = 超限卡明细
static func validate_deck(cards: Array) -> Dictionary:
	var over := {}
	var counts := {}
	var ok := true
	var msg := ""
	for c in cards:
		var tid = str(c)
		if not is_valid_card(tid):
			ok = false
			msg = "包含非法卡: %s" % tid
			break
		counts[tid] = int(counts.get(tid, 0)) + 1
		var lim = card_limit(tid)
		if int(counts[tid]) > lim:
			over[tid] = int(counts[tid])
	if ok and cards.size() != DECK_SIZE:
		ok = false
		msg = "卡组需 %d 张，当前 %d 张" % [DECK_SIZE, cards.size()]
	if ok and not over.is_empty():
		ok = false
		var parts: Array = []
		for tid in over:
			parts.append("%s×%d（上限%d）" % [card_name(tid), over[tid], card_limit(tid)])
		msg = "超出单卡上限：" + "，".join(parts)
	return {"ok": ok, "msg": msg, "count": cards.size(), "over": over}

# 统计卡组构成：{group: 数量}（编辑界面显示）
static func summarize(cards: Array) -> Dictionary:
	var g := {}
	for c in cards:
		var grp = card_group(str(c))
		g[grp] = int(g.get(grp, 0)) + 1
	return g

# ---------- user:// 存档 ----------
# 结构：{char_id: {"1": {name, cards:[type_id...]}, "2": ..., "3": ...}}

static func _empty_char_entry() -> Dictionary:
	var entry := {}
	for i in range(1, SLOTS_PER_CHAR + 1):
		entry[str(i)] = {"name": "", "cards": []}
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

# 读某角色的全部槽位（无记录返回 3 个空槽）
static func get_char_decks(char_id: String) -> Dictionary:
	var all = load_all()
	return all.get(char_id, _empty_char_entry())

# 读某槽位：{name, cards}（无配置返回 {}）
static func get_deck(char_id: String, slot: int) -> Dictionary:
	var entry = get_char_decks(char_id)
	return entry.get(str(slot), {})

# 写某槽位；cards 不合法时拒绝写入
static func set_deck(char_id: String, slot: int, name: String, cards: Array) -> Dictionary:
	var v = validate_deck(cards)
	if not v.ok:
		return v
	var all = load_all()
	if not all.has(char_id):
		all[char_id] = _empty_char_entry()
	all[char_id][str(slot)] = {"name": name, "cards": cards.duplicate()}
	save_all(all)
	return {"ok": true, "msg": "已保存"}

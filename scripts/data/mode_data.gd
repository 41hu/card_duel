# mode_data.gd — 对战模式注册表
# 每种模式定义 id/名称/简介/上限人数/规则要点/默认规则开关。
# 新增模式（如夺旗）只需在此加一行，mode_select.gd 会自适应渲染卡片，无需改其他逻辑。
extends RefCounted

# 规则开关字段（config 字典的 key，客户端/服务端共用）：
#   hand_limit          手牌上限（-1 = 默认动态：到己方板边距离 + 1）
#   hand_min            手牌下限
#   shared_deck         共享牌堆（true = 双方一副牌；false = 各自独立牌堆）
#   infinite_play       无限出牌（不消耗行动点）
#   freeze_no_cooldown  冻结无冷却（可连续冻结）
#   blessing_unlimited  天赐不限次数
#   resurrect_limit     复活次数上限（-1 = 无限）
const CONFIG_DEFAULTS = {
	"hand_limit": -1,
	"hand_min": 0,
	"shared_deck": true,
	"infinite_play": false,
	"freeze_no_cooldown": false,
	"blessing_unlimited": false,
	"resurrect_limit": -1,
}

# 配置区渲染 schema：mode_select.gd 遍历此表生成规则行。
# type: "int"(加减数值) / "bool"(开关)；min/max 约束数值；default_label 为默认值显示文案。
const CONFIG_SCHEMA = [
	{"key": "hand_limit", "label": "手牌上限", "type": "int", "min": 1, "max": 12, "default_label": "默认"},
	{"key": "hand_min", "label": "手牌下限", "type": "int", "min": 0, "max": 5},
	{"key": "shared_deck", "label": "共享牌堆", "type": "bool"},
	{"key": "infinite_play", "label": "无限出牌", "type": "bool"},
	{"key": "freeze_no_cooldown", "label": "冻结无冷却", "type": "bool"},
	{"key": "blessing_unlimited", "label": "天赐不限次数", "type": "bool"},
	{"key": "resurrect_limit", "label": "复活次数上限", "type": "int", "min": -1, "max": 10, "default_label": "无限"},
]

const MODES = [
	{
		"id": "classic",
		"name": "经典模式",
		"desc": "双人标准对战",
		"max_players": 2,
		"features": "共享牌堆 · BP禁选 · 标准规则",
		"selectable": true,
		"config": {},  # 空 = 全部默认
	},
	{
		"id": "rapid",
		"name": "快速模式",
		"desc": "双人快速对战",
		"max_players": 2,
		"features": "无限出牌 · 冻结连续 · 天赐不限",
		"selectable": true,
		"config": {"infinite_play": true, "freeze_no_cooldown": true, "blessing_unlimited": true},
	},
	{
		"id": "ffa",
		"name": "四人混战",
		"desc": "多人自由混战",
		"max_players": 4,
		"features": "六边形地图 · 独立牌堆",
		"selectable": true,
		"config": {"shared_deck": false},  # 默认各自独立牌堆
	},
	{
		"id": "custom_deck",
		"name": "自定义卡组",
		"desc": "40张自组卡牌对战",
		"max_players": 2,
		"features": "独立牌堆 · BP后配置卡组",
		"selectable": true,
		"config": {"shared_deck": false},  # 自定义卡组 = 独立牌堆
	},
	{
		"id": "more",
		"name": "更多模式",
		"desc": "开发中",
		"max_players": 0,
		"features": "敬请期待",
		"selectable": false,
		"config": {},
	},
]

# 根据 id 取模式（不存在返回空字典）
static func get_mode(id: String) -> Dictionary:
	for m in MODES:
		if m.id == id:
			return m
	return {}

static func is_selectable(id: String) -> bool:
	var m = get_mode(id)
	return not m.is_empty() and m.selectable

# 合并「默认值 + 模式预设 + 玩家自定义」得到最终 config
static func merge_config(mode_id: String, overrides: Dictionary = {}) -> Dictionary:
	var cfg = CONFIG_DEFAULTS.duplicate()
	var m = get_mode(mode_id)
	if not m.is_empty() and m.config is Dictionary:
		for k in m.config:
			cfg[k] = m.config[k]
	for k in overrides:
		cfg[k] = overrides[k]
	return cfg

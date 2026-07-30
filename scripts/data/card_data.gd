# card_data.gd — 卡牌数据定义（78张卡牌池）
extends RefCounted

const CARD_DB = {
	# 基础攻击 (各8张)
	"near":     {name="近战",   ap=1, cost=1, desc="贴脸物理攻击"},
	"range":    {name="远程",   ap=1, cost=1, desc="距离衰减远程攻击"},
	"magic":    {name="魔法",   ap=1, cost=1, desc="无视距离魔法攻击"},

	# 强化攻击 (各3张)
	"heavy":    {name="重击",   ap=1, cost=2, desc="贴脸近战+3"},
	"pierce":   {name="穿心",   ap=1, cost=2, desc="远程结算后+3"},
	"chant":    {name="吟唱",   ap=1, cost=2, desc="无视距离魔法+3"},

	# 位移 (7张)
	"move":     {name="移动",   ap=2, cost=1, desc="移动1格"},

	# 功能牌 (11张)
	"attract":  {name="吸引",   ap=3, cost=1, desc="拉对方1格"},
	"deter":    {name="威慑",   ap=3, cost=1, desc="推对方1格"},
	"freeze":   {name="冻结",   ap=3, cost=1, desc="跳过对方下个出牌阶段"},
	"destroy":  {name="摧毁",   ap=3, cost=1, desc="盲丢1手牌或摧毁1装备"},
	"seize":    {name="夺取",   ap=3, cost=1, desc="盲抽对方1手牌"},

	# 回复 (5张)
	"heal_3":   {name="回复+3", ap=0, cost=0, desc="回复3点HP"},
	"heal_5":   {name="回复+5", ap=0, cost=0, desc="回复5点HP"},

	# 面板强化 (各2张)
	"near_buf":  {name="近战+1", ap=0, cost=0, desc="近战面板永久+1"},
	"range_buf": {name="远程+1", ap=0, cost=0, desc="远程面板永久+1"},
	"magic_buf": {name="魔法+1", ap=0, cost=0, desc="魔法面板永久+1"},

	# 免费牌
	"blessing": {name="天赐",   ap=0, cost=0, desc="抽2张牌"},
	"trap":     {name="陷阱",   ap=0, cost=0, desc="在空格放置陷阱，触发造成3伤害"},

	# 武器牌 (各2张)
	"near_weapon":  {name="近战武器", ap=0, cost=0, desc="幻化随机近战武器"},
	"range_weapon": {name="远程武器", ap=0, cost=0, desc="幻化随机远程武器"},
	"magic_weapon": {name="法术武器", ap=0, cost=0, desc="幻化随机法术武器"},

	# 防具牌 (各1张)
	"near_armor":  {name="近战防具", ap=0, cost=0, desc="装备近战防具(3耐久)"},
	"range_armor": {name="远程防具", ap=0, cost=0, desc="装备远程防具(3耐久)"},
	"magic_armor": {name="法术防具", ap=0, cost=0, desc="装备法术防具(3耐久)"},
}

const CARD_COUNTS = {
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

const ATTACK_CARD_TYPES = ["near", "range", "magic", "heavy", "pierce", "chant"]
const RESPONDABLE_CARDS = ["near", "range", "magic", "heavy", "pierce", "chant", "freeze"]

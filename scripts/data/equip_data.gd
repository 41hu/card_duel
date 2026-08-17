# equip_data.gd — 武器和防具数据定义
extends RefCounted

const WEAPON_DB = {
	# 近战武器
	"iron_cutter":    {name="斩铁",     type="near",  effect="melee_dmg",  value=2, desc="近战伤害+2"},
	"frost_bite":     {name="霜咬",     type="near",  effect="freeze_move", value=0, desc="命中后对方下回合位移=0"},
	"bloodthirst":    {name="嗜血",     type="near",  effect="vampire",    value=2, desc="近战≥3伤害时回复2HP"},
	"lunge":          {name="突刺",     type="near",  effect="lunge",      value=3, desc="近战+1，移动贴脸后额外+3"},

	# 远程武器
	"longbow":        {name="长弓",     type="range", effect="range_buff", value=1, desc="远程+1，距离衰减-1"},
	"repeater":       {name="连弩",     type="range", effect="restrain_penalty", value=2, desc="牵制额外-2"},
	"hawkeye":        {name="鹰眼",     type="range", effect="reveal_hand", value=0, desc="命中后查看对方手牌"},
	"toxic_fang":     {name="毒牙",     type="range", effect="poison",     value=2, desc="中毒2层（每回合-1HP，可叠加）"},

	# 法术武器
	"sage_book":      {name="贤者之书", type="magic", effect="magic_dmg",  value=2, desc="魔法伤害+2"},
	"scorch":         {name="灼烧",     type="magic", effect="burn",       value=1, desc="-2HP/回合×2回合（再次命中刷新）"},
	"time_lag":       {name="时滞",     type="magic", effect="ap_attack_down", value=1, desc="命中后对方下回合攻击行动点-1"},
	"resonance":      {name="共鸣",     type="magic", effect="armor_reduce", value=2, desc="法术命中后减少对方护甲耐久2点"},
}

const ARMOR_DB = {
	"near_armor":  {name="近战防具", type="physical", desc="防近战/重击"},
	"range_armor": {name="远程防具", type="ranged",   desc="防远程/穿心"},
	"magic_armor": {name="法术防具", type="magical",  desc="防魔法/吟唱"},
	# 饲甲人专属魔甲：全类型减半、无满耐久免疫、0 耐久无减伤、不碎裂（规则特判见 combat_system）
	"demon_armor": {name="活铠",     type="all",      desc="全类型攻击伤害减半（无完全免疫；0耐久无减伤）"},
}

const RESPONSE_BY = {
	"near":   ["near"],           # 格挡
	"heavy":  ["near"],           # 格挡
	"range":  ["range"],          # 牵制
	"pierce": ["range", "magic"], # 牵制或闪避
	"magic":  ["range", "magic"], # 牵制或闪避
	"chant":  ["range", "magic"], # 牵制或闪避
	"freeze": ["magic"],          # 闪避
}

const RESPOND_AS = {
	"near":  "block",
	"range": "restrain",
	"magic": "dodge",
}

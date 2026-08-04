# character_data.gd — 角色数据定义（13名角色）
extends RefCounted

const CHARACTER_DB = {
	"fighter":   {name="斗士",   hp=28, near=7, range=3, magic=2, skill="fighter",   skill_desc="近战命中后：抽1牌或回2HP（每回合限一）"},
	"sharpshooter":      {name="神射手", hp=24, near=2, range=8, magic=2, skill="sharpshooter",      skill_desc="每回合首次普通远程不消耗攻击点"},
	"mage":        {name="法师",   hp=22, near=2, range=2, magic=8, skill="mage",         skill_desc="弃1手牌，魔法强化+2（每回合限一次，可叠加；打出魔法攻击后清除）"},
	"paladin":     {name="圣骑士", hp=26, near=4, range=1, magic=3, skill="paladin",      skill_desc="每回合首次受伤-2（最低0）"},
	"assassin":    {name="刺客",   hp=22, near=7, range=5, magic=1, skill="assassin",     skill_desc="每回合免费移动1格（独立于位移点）"},
	"priest":      {name="牧师",   hp=28, near=2, range=4, magic=6, skill="priest",       skill_desc="使用回复卡额外+2；受到DoT伤害后清除该类DoT"},
	"berserker":   {name="狂战士", hp=28, near=8, range=2, magic=2, skill="berserker",    skill_desc="受直接攻击后获得狂化（近战+1，持续3回合，可叠加）"},
	"warlock":     {name="邪术师", hp=24, near=2, range=3, magic=3, skill="warlock",      skill_desc="功能点+1；未用功能牌则回合结束抽1张；自身回血效果-1"},
	"gunslinger":  {name="快枪手", hp=26, near=2, range=6, magic=2, skill="gunslinger",   skill_desc="远程双发：固定消耗2攻击点，造成两段伤害，两段各需一次响应"},
	"hunter":      {name="猎人",   hp=26, near=4, range=5, magic=2, skill="hunter",       skill_desc="埋伏：弃「远程」卡耗1攻击点放1个捕兽夹；弃「穿心」卡耗2攻击点放2个捕兽夹（每回合限一次）"},
	"tracker":     {name="寻踪者", hp=24, near=4, range=5, magic=2, skill="tracker",      skill_desc="远程/法术命中获得1层校准（每层远程伤害+1，永久叠加）；远程/法术攻击未造成伤害则校准清空"},
	"wardsmith":   {name="铸甲师", hp=27, near=4, range=2, magic=4, skill="wardsmith",    skill_desc="护甲注魔：装备一种护甲（限一次）；修复：耗2攻击点+弃强化攻击卡修1耐久；护甲耐久+1"},
	"spellblade":  {name="魔剑士", hp=23, near=6, range=2, magic=4, skill="spellblade",   skill_desc="魔力引导：装备近战武器时，弃「魔法」卡耗1攻击点视作打出「近战」，弃「吟唱」卡耗2攻击点视作打出「重击」，均无视距离（可被格挡）", skill_turn_limit=-1},
	"miko":        {name="巫女",   hp=24, near=2, range=3, magic=3, skill="miko",         skill_desc="结界：道具卡放置鸟居，自己踩上+2HP并全属性+1（永久）；敌人踩上进入神隐（跳过下回合）；鸟居可被摧毁卡拆除"},
}

const CHARACTER_IDS = ["fighter", "sharpshooter", "mage", "paladin", "assassin", "priest", "berserker", "warlock", "gunslinger", "hunter", "tracker", "wardsmith", "spellblade", "miko"]

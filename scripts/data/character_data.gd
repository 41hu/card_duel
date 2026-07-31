# character_data.gd — 角色数据定义（8名角色）
extends RefCounted

const CHARACTER_DB = {
	"swordsman":   {name="剑士",   hp=28, near=7, range=3, magic=2, skill="swordsman",   skill_desc="近战命中后：抽1牌或回2HP（每回合限一）"},
	"archer":      {name="弓手",   hp=24, near=2, range=8, magic=2, skill="archer",      skill_desc="每回合首次普通远程不消耗攻击点"},
	"mage":        {name="法师",   hp=22, near=2, range=2, magic=8, skill="mage",         skill_desc="弃1手牌，本次魔法+2（每回合限一）"},
	"paladin":     {name="圣骑士", hp=36, near=5, range=2, magic=2, skill="paladin",      skill_desc="每回合首次受伤-2（最低0）；防具耐久+1"},
	"assassin":    {name="刺客",   hp=22, near=7, range=5, magic=1, skill="assassin",     skill_desc="每回合免费移动1格（独立于位移点）"},
	"priest":      {name="牧师",   hp=28, near=2, range=4, magic=6, skill="priest",       skill_desc="使用回复卡额外+2"},
	"berserker":   {name="狂战士", hp=28, near=8, range=2, magic=2, skill="berserker",    skill_desc="受直接攻击后近战+1（持续2回合，可叠加）"},
	"warlock":     {name="术士",   hp=24, near=2, range=3, magic=7, skill="warlock",      skill_desc="功能点+1；未用功能牌则回合结束抽1张"},
}

const CHARACTER_IDS = ["swordsman", "archer", "mage", "paladin", "assassin", "priest", "berserker", "warlock"]

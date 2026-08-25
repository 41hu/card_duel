# ai_deck_builder.gd — AI 临时卡组构建器（自定义卡组模式人机对战）
# 目标：AI 根据「自己角色 + 人类对手角色」动态组建 40 张合法卡组，
#       让 AI 发挥自身角色特点、并针对对手弱点组卡（防具/响应/控制针对性）。
# 设计：角色定位模板（战术/回复/装备骨架固定，攻击按定位配比）→ 针对对手调整防具/装备
#      → DeckData.validate_deck 校验兜底（非法回退默认卡组，防线上出错）。
# 进度（2026-08）：猎人、法师为精细模板；其余角色走通用定位模板，后续逐个精细化。
# 参照：docs/ai_custom_deck.md（适配方案）、docs/ai_playbooks.md（猎人道具流设计）。
extends RefCounted

const DeckData = preload("res://scripts/data/deck_data.gd")

# ---------- 角色定位（与 ai_player.gd 的 _BASE_ROLES 保持一致） ----------
const _CHAR_ROLE := {
	"fighter": "near", "berserker": "near", "assassin": "near", "paladin": "near",
	"sharpshooter": "range", "hunter": "range", "gunslinger": "range", "tracker": "range",
	"mage": "magic", "priest": "magic", "warlock": "magic", "miko": "magic",
	"spellblade": "near", "wardsmith": "near", "armor_feeder": "near",
}

# ---------- 对手主攻类型（读面板三属性 + 技能特判） ----------
# 返回 "near" / "range" / "magic"；AI 组卡据此选防具、调响应牌配比。
static func opp_main_attack_type(opp_char_id: String) -> String:
	var cd: Dictionary = Config.CHARACTER_DB.get(opp_char_id, {})
	# 技能特判：魔剑士靠近战武器引导输出；远程系角色面板可能被强化卡抬但底子是远程
	match opp_char_id:
		"spellblade": return "near"
		"sharpshooter", "hunter", "gunslinger", "tracker": return "range"
		"mage", "priest", "warlock", "miko": return "magic"
	var near := int(cd.get("near", 0))
	var rng := int(cd.get("range", 0))
	var mgc := int(cd.get("magic", 0))
	if mgc >= rng and mgc >= near: return "magic"
	if rng >= mgc and rng >= near: return "range"
	return "near"

# ---------- 主入口：AI 临时卡组（40 张 type_id，B 套餐） ----------
static func build_deck(ai_char_id: String, opp_char_id: String, _difficulty: int = 2) -> Array:
	var cards: Array = []
	match ai_char_id:
		"hunter": cards = _hunter_template(opp_char_id)
		"mage": cards = _mage_template(opp_char_id)
		_: cards = _generic_template(ai_char_id, opp_char_id)
	var v = DeckData.validate_deck(cards, "B")
	if not v.ok:
		push_warning("[AIDeckBuilder] %s 卡组校验失败，回退默认卡组：%s" % [ai_char_id, v.msg])
		return DeckData.default_deck()
	return cards

# ---------- AI 武器幻化池（针对角色定制；默认 = 每类型前 4 把） ----------
static func build_weapon_pool(ai_char_id: String, _opp_char_id: String) -> Dictionary:
	var pool := DeckData.default_weapon_pool()
	match ai_char_id:
		"hunter":
			# 猎人：远程池换入风神弓（穿心命中控对方位移→推进夹子区，与埋伏联动最强）。
			# 移除连弩（牵制+2 对猎人收益低——猎人牵制值 = 5-距离 已足够大）。
			var rng: Array = pool.get("range", [])
			if not rng.has("wind_god_bow"):
				rng.erase("repeater")
				rng.append("wind_god_bow")
			pool["range"] = rng
	return DeckData.normalize_weapon_pool(pool)

# ---------- 回复数值池（B 套餐固定：heal_5×1 + heal_3×2 + 三属性 buf 各 1） ----------
static func _sustain() -> Array:
	var out := ["heal_5", "heal_3", "heal_3"]
	out.append_array(["near_buf", "range_buf", "magic_buf"])
	return out

# ---------- 装备池（武器 3 按定位 + 防具 2 按对手主攻） ----------
static func _equipment(opp_char_id: String, weapon_main: String, weapon_extra: String) -> Array:
	var out: Array = []
	out.append(weapon_main); out.append(weapon_main); out.append(weapon_extra)
	var om = opp_main_attack_type(opp_char_id)
	var primary: String = {"near": "near_armor", "range": "range_armor", "magic": "magic_armor"}[om]
	var secondary: String = "magic_armor" if om == "near" else ("range_armor" if om == "magic" else "magic_armor")
	out.append(primary); out.append(secondary)
	return out

# ---------- 通用定位模板（13 角色；攻击 16 + 战术 13 + 回复 6 + 装备 5 = 40） ----------
# 注意：四池上限和 42 > 40（deck_data 设计强制跨池取舍），此处攻击 16 / 战术 13 不满上限
static func _generic_template(ai_char_id: String, opp_char_id: String) -> Array:
	var out: Array = []
	var role: String = _CHAR_ROLE.get(ai_char_id, "near")
	# 攻击池 16：定位主攻（6+强化2）+ 闪避 magic 4 + 格挡 near 3 + 副强化 1
	match role:
		"range":
			for i in range(6): out.append("range")
			for i in range(2): out.append("pierce")
			for i in range(4): out.append("magic")
			for i in range(3): out.append("near")
			out.append("chant")
		"magic":
			for i in range(6): out.append("magic")
			for i in range(2): out.append("chant")
			for i in range(4): out.append("range")
			for i in range(3): out.append("near")
			out.append("pierce")
		_:
			for i in range(6): out.append("near")
			for i in range(2): out.append("heavy")
			for i in range(4): out.append("magic")
			for i in range(3): out.append("range")
			out.append("pierce")
	# 战术池 13：move 4 + attract 2 + deter 2 + freeze 1 + destroy/seize/blessing/item 各 1
	for i in range(4): out.append("move")
	for i in range(2): out.append("attract")
	for i in range(2): out.append("deter")
	out.append("freeze")
	out.append("destroy"); out.append("seize"); out.append("blessing"); out.append("item")
	out.append_array(_sustain())
	var main_w := "near_weapon" if role == "near" else ("range_weapon" if role == "range" else "magic_weapon")
	var extra_w := "range_weapon" if role == "near" else ("magic_weapon" if role == "range" else "near_weapon")
	out.append_array(_equipment(opp_char_id, main_w, extra_w))
	return out

# ---------- 猎人精细模板（输出流：攻击 16 + 战术 13 + 回复 6 + 装备 5 = 40） ----------
# 设计修正（2026-08-23 实测）：原"道具流"（item×5）在实战中夹子对会避夹的对手几乎无伤，
# 且占用卡位导致输出不足 → 改为「远程输出为主、夹子控场为辅」。
# 攻击 16：range 6（主输出+牵制+埋伏素材）+ pierce 2（穿心/双夹）+ magic 3（闪避保命）
#         + near 3（格挡/贴脸）+ heavy 1（贴脸爆发）+ chant 1（无视距离魔法穿透，克远程防具）
# 战术 13：move 4（风筝保距）+ attract 2（拉进夹子区）+ deter 2 + freeze 1 + item 2（夹子辅助）
#         + destroy/seize 各 1
# 回复 6：B 套餐 + 三属性 buf 各 1；装备 5：range_weapon 3 + 防具 2 按对手
static func _hunter_template(opp_char_id: String) -> Array:
	var out: Array = []
	for i in range(6): out.append("range")
	for i in range(2): out.append("pierce")
	for i in range(3): out.append("magic")
	for i in range(3): out.append("near")
	out.append("heavy")
	out.append("chant")
	for i in range(4): out.append("move")
	for i in range(2): out.append("attract")
	for i in range(2): out.append("deter")
	out.append("freeze")
	# 战术分配：常规 = 夹子辅助（item 2）+ 摧毁/夺取各 1；
	# 对牧师（回复型）→ 打资源特化：夹子价值低（魔法无视距离、无需防贴脸），
	# 换成 摧毁/夺取各 2（打她的回复卡 = 血库+真言素材，双重收益）
	if opp_char_id == "priest":
		for i in range(2): out.append("destroy")
		for i in range(2): out.append("seize")
	else:
		for i in range(2): out.append("item")
		out.append("destroy"); out.append("seize")
	out.append_array(_sustain())
	out.append_array(_equipment(opp_char_id, "range_weapon", "range_weapon"))
	return out

# ---------- 法师精细模板（魔法爆发流；攻击 16 + 战术 13 + 回复 6 + 装备 5 = 40） ----------
# 攻击 16：magic 6 + chant 2（弃牌强化爆发核心）+ range 4（牵制）+ near 3（格挡）+ pierce 1
#         （去 heavy：法师近 2 的重击价值低，跨池省 1 张）
# 战术 13：move 4 + attract/deter 各 2 + freeze 1 + destroy/seize/blessing/item 各 1
# 回复 6：B 套餐（三属性 buf 各 1）；装备 5：magic_weapon 3 + 防具 2 按对手
static func _mage_template(opp_char_id: String) -> Array:
	var out: Array = []
	for i in range(6): out.append("magic")
	for i in range(2): out.append("chant")
	for i in range(4): out.append("range")
	for i in range(3): out.append("near")
	out.append("pierce")
	for i in range(4): out.append("move")
	for i in range(2): out.append("attract")
	for i in range(2): out.append("deter")
	out.append("freeze")
	out.append("destroy"); out.append("seize"); out.append("blessing"); out.append("item")
	out.append_array(_sustain())
	out.append_array(_equipment(opp_char_id, "magic_weapon", "magic_weapon"))
	return out

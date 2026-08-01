# ============================================================
# character_skills.gd — 角色技能钩子系统
# ============================================================
extends RefCounted

var _ms

func _init(ms):
	_ms = ms

func on_attack_hit(attacker_idx: int, _defender_idx: int, _damage: int, damage_type: int):
	var p = _ms.players[attacker_idx]
	match p.char_id:
		"swordsman": _swordsman_hit(attacker_idx, damage_type)

func on_taking_damage(defender_idx: int, _attacker_idx: int, base_damage: int) -> int:
	var p = _ms.players[defender_idx]
	match p.char_id:
		"paladin": return _paladin_reduce(defender_idx, base_damage)
		"berserker": _berserker_rage(defender_idx)
	return base_damage

func on_heal(player_idx: int, amount: int) -> int:
	var p = _ms.players[player_idx]
	var limit = _heal_limit(player_idx)
	if limit > 0:
		var healed = p.get("healed_this_turn", 0)
		var allowed = limit - healed
		if allowed <= 0: return 0
		amount = min(amount, allowed)
		p.healed_this_turn = healed + amount
	if p.char_id == "priest": amount += 2
	return amount

func _heal_limit(player_idx: int) -> int:
	match _ms.players[player_idx].char_id:
		_: return -1

# 判定阶段受到某类 DoT 伤害后调用：dot_types = 本回合造成伤害的 DoT 类型列表
# 牧师被动：清除自身对应类型的 DoT（受到一次伤害后即净化，不再持续）
func on_dot_damage(player_idx: int, dot_types: Array):
	if dot_types.is_empty(): return
	var p = _ms.players[player_idx]
	if p.char_id != "priest": return
	var cleared = false
	for i in range(p.dots.size() - 1, -1, -1):
		if p.dots[i].type in dot_types:
			p.dots.remove_at(i)
			cleared = true
	if cleared:
		_ms.add_log(player_idx, "牧师净化: 清除%s" % "、".join(dot_types))

func on_turn_start(player_idx: int):
	var p = _ms.players[player_idx]
	p.skill_used_this_turn = false
	p.free_move_used = false
	p.damage_bonus = {}
	p.healed_this_turn = 0
	p.damage_reduction_used = false
	p.pending_swordsman_skill = false
	p.skills_used = []
	p.used_function_card = false
	p.combo_attacks_this_turn = []
	match p.char_id:
		"warlock": p.ap_function = 2
		_: p.ap_function = 1
	p.ap_attack = 2
	p.ap_move = 1

func on_turn_end(player_idx: int):
	var p = _ms.players[player_idx]
	if p.char_id == "warlock" and not p.used_function_card:
		_ms.card_systems[player_idx].draw_cards(1)
		_ms.add_log(player_idx, "术士+1抽")

func can_attack_free(player_idx: int, card_type: String) -> bool:
	var p = _ms.players[player_idx]
	if p.char_id == "archer" and card_type == "range" and not p.skill_used_this_turn:
		return true
	return false

func set_damage_bonus(player_idx: int, types: Array, amount: int, label: String):
	var p = _ms.players[player_idx]
	p.damage_bonus = {"types": types, "amount": amount, "label": label}

func on_attack_cast(player_idx: int, type_id: String) -> int:
	var p = _ms.players[player_idx]
	var opp = 1 - player_idx
	var db = p.get("damage_bonus", {})
	if not db.is_empty() and _ms.char_skills.is_immune(opp, "skill_damage"):
		p.damage_bonus = {}
		return 0
	if db.is_empty(): return 0
	if type_id in db.types:
		p.damage_bonus = {}
		_ms.add_log(player_idx, "%s: +%d伤害" % [db.label, db.amount])
		return db.amount
	return 0

func on_opponent_turn_start(current_player_idx: int):
	var opp = 1 - current_player_idx
	match _ms.players[opp].char_id:
		_: pass

var _hand_conditions: Dictionary = {}

func _init_conditions():
	if not _hand_conditions.is_empty(): return
	_hand_conditions["has_attack"]   = func(idx): return _count_type(idx, Config.ATTACK_CARD_TYPES) > 0
	_hand_conditions["no_attack"]    = func(idx): return _count_type(idx, Config.ATTACK_CARD_TYPES) == 0
	_hand_conditions["hp_below_50"]  = func(idx): return _ms.players[idx].hp < _ms.players[idx].max_hp * 0.5
	_hand_conditions["hp_below_25"]  = func(idx): return _ms.players[idx].hp < _ms.players[idx].max_hp * 0.25

func check_hand_condition(player_idx: int, condition: String) -> bool:
	_init_conditions()
	var fn = _hand_conditions.get(condition, null)
	if fn: return fn.call(player_idx)
	return true

func _count_type(player_idx: int, types: Array) -> int:
	var n = 0
	for c in _ms.card_systems[player_idx].hand:
		if c.type_id in types: n += 1
	return n

func has_active_skills(player_idx: int) -> Array:
	var p = _ms.players[player_idx]
	var skills = []
	match p.char_id:
		"mage":
			if p.damage_bonus.is_empty(): skills.append("mage_discard")
		"assassin": skills.append("assassin_move")
	var result = []
	for sk in skills:
		if p.skills_used.has(sk): continue
		var limit = skill_game_limit(sk)
		if limit > 0:
			var used = p.skill_counts.get(sk, 0)
			if used >= limit: continue
		result.append(sk)
	return result

func skill_button_name(skill: String) -> String:
	match skill:
		"mage_discard": return "法术强化"
		"assassin_move": return "暗影步"
	return skill

func skill_game_limit(skill: String) -> int:
	match skill:
		_: return -1

func use_skill(player_idx: int, skill: String, params: Dictionary) -> Dictionary:
	var p = _ms.players[player_idx]
	var limit = skill_game_limit(skill)
	if limit > 0:
		var used = p.skill_counts.get(skill, 0)
		if used >= limit: return {success=false, msg="整局已达上限(%d次)" % limit}
		p.skill_counts[skill] = used + 1
	p.skills_used.append(skill)
	match skill:
		"mage_discard": return _mage_discard(player_idx, params)
		"assassin_move": return _assassin_move(player_idx, params)
	return {success=false, msg="未知技能"}

func hand_limit_bonus(player_idx: int) -> int:
	match _ms.players[player_idx].char_id:
		_: return 0

func move_distances(player_idx: int) -> Array:
	match _ms.players[player_idx].char_id:
		_: return [1]

func draw_count(player_idx: int) -> int:
	match _ms.players[player_idx].char_id:
		_: return 2

func can_upgrade_skill(player_idx: int) -> String:
	match _ms.players[player_idx].char_id:
		_: return ""

func upgrade_skill(player_idx: int, discarded_count: int) -> Dictionary:
	var p = _ms.players[player_idx]
	var key = str("up_", p.char_id)
	p.upgrades[key] = p.upgrades.get(key, 0) + discarded_count
	_ms.add_log(player_idx, "技能永久增强! (+%d级)" % discarded_count)
	return {success=true}

func is_immune(player_idx: int, _effect: String) -> bool:
	match _ms.players[player_idx].char_id:
		_: return false

func modify_stat(player_idx: int, stat: String, delta: int):
	var p = _ms.players[player_idx]
	match stat:
		"near": p.near_power = max(0, p.near_power + delta)
		"range": p.range_power = max(0, p.range_power + delta)
		"magic": p.magic_power = max(0, p.magic_power + delta)
	_ms.add_log(player_idx, "%s面板%+d" % [stat, delta])

func modify_max_hp(player_idx: int, delta: int):
	var p = _ms.players[player_idx]
	p.max_hp = max(1, p.max_hp + delta)
	p.hp = min(p.hp, p.max_hp)
	_ms.add_log(player_idx, "生命上限%+d" % delta)
	if delta > 0: p.hp = min(p.hp + delta, p.max_hp)

func can_equip(player_idx: int, _equip_type: String) -> String:
	match _ms.players[player_idx].char_id:
		_: return ""

# ---- 多段攻击预留钩子（快枪手用；新增"多段攻击"角色在此加分支） ----
# 攻击 AP 消耗覆盖：返回 -1 = 使用卡牌默认消耗
func get_attack_cost(player_idx: int, type_id: String) -> int:
	match _ms.players[player_idx].char_id:
		"gunslinger":
			if type_id in ["range", "pierce"]:
				return 2  # 远程/穿心固定消耗 2 攻击行动点
			return -1
		_: return -1

# 攻击段数：返回 1 = 单段（现有行为）；>1 = 多段攻击（每段独立 计算→响应→扣血→特效→死亡判定）
func get_attack_hit_count(player_idx: int, type_id: String) -> int:
	match _ms.players[player_idx].char_id:
		"gunslinger":
			if type_id in ["range", "pierce"]:
				return 2  # 远程/穿心两段伤害
			return 1
		_: return 1

# 攻击基础伤害公式覆盖：返回 -1 = 使用标准公式；>=0 = 用角色公式（后续武器/防具/Buff 修正照常）
# distance 为当前距离；多段攻击每段独立调用
func get_attack_base_damage(player_idx: int, type_id: String, distance: int) -> int:
	var p = _ms.players[player_idx]
	match p.char_id:
		"gunslinger":
			if type_id == "range":
				return max(0, floori((p.range_power - distance) / 2.0))
			elif type_id == "pierce":
				return max(0, floori((p.range_power + 3 - distance) / 2.0))
			return -1
		_: return -1

# ---- 角色道具类型（一张通用道具卡，角色决定放什么道具；默认陷阱） ----
# 道具类型需在 item_system._item_types 注册（堆叠/触发/拆除规则都在注册表）
func get_item_type(player_idx: int) -> String:
	match _ms.players[player_idx].char_id:
		# 示例（协作者）："hunter": return "snare"（捕兽夹，见 item_system 注册表）
		_: return "trap"

func _swordsman_hit(player_idx: int, damage_type: int):
	var p = _ms.players[player_idx]
	if damage_type == Config.DamageType.PHYSICAL and not p.skill_used_this_turn:
		p.pending_swordsman_skill = true

func _paladin_reduce(player_idx: int, base: int) -> int:
	var p = _ms.players[player_idx]
	if not p.damage_reduction_used:
		p.damage_reduction_used = true
		return max(0, base - 2)
	return base

func _berserker_rage(player_idx: int):
	_ms.status.add_buff(player_idx, "near_up", 1, 3)
	_ms.add_log(player_idx, "狂战士获得狂化(近战+1)")

func _mage_discard(player_idx: int, params: Dictionary) -> Dictionary:
	var uid = int(params.get("card_uid", -1))
	var cs = _ms.card_systems[player_idx]
	if not cs.has_card(uid): return {success=false, msg="没有此牌"}
	cs.discard_card(uid)
	set_damage_bonus(player_idx, ["magic", "chant"], 2, "法师强化")
	_ms.add_log(player_idx, "弃牌强化:下次魔法+2")
	return {success=true}

func _assassin_move(player_idx: int, params: Dictionary) -> Dictionary:
	var dir = params.get("direction", 0)
	if dir == 0: return {success=false, msg="请选择方向"}
	# 禁移动检查统一在 movement.move_player 兜底（霜咬同样限制暗影步）
	if not _ms.movement.move_player(player_idx, dir): return {success=false, msg="无法移动"}
	var td = _ms.item_system.trigger_on_step(player_idx)
	if td > 0:
		_ms._check_any_death()  # trigger_on_step 内部已扣血，这里只补死亡判定
	_ms.add_log(player_idx, "暗影步")
	return {success=true}

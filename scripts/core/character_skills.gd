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
		"fighter": _fighter_hit(attacker_idx, damage_type)
		"tracker":
			# 寻踪者：远程/法术攻击命中（伤害>0）叠 1 层校准，永久持续、无限叠加
			if damage_type == Config.DamageType.RANGED or damage_type == Config.DamageType.MAGICAL:
				_ms.status.add_buff(attacker_idx, "calibration", 1, -2)
				_ms.add_log(attacker_idx, "校准+1（远程伤害+%d）" % _calibration_stacks(attacker_idx))

# 攻击未造成伤害（护甲免疫/0伤害/闪避/格挡·牵制减到0）时调用：寻踪者清空校准
# 多段攻击每段独立判定：任何一段失败都会触发（清空幂等）
func on_attack_failed_no_damage(attacker_idx: int, damage_type: int):
	var p = _ms.players[attacker_idx]
	if p.char_id != "tracker": return
	if damage_type != Config.DamageType.RANGED and damage_type != Config.DamageType.MAGICAL: return
	if _calibration_stacks(attacker_idx) <= 0: return
	for i in range(p.buffs.size() - 1, -1, -1):
		if p.buffs[i].type == "calibration":
			p.buffs.remove_at(i)
	_ms.add_log(attacker_idx, "攻击未造成伤害，校准清空")

# 当前校准层数
func _calibration_stacks(player_idx: int) -> int:
	var n = 0
	for b in _ms.players[player_idx].buffs:
		if b.type == "calibration": n += 1
	return n

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
	if p.char_id == "warlock": amount = max(0, amount - 1)  # 邪术师被动「枯萎」：自身回血效果-1（+1→0）
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
	p.healed_this_turn = 0
	p.damage_reduction_used = false
	p.pending_fighter_skill = false
	p.skills_used = []
	p.used_function_card = false
	p.combo_attacks_this_turn = []
	match p.char_id:
		"warlock": p.ap_function = 2
		_: p.ap_function = 1
	# 攻击行动点应用 buff 修正（时滞 ap_attack_down 等）
	p.ap_attack = max(0, 2 + _ms.status.query_modifier(player_idx, "ap_attack"))
	p.ap_move = 1

func on_turn_end(player_idx: int):
	var p = _ms.players[player_idx]
	if p.char_id == "warlock" and not p.used_function_card:
		_ms.card_systems[player_idx].draw_cards(1)
		_ms.add_log(player_idx, "邪术师+1抽")

func can_attack_free(player_idx: int, card_type: String) -> bool:
	var p = _ms.players[player_idx]
	if p.char_id == "sharpshooter" and card_type == "range" and not p.skill_used_this_turn:
		return true
	return false

# 法师强化 buff 当前总加成（AI 决策/伤害预览用）
func mage_empower_value(player_idx: int) -> int:
	var p = _ms.players[player_idx]
	var total = 0
	for b in p.buffs:
		if b.type == "mage_empower": total += b.value
	return total

func on_attack_cast(player_idx: int, type_id: String) -> int:
	var p = _ms.players[player_idx]
	var opp = _ms._pending_target if _ms._pending_target >= 0 else 1 - player_idx
	# 释放魔法类型攻击（魔法/吟唱）→ 消耗全部法师强化层（buff 展示、可叠加）
	if type_id in ["magic", "chant"]:
		var total = mage_empower_value(player_idx)
		if total > 0:
			# 免疫检查：被免疫则只清除不加伤
			if _ms.char_skills.is_immune(opp, "skill_damage"):
				for i in range(p.buffs.size() - 1, -1, -1):
					if p.buffs[i].type == "mage_empower":
						p.buffs.remove_at(i)
				_ms.add_log(player_idx, "法师强化被免疫，层数清空")
				return 0
			for i in range(p.buffs.size() - 1, -1, -1):
				if p.buffs[i].type == "mage_empower":
					p.buffs.remove_at(i)
			_ms.add_log(player_idx, "魔法攻击消耗法师强化: +%d伤害" % total)
			return total
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
			# 法术强化：始终可用（每回合限一次由 skill_turn_limit 控制；效果可叠加，打出魔法攻击后清除）
			skills.append("mage_discard")
		"assassin": skills.append("assassin_move")
		"hunter":
			# 埋伏：手牌有远程攻击牌（range/pierce）时才显示
			if _has_range_attack(player_idx): skills.append("hunter_ambush")
		"wardsmith":
			# 护甲注魔：始终可用（整局限一次由 skill_game_limit 控制）
			skills.append("wardsmith_imbue")
			# 修复：装备护甲且耐久未满时可用
			if not p.armor.is_empty() and p.armor.durability < p.armor.get("max_durability", 3):
				skills.append("wardsmith_repair")
		"spellblade":
			# 魔力引导：装备近战武器时可用（回合不限次数由 skill_turn_limit=-1 控制）
			if not p.weapon.is_empty() and p.weapon.get("data", {}).get("type", "") == "near":
				skills.append("spellblade_channel")
	var result = []
	for sk in skills:
		# 每回合限次（数据表 skill_turn_limit，默认 1；-1 = 不限次数）
		var cd = Config.CHARACTER_DB[p.char_id]
		var turn_limit = int(cd.get("skill_turn_limit", 1))
		var turn_used = 0
		for sku in p.skills_used:
			if sku == sk: turn_used += 1
		if turn_limit >= 0 and turn_used >= turn_limit: continue
		# 整局限次（数据表 skill_game_limit，默认 -1 无限）
		var game_limit = int(cd.get("skill_game_limit", -1))
		if game_limit < 0 and sk == "wardsmith_imbue": game_limit = 1  # 铸甲师护甲注魔限整局一次（数据缺省兜底）
		if game_limit > 0:
			var used = p.skill_counts.get(sk, 0)
			if used >= game_limit: continue
		result.append(sk)
	return result

# 手牌是否含远程攻击牌（猎人埋伏按钮条件）
func _has_range_attack(player_idx: int) -> bool:
	for c in _ms.card_systems[player_idx].hand:
		if c.type_id in ["range", "pierce"]:
			return true
	return false

func skill_button_name(skill: String) -> String:
	match skill:
		"mage_discard": return "法术强化"
		"assassin_move": return "暗影步"
		"hunter_ambush": return "埋伏"
		"wardsmith_imbue": return "护甲注魔"
		"wardsmith_repair": return "修复"
		"spellblade_channel": return "魔力引导"
	return skill

func use_skill(player_idx: int, skill: String, params: Dictionary) -> Dictionary:
	var p = _ms.players[player_idx]
	# 技能必须属于该角色（下划线前缀为调试技能，放行）——防误调/调试卡 uid 冲突
	if not skill.begins_with("_") and not skill in has_active_skills(player_idx):
		return {success=false, msg="无此技能"}
	# 技能次数由角色数据表配置（协作者在 character_data.gd 直接调）：
	#   skill_turn_limit: 每回合限次（默认 1）；skill_game_limit: 整局限次（默认 -1 无限）
	var cd = Config.CHARACTER_DB[p.char_id]
	var game_limit = int(cd.get("skill_game_limit", -1))
	if game_limit < 0 and skill == "wardsmith_imbue": game_limit = 1  # 铸甲师护甲注魔限整局一次（数据缺省兜底）
	var used = 0
	if game_limit > 0:
		used = p.skill_counts.get(skill, 0)
		if used >= game_limit: return {success=false, msg="整局已达上限(%d次)" % game_limit}
	var turn_limit = int(cd.get("skill_turn_limit", 1))
	var turn_used = 0
	for sk in p.skills_used:
		if sk == skill: turn_used += 1
	if turn_limit >= 0 and turn_used >= turn_limit:
		return {success=false, msg="本回合已达次数上限"}
	# 先执行技能，成功后才记账（skills_used/skill_counts）。
	# 否则技能内部失败（如暗影步贴脸推人被拒）也会消耗回合次数/整局限次。
	p.skills_used.append(skill)
	if game_limit > 0: p.skill_counts[skill] = used + 1
	var skill_result: Dictionary
	match skill:
		"mage_discard": skill_result = _mage_discard(player_idx, params)
		"assassin_move": skill_result = _assassin_move(player_idx, params)
		"hunter_ambush": skill_result = _hunter_ambush(player_idx, params)
		"wardsmith_imbue": skill_result = _wardsmith_imbue(player_idx, params)
		"wardsmith_repair": skill_result = _wardsmith_repair(player_idx, params)
		"spellblade_channel": skill_result = _spellblade_channel(player_idx, params)
		_: skill_result = {success=false, msg="未知技能"}
	if not skill_result.get("success", false):
		p.skills_used.pop_back()
		if game_limit > 0: p.skill_counts[skill] = used
	return skill_result

# 护甲注魔（铸甲师，限整局一次）：直接选择一种护甲装备（不消耗卡牌）
func _wardsmith_imbue(player_idx: int, params: Dictionary) -> Dictionary:
	var armor_id = str(params.get("armor_type", ""))
	if not armor_id in ["near_armor", "range_armor", "magic_armor"]:
		return {success=false, msg="请选择护甲类型"}
	_ms.equipment.equip_armor(player_idx, armor_id)
	_ms.add_log(player_idx, "护甲注魔: 装备%s" % Config.ARMOR_DB[armor_id].name)
	return {success=true}

# 修复（铸甲师）：装备破损护甲时，消耗2攻击点 + 弃一张与装备护甲匹配的强化攻击卡，修复1点耐久
# 重击→近战防具、穿心→远程防具、吟唱→法术防具（一一对应 ARMOR_DB 类型）
func _wardsmith_repair(player_idx: int, params: Dictionary) -> Dictionary:
	var p = _ms.players[player_idx]
	if p.armor.is_empty():
		return {success=false, msg="未装备护甲"}
	var max_dur = p.armor.get("max_durability", 3)
	if p.armor.durability >= max_dur:
		return {success=false, msg="护甲未破损"}
	if p.ap_attack < 2:
		return {success=false, msg="攻击行动点不足"}
	var uid = int(params.get("card_uid", -1))
	var cs = _ms.card_systems[player_idx]
	var card = {}
	for c in cs.hand:
		if c.uid == uid: card = c; break
	if card.is_empty() or not card.type_id in ["heavy", "pierce", "chant"]:
		return {success=false, msg="请选择重击/穿心/吟唱"}
	# 卡类型必须匹配已装备护甲类型
	var expect_armor = {"heavy": "near_armor", "pierce": "range_armor", "chant": "magic_armor"}[card.type_id]
	if p.armor.id != expect_armor:
		return {success=false, msg="卡牌类型与装备护甲不匹配"}
	cs.play_card(uid)  # 丢弃进弃牌堆
	p.armor.durability = min(max_dur, p.armor.durability + 1)
	p.ap_attack -= 2
	_ms.add_log(player_idx, "修复: %s耐久+1(%d/%d)" % [p.armor.data.name, p.armor.durability, max_dur])
	return {success=true}

# 魔力引导（魔剑士）：装备近战武器时，弃「魔法」卡视作打出「近战」、弃「吟唱」卡视作打出「重击」（均无视距离，可被格挡）
func _spellblade_channel(player_idx: int, params: Dictionary) -> Dictionary:
	var p = _ms.players[player_idx]
	# 必须装备近战武器
	if p.weapon.is_empty() or p.weapon.get("data", {}).get("type", "") != "near":
		return {success=false, msg="需要装备近战武器"}
	var uid = int(params.get("card_uid", -1))
	var cs = _ms.card_systems[player_idx]
	var card = {}
	for c in cs.hand:
		if c.uid == uid: card = c; break
	if card.is_empty() or not card.type_id in ["magic", "chant"]:
		return {success=false, msg="请选择魔法/吟唱卡"}
	var as_type = "near" if card.type_id == "magic" else "heavy"
	# 复用出牌流程：以 near/heavy 打出（对应攻击点消耗），ignore_distance 绕过贴脸限制
	return _ms._do_play_card(player_idx, {"card_uid": uid, "extra": {"as_type": as_type, "ignore_distance": true}})

# 被动：装备护甲耐久上限 +1（铸甲师 max_durability=4；由 equip_armor 调用）
func armor_durability_bonus(player_idx: int) -> int:
	if _ms.players[player_idx].char_id == "wardsmith": return 1
	return 0

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
		"hunter": return "snare"  # 猎人 → 捕兽夹
		"miko": return "torii"    # 巫女 → 鸟居
		_: return "trap"

func _fighter_hit(player_idx: int, damage_type: int):
	var p = _ms.players[player_idx]
	if damage_type == Config.DamageType.PHYSICAL and not p.skill_used_this_turn:
		p.pending_fighter_skill = true

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
	# 法师强化 buff：每层+2、无限叠加、永久持续（打出魔法类型攻击后由 on_attack_cast 清除）
	_ms.status.add_buff(player_idx, "mage_empower", 2, -2)
	_ms.add_log(player_idx, "弃牌强化: 魔法强化+2(当前+%d)" % mage_empower_value(player_idx))
	return {success=true}

func _assassin_move(player_idx: int, params: Dictionary) -> Dictionary:
	var dir: Vector2i = _ms.movement.geometry.from_dict(params.get("direction", {}))
	if dir == Vector2i.ZERO: return {success=false, msg="请选择方向"}
	# 暗影步不允许推人（免费位移不附带推人收益）：贴脸朝任一存活对手方向使用 → 明确提示
	if _ms.movement._opponent_in_dir(player_idx, dir) >= 0:
		return {success=false, msg="暗影步不能推人"}
	# 禁移动检查统一在 movement.move_player 兜底（霜咬同样限制暗影步）
	if not _ms.movement.move_player(player_idx, dir, false): return {success=false, msg="无法移动"}
	# 突刺武器：暗影步位移到贴脸同样触发额外+3（与移动卡一致）
	if _ms.movement.get_distance() == 0:
		_ms._moved_to_adjacent_this_turn = true
	_ms.item_system.trigger_on_step(player_idx)  # 死亡判定由 _damage_player 统一处理
	_ms.add_log(player_idx, "暗影步")
	return {success=true}

# 猎人埋伏：把一张远程攻击牌转为捕兽夹道具放置（不触发攻击）
func _hunter_ambush(player_idx: int, params: Dictionary) -> Dictionary:
	var uid = int(params.get("card_uid", -1))
	var cs = _ms.card_systems[player_idx]
	# 校验选中的卡在手牌且是远程攻击牌
	var card = {}
	for c in cs.hand:
		if c.uid == uid: card = c; break
	if card.is_empty() or not card.type_id in ["range", "pierce"]:
		return {success=false, msg="请选择远程攻击牌"}
	# 埋伏不消耗攻击行动点（平衡调整 2026-08：猎人道具流加强）；次数限制由 use_skill 的 turn_limit 兜底（每回合 1 次）
	var geo = _ms.movement.geometry
	var positions: Array = []
	positions.append(geo.from_dict(params.get("pos", params.get("trap_pos", {}))))
	if card.type_id == "pierce":
		positions.append(geo.from_dict(params.get("pos2", {})))
	for pos in positions:
		if not geo.is_valid(pos):
			return {success=false, msg="请选择放置位置"}
	# 预校验：目标格不能有单位（捕兽夹可无限堆叠，放置校验只受单位占用影响）
	for pos in positions:
		if pos == _ms.players[0].position or pos == _ms.players[1].position:
			return {success=false, msg="无法放置"}
	for pos in positions:
		_ms.item_system.place_item(player_idx, "snare", pos)
	cs.play_card(uid)  # 卡进弃牌堆，不触发攻击/响应
	var pos_str = geo.to_text(positions[0])
	for i in range(1, positions.size()):
		pos_str += "、" + geo.to_text(positions[i])
	_ms.add_log(player_idx, "埋伏: 捕兽夹于%s" % pos_str)
	return {success=true}

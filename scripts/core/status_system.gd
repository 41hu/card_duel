# status_system.gd — 状态系统（Buff、DoT、冻结、被动技能标记）
extends RefCounted

var match_ref

func _init(match):
	match_ref = match

# 添加Buff {type, value, duration} duration=-1表示回合结束清除
func add_buff(player_idx: int, buff_type: String, value: int, duration: int):
	var player = match_ref.get_player(player_idx)
	player.buffs.append({type=buff_type, value=value, duration=duration})

# 添加灼烧：持续2回合，每回合-2HP，再次命中刷新持续时间为2回合（不叠加层数）
func add_burn(player_idx: int):
	if match_ref.char_skills.is_immune(player_idx, "dot_burn"): return
	var player = match_ref.get_player(player_idx)
	for dot in player.dots:
		if dot.type == "burn":
			dot.duration = 2  # 刷新持续时间
			return
	player.dots.append({type="burn", damage=2, duration=2})

# 添加中毒：每回合-1HP，再次命中+2层，层数每回合-1，可无限叠加
func add_poison(player_idx: int, stacks: int = 2):
	if match_ref.char_skills.is_immune(player_idx, "dot_poison"): return
	var player = match_ref.get_player(player_idx)
	for dot in player.dots:
		if dot.type == "poison":
			dot.duration += stacks  # 叠加层数
			return
	player.dots.append({type="poison", damage=1, duration=stacks})

# 冻结玩家
func freeze_player(player_idx: int) -> bool:
	var player = match_ref.get_player(player_idx)
	# 不能连续冻结
	if match_ref.char_skills.is_immune(player_idx, "freeze"): return false
	if player.frozen_lockout:
		return false
	player.frozen = true
	player.frozen_lockout = true
	return true

# 清除冻结
func clear_freeze(player_idx: int):
	var player = match_ref.get_player(player_idx)
	player.frozen = false
	player.frozen_lockout = true  # 本回合不能被再次冻结

# 回合开始处理
func on_turn_start(player_idx: int):
	pass  # 冻结锁在 char_skills.on_turn_start 中重置（仅正常回合）

# 回合结束处理
func on_turn_end(player_idx: int):
	var player = match_ref.get_player(player_idx)

	# 处理有限持续时间的buff
	for i in range(player.buffs.size() - 1, -1, -1):
		if player.buffs[i].duration > 0:
			player.buffs[i].duration -= 1
			if player.buffs[i].duration <= 0:
				player.buffs.remove_at(i)

	# 清理回合性buff（duration=-1，每回合结束时清除）
	for i in range(player.buffs.size() - 1, -1, -1):
		if player.buffs[i].duration == -1:
			player.buffs.remove_at(i)

	# 清除冻结移动限制
	player.frozen_move = false

	# 重置圣骑士被动
	player.damage_reduction_used = false

	# 清除技能使用标记
	player.skill_used_this_turn = false

# 获取攻击力修正（damage_type: Config.DamageType，用于区分近战限定加成）
func get_attack_modifier(player_idx: int, damage_type: int) -> int:
	var player = match_ref.get_player(player_idx)
	var mod = 0
	for buff in player.buffs:
		if buff.type == "attack_up":
			mod += buff.value
		elif buff.type == "attack_down":
			mod += buff.value  # value为负
		elif buff.type == "near_up" and damage_type == Config.DamageType.PHYSICAL:
			mod += buff.value  # 狂战士：仅近战类伤害（近战/重击）生效
	return mod

# 获取移动修正（霜咬效果等）
func get_move_modifier(player_idx: int) -> int:
	var player = match_ref.get_player(player_idx)
	if player.frozen_move:
		return -999  # 位移=0
	return 0

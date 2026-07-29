# character_skills.gd — 角色技能钩子系统
# 加新角色只需：1) config.gd 加角色数据  2) 本文件加 skill_xxx 方法
extends RefCounted

var _ms

func _init(ms):
	_ms = ms

# ---------- 钩子入口 ----------
func on_attack_hit(attacker_idx: int, defender_idx: int, damage: int, damage_type: int):
	var p = _ms.players[attacker_idx]
	match p.char_id:
		"swordsman": _swordsman_hit(attacker_idx, damage_type)

func on_taking_damage(defender_idx: int, attacker_idx: int, base_damage: int) -> int:
	var p = _ms.players[defender_idx]
	match p.char_id:
		"paladin": return _paladin_reduce(defender_idx, base_damage)
		"berserker": _berserker_rage(defender_idx)
	return base_damage

func on_heal(player_idx: int, amount: int) -> int:
	var p = _ms.players[player_idx]
	if p.char_id == "priest": return amount + 2
	return amount

func on_turn_start(player_idx: int):
	var p = _ms.players[player_idx]
	p.skill_used_this_turn = false
	p.free_move_used = false
	p.mage_buffed = false
	p.damage_reduction_used = false
	p.combo_attacks_this_turn = []
	match p.char_id:
		"warlock": p.ap_function = 2
		_: p.ap_function = 1
	p.ap_attack = 2
	p.ap_move = 1

func on_turn_end(player_idx: int):
	var p = _ms.players[player_idx]
	if p.char_id == "warlock" and p.ap_function >= 1:
		_ms.card_systems[player_idx].draw_cards(1)
		_ms.add_log(player_idx, "术士+1抽")

func can_attack_free(player_idx: int, card_type: String) -> bool:
	var p = _ms.players[player_idx]
	if p.char_id == "archer" and card_type == "range" and not p.skill_used_this_turn:
		return true
	return false

func on_attack_cast(player_idx: int, type_id: String) -> int:
	var p = _ms.players[player_idx]
	var bonus = 0
	if type_id in ["magic", "chant"] and p.mage_buffed:
		bonus = 2
		p.mage_buffed = false
		_ms.add_log(player_idx, "法师强化: +2")
	return bonus

func has_active_skill(player_idx: int) -> String:
	var p = _ms.players[player_idx]
	if p.skill_used_this_turn: return ""
	match p.char_id:
		"mage": return "mage_discard" if not p.mage_buffed else ""
		"assassin": return "assassin_move"
	return ""

func use_skill(player_idx: int, skill: String, params: Dictionary) -> Dictionary:
	var p = _ms.players[player_idx]
	if p.skill_used_this_turn: return {success=false, msg="本回合已使用过"}
	p.skill_used_this_turn = true
	match skill:
		"mage_discard": return _mage_discard(player_idx)
		"assassin_move": return _assassin_move(player_idx, params)
	return {success=false, msg="未知技能"}

func armor_durability_bonus(player_idx: int) -> int:
	if _ms.players[player_idx].char_id == "paladin": return 1
	return 0

# ---------- 各角色技能实现 ----------
func _swordsman_hit(player_idx: int, damage_type: int):
	var p = _ms.players[player_idx]
	if damage_type == Config.DamageType.PHYSICAL:
		p.hp = min(p.max_hp, p.hp + 2)
		_ms.add_log(player_idx, "剑士+2HP")

func _paladin_reduce(player_idx: int, base: int) -> int:
	var p = _ms.players[player_idx]
	if not p.damage_reduction_used:
		p.damage_reduction_used = true
		return max(0, base - 2)
	return base

func _berserker_rage(player_idx: int):
	_ms.status.add_buff(player_idx, "attack_up", 1, 2)
	_ms.add_log(player_idx, "狂战士+1近战")

func _mage_discard(player_idx: int) -> Dictionary:
	var cs = _ms.card_systems[player_idx]
	if cs.hand.is_empty(): return {success=false, msg="没有可弃的牌"}
	cs.random_discard(1)
	_ms.players[player_idx].mage_buffed = true
	_ms.add_log(player_idx, "弃牌强化:下次魔法+2")
	return {success=true}

func _assassin_move(player_idx: int, params: Dictionary) -> Dictionary:
	var dir = params.get("direction", 0)
	if dir == 0: return {success=false, msg="请选择方向"}
	if not _ms.movement.move_player(player_idx, dir): return {success=false, msg="无法移动"}
	var td = _ms.movement.check_trap_trigger(player_idx)
	if td > 0: _ms.players[player_idx].hp -= td
	_ms.add_log(player_idx, "暗影步")
	return {success=true}

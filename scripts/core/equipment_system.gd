# equipment_system.gd — 装备系统（武器幻化、装备/丢弃、防具管理）
extends RefCounted

var match_ref

func _init(match):
	match_ref = match

# 场上所有玩家正在装备的武器 id 集合（武器全局独占：
# 某武器被任一玩家装备时，其他玩家无法再幻化到同一把）
func _equipped_weapon_ids() -> Dictionary:
	var ids := {}
	for p in match_ref.players:
		if not p.weapon.is_empty():
			ids[p.weapon.id] = true
	return ids

# 幻化武器卡：从该玩家的自定义武器池中随机（排除场上已装备的武器）。
# 弃置/摧毁/换装后的武器不在场上 → 自然回到可选池。
func process_weapon_card(player_idx: int, weapon_type: String) -> Dictionary:
	var equipped = _equipped_weapon_ids()
	var pool: Array = []
	var pools: Array = match_ref.weapon_pools
	if player_idx < pools.size() and pools[player_idx] is Dictionary:
		for wid in pools[player_idx].get(weapon_type, []):
			if not equipped.has(str(wid)):
				pool.append(str(wid))
	if pool.is_empty():
		return {phase="done", msg="该类武器均已被场上玩家装备"}
	var wid = pool[randi() % pool.size()]
	return {phase="choose", weapon={"id": wid, "data": Config.WEAPON_DB[wid]}}

func equip_weapon(player_idx: int, weapon_id: String):
	var player = match_ref.get_player(player_idx)
	var reject = match_ref.char_skills.can_equip(player_idx, "weapon")
	if reject != "": return
	# 旧武器离场：场上独占集合自动释放（无需额外回池操作）
	player.weapon = {id=weapon_id, data=Config.WEAPON_DB[weapon_id]}
	# 对战统计：记录装备过的武器（去重集合，武器专家称号判定）
	match_ref.stats[player_idx]["weapons_used"][weapon_id] = true

func discard_weapon_offer(_weapon_id: String):
	pass  # 放弃幻化：武器未装备、未入独占集合，无需处理（回池语义由场上集合天然实现）

func equip_armor(player_idx: int, armor_type_id: String) -> Dictionary:
	var reject = match_ref.char_skills.can_equip(player_idx, "armor")
	if reject != "": return {success=false, msg=reject}
	var player = match_ref.get_player(player_idx)
	# 耐久上限：基础 3 + 角色被动加成（铸甲师 +1 → 4）
	var dur = 3 + match_ref.char_skills.armor_durability_bonus(player_idx)
	# 旧防具直接消失（防具卡打出时已进弃牌堆；若把 {id,data} 结构塞进弃牌堆会污染牌堆）
	player.armor = {id=armor_type_id, data=Config.ARMOR_DB[armor_type_id], durability=dur, max_durability=dur}
	return {success=true, msg="装备了" + Config.ARMOR_DB[armor_type_id].name}

func swap_armor(player_idx: int, armor_type_id: String) -> Dictionary:
	return equip_armor(player_idx, armor_type_id)

func destroy_equipment(player_idx: int, equip_type: String) -> String:
	var player = match_ref.get_player(player_idx)
	match equip_type:
		"weapon":
			if player.weapon.is_empty(): return "对方没有武器"
			var old = player.weapon
			player.weapon = {}  # 摧毁后离场 → 自动回到可选池
			return "摧毁了" + old.data.name + "(已回池)"
		"armor":
			if player.armor.is_empty(): return "对方没有防具"
			var old = player.armor
			player.armor = {}
			return "摧毁了" + old.data.name
	return "无效选择"

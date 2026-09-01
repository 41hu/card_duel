# ============================================================
# item_system.gd — 道具系统（地格放置型道具）
# 道具 = 可放置在地格上、被踩后触发效果的游戏元素；陷阱是默认道具。
# 设计原则（注册表模式）：
#   新增道具类型只需在 _item_types 注册一条配置，放置/触发/堆叠规则自动生效；
#   特殊互动（如某卡对某类道具的特殊规则）通过类型字段声明，不在消费点散落分支。
# ============================================================
extends RefCounted

var match_ref

# 道具类型注册表
# name:         道具名（卡面/日志显示）；desc: 效果描述（点击卡牌说明区显示）
# damage:       踩上触发的固定伤害；on_step: 自定义触发回调（func(player_idx, item) -> int，有则优先于 damage）
# stack:        堆叠规则 —— "unlimited" 无限叠加 | "single" 同格同类仅1个 | "max:N" 同格同类上限N
# destroy_rule: 摧毁卡对它的拆除规则 —— "one" 一次拆1个（默认）| "all" 一张清掉该格全部同类道具
var _item_types: Dictionary = {
	"trap": {
		"name": "陷阱",
		"desc": "踩上-3HP，同格仅放1个",
		"damage": 3,
		"stack": "single",
		"destroy_rule": "one",
	},
	"snare": {
		"name": "捕兽夹",
		"desc": "踩上-4HP，可重叠放置（猎人埋伏）；一张摧毁清掉同格全部",
		"damage": 4,
		"stack": "unlimited",
		"destroy_rule": "all",
	},
	"torii": {
		"name": "鸟居",
		"desc": "巫女专属：自己踩上+2HP并全属性+1（永久）；敌人踩上进入神隐（跳过下回合）；可被摧毁卡拆除",
		"stack": "single",
		"destroy_rule": "one",
		"on_step": _torii_step,
	},
	"vine_seed": {
		"name": "蔓生种子",
		"desc": "蔓生树妖专属：踩到的单位获得1层「致残」（永久可叠加）；带致残的单位每次位移受2点真实伤害并消去1层；持续存在不因踩踏消失；只能被近战/重击除根或摧毁卡拆除（限所在格/相邻格）",
		"stack": "single",
		"destroy_rule": "one",
		"on_step": _vine_seed_step,
	},
}

# 蔓生种子：单位到达获得 1 层致残（永久可叠加）；树妖自身无视（不获得）
# 签名与 on_step 统一（player_idx, it）——trigger_on_step 固定传 2 参
func _vine_seed_step(player_idx: int, _it: Dictionary = {}):
	var player = match_ref.get_player(player_idx)
	if player.char_id == "vine_ent": return  # 树妖免疫自己的种子
	var found = false
	for b in player.buffs:
		if b.type == "vine_cripple":
			b.value += 1
			found = true
			break
	if not found:
		player.buffs.append({type="vine_cripple", value=1, duration=-2})
	match_ref.add_log(player_idx, "蔓: 获得1层致残（位移时受2点真伤）")

# 鸟居触发：自己踩（放置者=巫女）回血2+全属性+1 永久；敌人踩进入神隐（跳过下回合）
func _torii_step(player_idx: int, item: Dictionary) -> int:
	if item.owner == player_idx:
		var p = match_ref.players[player_idx]
		var before = p.hp
		p.hp = min(p.max_hp, p.hp + 2)
		p.near_power += 1
		p.range_power += 1
		p.magic_power += 1
		match_ref.stats[player_idx]["heal_total"] += p.hp - before
		match_ref.add_log(player_idx, "鸟居: +2HP 全属性+1")
		return 0
	match_ref.status.add_buff(player_idx, "神隐", 0, -2)
	match_ref.add_log(player_idx, "踩上鸟居，进入神隐（下回合被跳过）")
	return 0

func _init(match):
	match_ref = match

# 道具类型配置查询（未知类型返回空字典，消费点自行兜底）
func get_item_type(item_type: String) -> Dictionary:
	return _item_types.get(item_type, {})

# 道具类型按结算优先级的展示顺序（伤害类在前、收益类在后 = 注册表定义顺序）：
# 地格道具悬浮框按此顺序排列（如"陷阱:1|捕兽夹:2|鸟居:1"）
func get_type_order() -> Array:
	return _item_types.keys()

# 场上所有道具（引用 match_state.items，避免拷贝）
func get_items() -> Array:
	return match_ref.items

# 指定格子的道具
func get_items_at(pos: Vector2i) -> Array:
	var out = []
	for it in match_ref.items:
		if it.position == pos:
			out.append(it)
	return out

# ---- 放置 ----
# 规则：目标格不能有单位；按道具类型的堆叠规则校验
func place_item(player_idx: int, item_type: String, pos: Vector2i) -> bool:
	var geo = match_ref.movement.geometry
	if not geo.is_valid(pos):
		return false
	var p0 = match_ref.get_player(0)
	var p1 = match_ref.get_player(1)
	if pos == p0.position or pos == p1.position:
		return false
	var t = get_item_type(item_type)
	if t.is_empty():
		return false
	var same_count = 0
	for it in match_ref.items:
		if it.position == pos and it.item_type == item_type:
			same_count += 1
	var stack = str(t.get("stack", "unlimited"))
	match stack:
		"single":
			if same_count >= 1: return false
		_:
			if stack.begins_with("max:") and same_count >= int(stack.trim_prefix("max:")):
				return false
	match_ref.items.append({item_type=item_type, position=pos, owner=player_idx})
	return true

# ---- 踩上触发 ----
# 返回本次触发总伤害；道具伤害属于无来源伤害（只计入受到伤害，不计入造成伤害）
# 结算顺序：先伤害类（陷阱/捕兽夹等固定 damage），后收益类（鸟居 on_step 回血/神隐）——
# 同格混放时先扣血再回血，避免"先回血再扣血"的收益倒挂
func trigger_on_step(player_idx: int) -> int:
	var player = match_ref.get_player(player_idx)
	var total = 0
	var names = []
	# 第一遍：伤害类道具（无 on_step 的固定 damage 道具），统一累计后扣血
	for i in range(match_ref.items.size() - 1, -1, -1):
		var it = match_ref.items[i]
		if it.position != player.position:
			continue
		var t = get_item_type(it.item_type)
		if t.has("on_step") and t.get("on_step") != null:
			continue  # 收益类（鸟居）第二遍处理
		# 猎人无视捕兽夹（平衡调整）：踩上不受伤、夹子保留在原格
		if it.item_type == "snare" and player.char_id == "hunter":
			continue
		var dmg = int(t.get("damage", 0))
		if dmg > 0:
			total += dmg
			names.append(str(t.get("name", it.item_type)))
		match_ref.items.remove_at(i)  # 触发即消耗（一次性道具）
	if total > 0:
		match_ref.add_log(player_idx, "踩%s-%dHP" % ["/".join(names), total])
		match_ref._damage_player(player_idx, total)  # 统一伤害入口（内部含死亡判定）
		match_ref.stats[player_idx]["damage_taken"] += total
		match_ref.stats[player_idx]["damage_from_trap"] += total
	# 第二遍：收益/特殊类道具（on_step 回调：鸟居回血/神隐等）——扣血后再结算
	# 只移除带 on_step 的道具：猎人免疫的捕兽夹（无 on_step）在第一遍被跳过，须保留在原格
	for i in range(match_ref.items.size() - 1, -1, -1):
		var it = match_ref.items[i]
		if it.position != player.position:
			continue
		var t = get_item_type(it.item_type)
		if t.has("on_step") and t.get("on_step") != null:
			t["on_step"].call(player_idx, it)
			# 蔓生种子持续存在（多次触发致残），其余 on_step 道具（鸟居等）触发即消耗
			if it.item_type != "vine_seed":
				match_ref.items.remove_at(i)
	return total

# ---- 摧毁 ----
# 指定格子摧毁：同格所有可摧毁道具类型**同时**各执行一次自己的 destroy_rule：
#   "one"（默认）：该类型拆除一层（后放的先拆）
#   "all"：该类型同格全部拆除（如捕兽夹堆叠）
#   "none"：该类型免疫摧毁（跳过，不影响同格其他类型）
# 例：捕兽夹(可堆叠, all) + 逐层道具(one) 同格 → 一次摧毁：夹子全清 + 逐层道具拆一层
func destroy_item_at(pos: Vector2i) -> bool:
	var removed = false
	var types_seen := {}
	# while 循环：每次迭代后重新读数组长度（循环中 remove_at 会缩短数组，
	# 若用 for i in range(size) 上限固定，删除后索引越界）
	var i = match_ref.items.size() - 1
	while i >= 0:
		if i >= match_ref.items.size():
			# all 分支删除了多个元素（含当前 i 处），索引前移：重新对齐到最后一项
			i = match_ref.items.size() - 1
			if i < 0:
				break
		var it = match_ref.items[i]
		if it.position == pos and not types_seen.has(it.item_type):
			types_seen[it.item_type] = true  # 同类已按规则处理过（all 已全清 / one 只拆一层）
			var t = get_item_type(it.item_type)
			match str(t.get("destroy_rule", "one")):
				"none":
					pass  # 免疫类型：跳过，同格其他类型照常拆
				"all":
					var j = match_ref.items.size() - 1
					while j >= 0:
						if match_ref.items[j].position == pos and match_ref.items[j].item_type == it.item_type:
							match_ref.items.remove_at(j)
							removed = true
						j -= 1
				_:
					match_ref.items.remove_at(i)
					removed = true
		i -= 1
	return removed

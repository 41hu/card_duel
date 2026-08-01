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
		"desc": "踩上-3HP，可重叠放置",
		"damage": 3,
		"stack": "unlimited",
		"destroy_rule": "one",
	},
}

func _init(match):
	match_ref = match

# 道具类型配置查询（未知类型返回空字典，消费点自行兜底）
func get_item_type(item_type: String) -> Dictionary:
	return _item_types.get(item_type, {})

# 场上所有道具（引用 match_state.items，避免拷贝）
func get_items() -> Array:
	return match_ref.items

# 指定格子的道具
func get_items_at(pos: int) -> Array:
	var out = []
	for it in match_ref.items:
		if it.position == pos:
			out.append(it)
	return out

# ---- 放置 ----
# 规则：目标格不能有单位；按道具类型的堆叠规则校验
func place_item(player_idx: int, item_type: String, pos: int) -> bool:
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
func trigger_on_step(player_idx: int) -> int:
	var player = match_ref.get_player(player_idx)
	var total = 0
	var names = []
	for i in range(match_ref.items.size() - 1, -1, -1):
		var it = match_ref.items[i]
		if it.position != player.position:
			continue
		var t = get_item_type(it.item_type)
		var dmg = 0
		# 自定义触发优先（on_step handler），否则用固定 damage（开闭原则）
		if t.has("on_step") and t.get("on_step") != null:
			dmg = int(t["on_step"].call(player_idx, it))
		else:
			dmg = int(t.get("damage", 0))
		if dmg > 0:
			total += dmg
			names.append(str(t.get("name", it.item_type)))
		match_ref.items.remove_at(i)  # 触发即消耗（一次性道具）
	if total > 0:
		player.hp -= total
		match_ref.stats[player_idx]["damage_taken"] += total
		match_ref.stats[player_idx]["damage_from_trap"] += total
		match_ref.add_log(player_idx, "踩%s-%dHP" % ["/".join(names), total])
	return total

# ---- 摧毁 ----
# 指定格子摧毁：按目标道具类型的 destroy_rule 执行
#   "one"（默认）：拆除该格一个道具（后放的先拆）
#   "all"：一张摧毁清掉该格全部同类道具（由道具类型自行声明，未来角色可设计逐层拆的反制）
func destroy_item_at(pos: int) -> bool:
	for i in range(match_ref.items.size() - 1, -1, -1):
		var it = match_ref.items[i]
		if it.position != pos:
			continue
		if str(get_item_type(it.item_type).get("destroy_rule", "one")) == "all":
			var removed = false
			for j in range(match_ref.items.size() - 1, -1, -1):
				if match_ref.items[j].position == pos and match_ref.items[j].item_type == it.item_type:
					match_ref.items.remove_at(j)
					removed = true
			return removed
		match_ref.items.remove_at(i)
		return true
	return false

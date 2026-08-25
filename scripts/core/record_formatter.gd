# record_formatter.gd — 对局记录 v2 格式化（AI 复盘友好）
# 目标：让 AI（分析者）能精准还原"这局发生了什么、AI 为什么这么做"。
# 相比 v1（快照+文本日志分离）：
#   · 按回合组织成行动流水，每条行动自带执行时上下文（距离/HP/位置/AP/手牌内容）
#   · AI 决策轨迹行（[AI决策] 选了什么、几分、攻击牌候选对比、为什么跳过）
#   · 头部 meta：模式/难度/先手/双方卡组构成
# 输入：result（game_result：battle_record/action_log/names/stats/winner/titles）+ meta
extends RefCounted

const DIFF_NAMES = ["简单", "普通", "困难", "地狱"]

# 生成 v2 文本日志
static func format(result: Dictionary, meta: Dictionary = {}) -> String:
	var lines: Array = []
	lines.append("=== 卡牌对决 对局记录 v2 ===")
	var names: Array = result.get("names", ["P0", "P1"])
	var first: int = int(meta.get("first", -1))
	var first_txt: String = "P%d" % first if first >= 0 else "?"
	var diff: String = str(meta.get("difficulty", "-"))
	if diff.is_valid_int() and int(diff) >= 0 and int(diff) < DIFF_NAMES.size():
		diff = DIFF_NAMES[int(diff)]
	lines.append("角色: %s(P0) vs %s(P1) | 模式: %s | 难度: %s | 先手: %s | 总回合: %d" % [
		names[0], names[1], meta.get("mode", "?"), diff, first_txt, _last_turn(result)])
	# 双方卡组构成
	var decks: Array = meta.get("decks", [])
	if not decks.is_empty():
		for i in range(decks.size()):
			lines.append("P%d 卡组(%d张): %s" % [i, decks[i].size(), _deck_summary(decks[i])])
	# 行动流水：按回合分组
	lines.append("")
	lines.append("== 逐回合行动流水 ==")
	var cur_turn := -1
	for e in result.get("action_log", []):
		var t: int = int(e.get("turn", 0))
		if t != cur_turn:
			cur_turn = t
			lines.append("")
			lines.append("--- T%d ---" % t)
		var msg: String = str(e.get("msg", ""))
		var pname: String = str(e.get("player_name", "?"))
		var ctx: Dictionary = e.get("ctx", {})
		if msg.begins_with("[AI决策]"):
			lines.append("  ◆ %s %s" % [pname, msg])
		else:
			lines.append("  · %s %s %s" % [pname, msg, _ctx_text(ctx, int(e.get("player", -1)))])
	# 回合快照（手牌内容终态，配合流水使用）
	var record: Array = result.get("battle_record", [])
	if not record.is_empty():
		lines.append("")
		lines.append("== 每回合终态快照（弃牌后；手牌内容）==")
		var seen := {}
		for rec in record:
			if rec.get("phase", 3) != 3:
				continue  # 只取弃牌后终态
			var key: int = int(rec.get("turn", 0))
			if seen.has(key):
				continue
			seen[key] = true
			var p0: Dictionary = rec.get("p0", {})
			var p1: Dictionary = rec.get("p1", {})
			var a0: Array = p0.get("ap", [0, 0, 0])
			var a1: Array = p1.get("ap", [0, 0, 0])
			lines.append("T%d P0 HP%d/%d 位%s 手[%s] AP(%d/%d/%d) | P1 HP%d/%d 位%s 手[%s] AP(%d/%d/%d) | 牌堆%d 弃%d" % [
				key,
				p0.get("hp", 0), p0.get("max_hp", 1), _pos_text(p0.get("pos", {})), "、".join(p0.get("hand", [])),
				a0[0], a0[1], a0[2],
				p1.get("hp", 0), p1.get("max_hp", 1), _pos_text(p1.get("pos", {})), "、".join(p1.get("hand", [])),
				a1[0], a1[1], a1[2],
				rec.get("deck", 0), rec.get("discard", 0)])
	# 结算
	lines.append("")
	lines.append("== 结算 ==")
	var w = int(result.get("winner", -1))
	var titles: Array = result.get("titles", [])
	if titles.is_empty() and result.get("title", "") != "":
		titles = [result.get("title", "")]
	var loser: Array = result.get("titles_loser", [])
	lines.append("胜者: %s（%s）| 称号: %s | 败者称号: %s" % [
		names[w] if w >= 0 and w < names.size() else "?", result.get("reason", ""),
		"、".join(titles), "、".join(loser) if not loser.is_empty() else "无"])
	return "\n".join(lines)

# 生成结构化 JSON 回放（程序化分析用，最精确）
static func format_json(result: Dictionary, meta: Dictionary = {}) -> String:
	var names: Array = result.get("names", ["P0", "P1"])
	return JSON.stringify({
		"meta": {
			"mode": meta.get("mode", "?"), "difficulty": meta.get("difficulty", "?"),
			"first": meta.get("first", -1), "names": names,
			"decks": meta.get("decks", []),
		},
		"turns": _last_turn(result),
		"actions": result.get("action_log", []),
		"snapshots": result.get("battle_record", []),
		"winner": result.get("winner", -1),
		"reason": result.get("reason", ""),
		"stats": result.get("stats", []),
	}, "\t")

# 行动上下文文本：行动者视角显示 距离/双人HP/手牌内容/AP
static func _ctx_text(ctx: Dictionary, actor: int) -> String:
	if ctx.is_empty():
		return ""
	var me: int = actor if actor >= 0 else 0
	var opp: int = 1 - me
	var hp_me: int = int(ctx.get("hp%d" % me, 0))
	var hp_opp: int = int(ctx.get("hp%d" % opp, 0))
	var hand_types: Array = ctx.get("hand%d_types" % me, [])
	var hand_opp_types: Array = ctx.get("hand%d_types" % opp, [])
	var hand_names: Array = []
	for tid in hand_types:
		hand_names.append(Config.card_name(str(tid)))
	var ap: Array = ctx.get("ap%d" % me, [0, 0, 0])
	return "「距%d 我HP%d 敌HP%d 手[%s] 敌手%d张 AP(%d/%d/%d)」" % [
		int(ctx.get("dist", -1)), hp_me, hp_opp,
		"、".join(hand_names), hand_opp_types.size(),
		int(ap[0]), int(ap[1]), int(ap[2])]

static func _pos_text(pos) -> String:
	if pos is Dictionary:
		return "%d,%d" % [pos.get("x", 0), pos.get("y", 0)]
	return str(pos)

static func _last_turn(result: Dictionary) -> int:
	var record: Array = result.get("battle_record", [])
	if not record.is_empty():
		return int(record[record.size() - 1].get("turn", 0))
	return 0

# 卡组构成摘要："远程×6、穿心×2、道具×5..."
static func _deck_summary(ids: Array) -> String:
	var counts := {}
	for tid in ids:
		counts[str(tid)] = int(counts.get(str(tid), 0)) + 1
	var parts: Array = []
	for tid in counts:
		parts.append("%s×%d" % [Config.card_name(tid), counts[tid]])
	return "、".join(parts)

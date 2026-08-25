# ai_deck_test.gd — AI 临时卡组构建器验证（headless 测试场景挂载）
# 跑法（Godot 4.7）：godot --headless --path <项目> res://scenes/test_ai_deck.tscn
# 结果：print 输出 + 写入项目根 _ai_deck_test_result.txt（进程退出后可读取）
# 验证项：
#   1) 15 个 AI 角色 × 15 个对手角色 的卡组全部通过 DeckData.validate_deck（B 套餐）
#   2) 全部武器幻化池合法
#   3) 胜率模拟：猎人/法师「新卡组 vs 默认卡组」各若干局，确认卡组强度不弱于默认
extends Node

const DeckData = preload("res://scripts/data/deck_data.gd")
const AIDeckBuilder = preload("res://scripts/data/ai_deck_builder.gd")
const MatchStateClass = preload("res://scripts/core/match_state.gd")
const AIPlayerClass = preload("res://scripts/core/ai_player.gd")
const RecordFormatter = preload("res://scripts/core/record_formatter.gd")

const RESULT_PATH = "res://_ai_deck_test_result.txt"

var _winner: int = -1
var _out_lines: Array = []

func _ready():
	var t0 := Time.get_ticks_msec()
	_out("=== AI 卡组构建器验证开始 ===")
	var fails := 0
	# ---- 1) 全角色 × 全对手 卡组合法性 ----
	_out("=== 1. 卡组合法性（%d 角色 × %d 对手）===" % [Config.CHARACTER_IDS.size(), Config.CHARACTER_IDS.size()])
	var counted := 0
	for ai in Config.CHARACTER_IDS:
		for opp in Config.CHARACTER_IDS:
			var deck: Array = AIDeckBuilder.build_deck(str(ai), str(opp), 2)
			var v = DeckData.validate_deck(deck, "B")
			counted += 1
			if not v.ok:
				fails += 1
				_out("INVALID: ai=%s opp=%s -> %s" % [ai, opp, v.msg])
	if fails == 0:
		_out("全部 %d 组卡组合法" % counted)
	else:
		_out("%d 组卡组非法" % fails)

	# ---- 1.5) 抽查：每个角色的 build_deck 都应输出定制卡组（非默认回退）----
	_out("=== 1.5 定制卡组抽查（15 角色，对手=法师）===")
	for ai in Config.CHARACTER_IDS:
		var probe := AIDeckBuilder.build_deck(str(ai), "mage", 2)
		var probe_def := DeckData.default_deck()
		var is_default := probe.size() == probe_def.size()
		if is_default:
			for i in range(probe_def.size()):
				if probe[i] != probe_def[i]:
					is_default = false
					break
		if is_default:
			fails += 1
			_out("回退默认卡组: %s" % ai)
		else:
			_out("定制OK: %s（%d张, 远程×%d 道具×%d 魔法×%d）" % [ai, probe.size(),
				probe.count("range"), probe.count("item"), probe.count("magic")])
	# 猎人模板具体构成
	var raw: Array = AIDeckBuilder._hunter_template("wardsmith")
	var raw_v = DeckData.validate_deck(raw, "B")
	_out("hunter_template 原始: 张数=%d 校验ok=%s msg=%s（期望40张且ok）" % [raw.size(), raw_v.ok, raw_v.msg])
	if not raw_v.ok:
		fails += 1

	# ---- 2) 武器幻化池 ----
	_out("=== 2. 武器幻化池 ===")
	for ai in Config.CHARACTER_IDS:
		var pool: Dictionary = AIDeckBuilder.build_weapon_pool(str(ai), "mage")
		if not DeckData.validate_weapon_pool(pool):
			fails += 1
			_out("POOL INVALID: %s" % ai)
		else:
			_out("POOL OK: %s -> 近%s 远%s 法%s" % [ai, pool.get("near", []), pool.get("range", []), pool.get("magic", [])])
	if fails == 0:
		_out("全部武器池合法")

	# ---- 3) 胜率对比（新卡组 vs 默认卡组，同角色同对手） ----
	_out("=== 3. 胜率对比（各 12 局，AI 难度 hard）===")
	var matchups: Array = [
		{"ai": "hunter", "opp": "fighter", "label": "猎人(新) vs 斗士(默认)"},
		{"ai": "mage", "opp": "fighter", "label": "法师(新) vs 斗士(默认)"},
		{"ai": "hunter", "opp": "mage", "label": "猎人(新) vs 法师(默认)"},
		{"ai": "mage", "opp": "hunter", "label": "法师(新) vs 猎人(默认)"},
	]
	for m in matchups:
		var ai_id: String = m.ai
		var opp_id: String = m.opp
		var ctrl := _run_series(opp_id, ai_id, DeckData.default_deck(), DeckData.default_deck(), 12)
		var new_deck: Array = AIDeckBuilder.build_deck(ai_id, opp_id, 2)
		var exp := _run_series(opp_id, ai_id, DeckData.default_deck(), new_deck, 12)
		_out("%s | 对照组 P1胜 %d/%d | 新卡组 P1胜 %d/%d（P0=对手默认卡组）" % [
			m.label, ctrl.p1w, ctrl.total, exp.p1w, exp.total])

	var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
	_out("耗时 %.1fs" % elapsed)

	# ---- 4) 猎人行为统计（验证 playbook V2：埋伏收敛 / 主动攻击恢复 / 不再退板边）----
	_out("=== 4. 猎人行为统计（各 10 局，AI 难度 hard）===")
	for m in [{"opp": "paladin", "label": "猎人 vs 圣骑士（复现原问题局）"},
			  {"opp": "fighter", "label": "猎人 vs 斗士"},
			  {"opp": "priest", "label": "猎人 vs 牧师（复现新日志局）"},
			  {"opp": "berserker", "label": "猎人 vs 狂战士（满耐久防具死锁局）"},
			  {"opp": "wardsmith", "label": "猎人 vs 铸甲师（防具+站桩局）"},
			  {"opp": "mage", "label": "猎人 vs 法师"}]:
		var stats := _run_hunter_series(str(m.opp), 10)
		_out("%s | 胜 %d/10 | 夹子 %.1f | 埋伏 %.1f次 | 主动攻击 %.1f | 穿心打出 %.1f | 半场(≥8)回合 %.1f" % [
			m.label, stats.wins, stats.snares, stats.ambushes, stats.attacks, stats.pierces, stats.back_turns])

	# ---- 4.5) 牧师强度验证（默认卡组互打 30 局，P1=牧师；加大样本看趋势）----
	_out("=== 4.5 牧师强度（24/3/4 回复+1，默认卡组互打 30 局）===")
	for m in [{"opp": "fighter", "label": "牧师 vs 斗士"},
			  {"opp": "hunter", "label": "牧师 vs 猎人"},
			  {"opp": "mage", "label": "牧师 vs 法师"},
			  {"opp": "berserker", "label": "牧师 vs 狂战士"},
			  {"opp": "paladin", "label": "牧师 vs 圣骑士"}]:
		var r := _run_series(str(m.opp), "priest", DeckData.default_deck(), DeckData.default_deck(), 30)
		_out("%s | 牧师胜 %d/30" % [m.label, r.p1w])

	_out("=== RESULT: %s ===" % ("ALL PASS" if fails == 0 else "%d FAIL" % fails))

	# ---- 5) 生成 v2 样本日志（验证新格式可读性）----
	var sample := _run_sample_game()
	if sample.result.get("winner", -2) != -2:
		var f = FileAccess.open("res://_sample_v2_log.txt", FileAccess.WRITE)
		if f:
			f.store_string(sample.txt)
			f.close()
			_out("样本日志已写入 res://_sample_v2_log.txt（%d 字节，%d 回合）" % [sample.txt.length(), sample.turns])
	_flush()
	get_tree().quit(0 if fails == 0 else 1)

# 跑一局生成 v2 日志样本（猎人 vs 牧师，AI hard）
func _run_sample_game() -> Dictionary:
	var g = MatchStateClass.new()
	g.disable_timeout = true
	var ais: Array = [AIPlayerClass.new(g, 2), AIPlayerClass.new(g, 2)]
	_winner = -1
	g.weapon_prompt.connect(func(pi: int, w: Dictionary):
		g.confirm_weapon(pi, ais[pi].decide_weapon(pi, w))
	)
	g.response_needed.connect(func(di: int, info: Dictionary):
		var dec = ais[di].decide_response(di, info.get("card", ""))
		if dec.respond:
			g.process_response(di, true, dec.card_uid)
		else:
			g.skip_response(di)
	)
	g.game_ended.connect(func(r: Dictionary): _winner = int(r.get("winner", -1)))
	var hunter_deck: Array = AIDeckBuilder.build_deck("hunter", "priest", 2)
	g.init_match("priest", "hunter", 1, [DeckData.default_deck(), hunter_deck], true)
	g._start_game()
	var guard := 0
	while g.phase != Config.Phase.GAME_OVER and guard < 600:
		guard += 1
		if g.turn_number > 40:
			break
		var cur = g.current_player
		if g.waiting_for_discard:
			var cs = g.card_systems[cur]
			var need = max(0, cs.hand.size() - g.movement.get_hand_limit(cur))
			if need == 0: need = 1
			g.confirm_discard(cur, ais[cur].decide_discard(cur, need))
			continue
		var act = ais[cur].decide_action(cur)
		var r = g.process_action(cur, act)
		if not r.get("success", false):
			g.process_action(cur, {"action": "end_turn"})
	var meta := {"mode": "人机对战", "difficulty": 2, "first": g.first_player, "decks": g.deck_compositions}
	var result: Dictionary = g.game_result.duplicate(true)
	var txt: String = RecordFormatter.format(result, meta)
	return {"result": result, "txt": txt, "turns": g.turn_number}

func _out(s: String):
	print(s)
	_out_lines.append(s)

func _flush():
	var f = FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_out_lines) + "\n")
		f.close()

# 跑 N 局：P0=opp_char(默认卡组) vs P1=ai_char(p1_deck)，返回 {p1w, total}
func _run_series(opp_char: String, ai_char: String, p0_deck: Array, p1_deck: Array, n: int) -> Dictionary:
	var p1w := 0
	var total := 0
	for i in range(n):
		var w = _run_game(opp_char, ai_char, p0_deck, p1_deck)
		total += 1
		if w == 1: p1w += 1
	return {"p1w": p1w, "total": total}

# 跑 N 局猎人（P1）行为统计：胜场 / 夹子 / 埋伏日志数 / 主动攻击 / 穿心打出 / 退板边回合
func _run_hunter_series(opp_char: String, n: int) -> Dictionary:
	var wins := 0
	var snares := 0
	var ambushes := 0
	var attacks := 0
	var pierces := 0
	var back_turns := 0
	for i in range(n):
		var g = MatchStateClass.new()
		g.disable_timeout = true
		var ais: Array = [AIPlayerClass.new(g, 2), AIPlayerClass.new(g, 2)]
		_winner = -1
		g.weapon_prompt.connect(func(pi: int, w: Dictionary):
			g.confirm_weapon(pi, ais[pi].decide_weapon(pi, w))
		)
		g.response_needed.connect(func(di: int, info: Dictionary):
			var dec = ais[di].decide_response(di, info.get("card", ""))
			if dec.respond:
				g.process_response(di, true, dec.card_uid)
			else:
				g.skip_response(di)
		)
		g.game_ended.connect(func(r: Dictionary): _winner = int(r.get("winner", -1)))
		# 猎人 P1 用构建卡组（道具流），对手 P0 默认卡组
		var hunter_deck: Array = AIDeckBuilder.build_deck("hunter", opp_char, 2)
		g.init_match(opp_char, "hunter", 1, [DeckData.default_deck(), hunter_deck], true)
		g._start_game()
		var guard := 0
		while g.phase != Config.Phase.GAME_OVER and guard < 600:
			guard += 1
			if g.turn_number > 60:
				break
			var cur = g.current_player
			if g.waiting_for_discard:
				var cs = g.card_systems[cur]
				var need = max(0, cs.hand.size() - g.movement.get_hand_limit(cur))
				if need == 0: need = 1
				g.confirm_discard(cur, ais[cur].decide_discard(cur, need))
				continue
			var act = ais[cur].decide_action(cur)
			var r = g.process_action(cur, act)
			if not r.get("success", false):
				g.process_action(cur, {"action": "end_turn"})
		# 统计
		if _winner == 1: wins += 1
		for it in g.items:
			if it.item_type == "snare" and it.owner == 1:
				snares += 1
		for e in g.action_log:
			if e.get("player", -1) == 1 and str(e.get("msg", "")).contains("埋伏"):
				ambushes += 1
		var cp = g.stats[1].get("cards_played", {})
		for tid in cp:
			if tid in ["near", "heavy", "range", "pierce", "magic", "chant"]:
				attacks += int(cp[tid])
			if tid == "pierce":
				pierces += int(cp[tid])
		# 后撤到板边（P1 x≥8，手牌上限≤3）的回合数
		for rec in g.battle_record:
			var p1 = rec.get("p1", {})
			var pos = p1.get("pos", 0)
			if pos is Dictionary and int(pos.get("x", 0)) >= 8:
				back_turns += 1
	return {"wins": wins, "snares": snares * 1.0 / n, "ambushes": ambushes * 1.0 / n,
			"attacks": attacks * 1.0 / n, "pierces": pierces * 1.0 / n, "back_turns": back_turns * 1.0 / n}

# 同步跑一局（AI 决策循环，无帧依赖），返回胜者索引（-1=超时平局）
func _run_game(p0_char: String, p1_char: String, p0_deck: Array, p1_deck: Array) -> int:
	var g = MatchStateClass.new()
	g.disable_timeout = true
	var ais: Array = [AIPlayerClass.new(g, 2), AIPlayerClass.new(g, 2)]
	_winner = -1
	g.weapon_prompt.connect(func(pi: int, w: Dictionary):
		g.confirm_weapon(pi, ais[pi].decide_weapon(pi, w))
	)
	g.response_needed.connect(func(di: int, info: Dictionary):
		var dec = ais[di].decide_response(di, info.get("card", ""))
		if dec.respond:
			g.process_response(di, true, dec.card_uid)
		else:
			g.skip_response(di)
	)
	g.game_ended.connect(func(r: Dictionary): _winner = int(r.get("winner", -1)))
	g.init_match(p0_char, p1_char, randi() % 2, [p0_deck, p1_deck], true)
	g._start_game()
	var guard := 0
	while g.phase != Config.Phase.GAME_OVER and guard < 600:
		guard += 1
		if g.turn_number > 60:
			return -1
		var cur = g.current_player
		if g.waiting_for_discard:
			var cs = g.card_systems[cur]
			var need = max(0, cs.hand.size() - g.movement.get_hand_limit(cur))
			if need == 0: need = 1
			g.confirm_discard(cur, ais[cur].decide_discard(cur, need))
			continue
		var act = ais[cur].decide_action(cur)
		var r = g.process_action(cur, act)
		if not r.get("success", false):
			g.process_action(cur, {"action": "end_turn"})
	return _winner

# balance_sim.gd — 自动对局平衡性模拟（测试工具，不入游戏流程）
# 用法：游戏中 eval 执行 `add_child(load("res://scripts/tests/balance_sim.gd").new())` 后调 start()。
# 功能：用 AI 决策循环快速跑 N 局（默认 40 张卡组 vs 40 张卡组，独立牌堆），
#       统计胜率 / 平均回合数 / 成长牌使用次数 / 超时率，结果写入 user://balance_sim_result.txt。
# 注意：AI 决策基于共享牌堆假设编写，若在独立牌堆下崩溃，本工具会降级为随机决策。
extends Node

const MatchStateClass = preload("res://scripts/core/match_state.gd")
const AIPlayerClass = preload("res://scripts/core/ai_player.gd")
const DeckData = preload("res://scripts/data/deck_data.gd")

const RESULT_PATH = "user://balance_sim_result.txt"
const MAX_TURNS = 60        # 单局回合上限（超时判平）
const FRAMES_PER_STEP = 3   # 每 3 帧推进一步 AI（控制速度，便于观察）

var total_games := 20
var games_done := 0
var results: Array = []     # 每局 {winner, turns, grow_uses}
var _game = null
var _ai: Array = []
var _frame := 0
var _custom_decks: Array = []  # [deckA, deckB]；空则用默认 40 张

func start(games: int = 20, custom_decks: Array = []):
	total_games = games
	games_done = 0
	results.clear()
	_custom_decks = custom_decks
	_new_game()

func _new_game():
	var ids = Config.CHARACTER_IDS.duplicate()
	ids.shuffle()
	var p1 = str(ids[0])
	var p2 = str(ids[1])
	var decks: Array = []
	if _custom_decks.size() >= 2:
		decks = [_custom_decks[0], _custom_decks[1]]
	else:
		decks = [DeckData.default_deck(), DeckData.default_deck()]
	_game = MatchStateClass.new()
	_game.disable_timeout = true
	_game.rapid_mode = false
	_game.state_changed.connect(_on_state)
	_game.weapon_prompt.connect(_on_weapon)
	_game.response_needed.connect(_on_response)
	_game.game_ended.connect(_on_ended)
	_game.init_match(p1, p2, randi() % 2, decks, true)
	_ai = [AIPlayerClass.new(_game, 1), AIPlayerClass.new(_game, 1)]
	_game._start_game()

func _process(_d):
	if _game == null or games_done >= total_games:
		return
	_frame += 1
	if _frame % FRAMES_PER_STEP != 0:
		return
	if _game.turn_number > MAX_TURNS:
		_finish_game(-1)  # 超时判平
		return
	_step()

# 主循环：轮到当前玩家时 AI 决策一步；失败则结束回合
func _step():
	var cur = _game.current_player
	if _game.waiting_for_discard:
		var cs = _game.card_systems[cur]
		var limit = _game.movement.get_hand_limit(cur)
		var need = max(0, cs.hand.size() - limit)
		if need == 0:
			need = 1
		var uids = _ai[cur].decide_discard(cur, need)
		_game.confirm_discard(cur, uids)
		return
	var act = _ai[cur].decide_action(cur)
	var r = _game.process_action(cur, act)
	if not r.get("success", false):
		_game.process_action(cur, {"action": "end_turn"})

# 响应：防守方 AI 立即决策（同步处理，防卡响应窗口）
func _on_response(defender_idx: int, attack_info: Dictionary):
	if _game == null or _ai.size() <= defender_idx:
		return
	var dec = _ai[defender_idx].decide_response(defender_idx, attack_info.get("card", ""))
	if dec.respond:
		_game.process_response(defender_idx, true, dec.card_uid)
	else:
		_game.skip_response(defender_idx)

# 武器：AI 自动决策装备/丢弃
func _on_weapon(player_idx: int, weapon: Dictionary):
	if _game != null and _ai.size() > player_idx:
		_game.confirm_weapon(player_idx, _ai[player_idx].decide_weapon(player_idx, weapon))

func _on_state(_st):
	pass

# 对局结束：记录结果 → 下一局或输出汇总
func _on_ended(result: Dictionary):
	var winner = int(result.get("winner", -1))
	_finish_game(winner)

func _finish_game(winner: int):
	var grow_uses := 0
	var st = _game.stats
	for s in st:
		var cp = s.get("cards_played", {})
		for tid in cp:
			if tid in ["near_buf", "range_buf", "magic_buf"]:
				grow_uses += int(cp[tid])
	results.append({
		"winner": winner,
		"turns": _game.turn_number,
		"grow_uses": grow_uses,
		"p1": _game.players[0].char_id,
		"p2": _game.players[1].char_id,
	})
	games_done += 1
	if games_done >= total_games:
		_write_summary()
		print("[BalanceSim] DONE %d 局" % total_games)
		_game = null
		return
	_new_game()

func _write_summary():
	var p1_wins := 0
	var p2_wins := 0
	var draws := 0
	var turns_sum := 0
	var grow_sum := 0
	var max_turns := 0
	var timeouts := 0
	for r in results:
		if r.winner == 0: p1_wins += 1
		elif r.winner == 1: p2_wins += 1
		else: draws += 1
		turns_sum += r.turns
		grow_sum += r.grow_uses
		max_turns = max(max_turns, r.turns)
		if r.turns > MAX_TURNS - 1: timeouts += 1
	var lines := []
	lines.append("=== 平衡性模拟结果（%d 局，默认40 vs 默认40，独立牌堆）===" % total_games)
	lines.append("P1 胜 %d（%.1f%%）| P2 胜 %d（%.1f%%）| 平 %d | 超时 %d" % [p1_wins, 100.0*p1_wins/total_games, p2_wins, 100.0*p2_wins/total_games, draws, timeouts])
	lines.append("平均回合数 %.1f（最大 %d）" % [turns_sum*1.0/total_games, max_turns])
	lines.append("平均成长牌使用次数 %.2f" % [grow_sum*1.0/total_games])
	lines.append("--- 每局明细 ---")
	for i in range(results.size()):
		var r = results[i]
		lines.append("局%d: %s vs %s → winner=%s 回合%d 成长%d" % [i+1, r.p1, r.p2, r.winner, r.turns, r.grow_uses])
	var f = FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("\n".join(lines))

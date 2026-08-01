# 卡牌对决 — 扩展开发手册

> **加任何新东西之前先读本文件**。每个扩展点都列出"必改清单 / 不用动 / 自检清单"，照做即可，无需重读项目结构。
> 涉及 `scripts/core/` 的改动 = 服务端逻辑变化 = **必须通知主维护者部署服务器**。

---

## 1. 加一张新卡

### 必改
1. `scripts/data/card_data.gd` → `CARD_DB` 加一行：`"type_id": {name="卡名", ap=Config.APType.X, cost=行动点, desc="描述"}`
   - ap 枚举：`ATTACK`（攻击）/ `MOVE`（移动）/ `FUNCTION`（功能）/ `NONE`（免费）
2. `scripts/data/card_data.gd` → `CARD_COUNTS` 加数量（决定牌堆张数）
3. `scripts/core/card_effects.gd` → `_handlers` 注册：`"type_id": _handler函数`
   - handler 签名：`func(player_idx: int, card: Dictionary) -> Dictionary`，返回 `{success=true/false, msg=...}`
   - 内部实现：调 `_m._handle_*`（攻击/移动/摧毁等已有入口）或直接操作 `_m.players`/`_m.card_systems`
   - **必须**：`_m._use_card(player_idx, card)` 消耗卡 + `_m.add_log(player_idx, "...")` 记日志

### 攻击卡额外必改（4 处）
4. `scripts/autoload/config.gd` → `get_damage_type()` 加 type_id → 伤害类型映射；`get_response_type()` 加响应类型
5. `scripts/core/combat_system.gd` → `calculate_attack()` 的 `match card_type_id:` 加伤害公式
6. `scripts/data/equip_data.gd` → `RESPONSE_BY` 加"谁能响应它"
7. `scripts/core/combat_system.gd` → `process_response()` 的响应分支（如果可被响应）

### 不用动
- 场景、UI、网络协议、结算统计（出牌统计自动走 `_use_card`）

### 自检清单
- `CARD_COUNTS` 总和仍为 78？武器牌数量与武器池匹配？
- 自我对战打出一张：能出、能消耗、日志有记录

---

## 2. 加一个新角色

### 必改
1. `scripts/data/character_data.gd` → `CHARACTER_DB` 加 `"char_id": {name, hp, near, range, magic, skill, skill_desc}`；`CHARACTER_IDS` 加 char_id
2. `scripts/core/character_skills.gd` → 在需要的钩子里加 `"char_id": 逻辑` 分支（`match p.char_id:` 模式）：
   - 被动：`on_turn_start`（设 AP 等）、`on_taking_damage`、`on_attack_hit`、`on_heal`、`on_dot_damage`
   - 查询：`draw_count`、`move_distances`、`hand_limit_bonus`、`can_equip`、`is_immune`

### 主动技能额外必改（3 步）
3. `character_skills.gd` → `has_active_skills()` 加条件、`skill_button_name()` 加名字
4. `character_skills.gd` → `use_skill()` 加 `match skill:` 分支（参数从 params 取）
5. 带参数技能（选卡/选方向）→ `scripts/ui/battle_ui.gd` 的 `_exec_skill()` 加对应弹窗（参考 `mage_discard`/`assassin_move`）

### 不用动
- 场景、BP 网格（自动渲染）、网络协议

### 自检清单
- BP 界面能选到新角色；被动/主动技能各测一次；技能显示在"技能"按钮

---

## 3. 加武器 / 防具效果

### 必改
1. `scripts/data/equip_data.gd` → `WEAPON_DB` 加 `"wid": {name, type, effect, value, desc}`（type: "near"/"range"/"magic" 决定匹配的伤害类型）；防具加 `ARMOR_DB`（type: physical/ranged/magical）
2. 武器效果在 `scripts/core/combat_system.gd` 的消费点加 `weapon.id` 分支：
   - 伤害加成 → `_apply_weapon_damage_bonus()`
   - 命中特效 → `apply_on_hit_effects()`（可调 `status.add_buff/add_burn/add_poison`）
   - 距离修正 → `calculate_attack()` 特判（参考 longbow）

### 不用动
- 防具：走 `_check_armor` 通用逻辑（type 匹配 + 3 耐久），**无需**逐件分支

### 自检清单
- 装备后打对应类型攻击验证效果；被摧毁后武器回池可再生成

---

## 4. 加一个状态 Buff（注册表模式）

### 必改（2 处，无需改消费点）
1. 需要时 `status.add_buff(player_idx, "type_id", value, duration)`（duration=-1 回合结束清，on_turn_end 自动衰减）
2. `scripts/core/status_system.gd` → `_modifier_handlers` 注册表加一行：
   ```gdscript
   "type_id": func(buff, aspect, damage_type):
       return buff.value if (aspect == "attack" and ...) else 0,
   ```
   - 影响攻击伤害：判断 `aspect == "attack"`，需要时按 `damage_type`（`Config.DamageType.PHYSICAL/RANGED/MAGICAL`）区分
   - 影响移动：判断 `aspect == "move"`

### 不用动
- `get_attack_modifier` / `get_move_modifier`（自动走 `query_modifier` 统一入口）

### 注意
- 近战限定加成用 `near_up`（仅 PHYSICAL 生效），通用用 `attack_up`——不要用错（狂战士 bug 教训）
- DoT（灼烧/中毒）走独立的 `dots` 数组 + `add_burn/add_poison`，不走 buffs

---

## 5. 加技能钩子 / 新触发时机

- 钩子 = `character_skills.gd` 的公开函数 + `match_state.gd` 对应流程点调用（on_* 系列已有固定时机）
- 新钩子：在 character_skills 加公开函数（`match p.char_id:` 分支 + `_:` 兜底），在 match_state 需要的位置调用它
- 常用调用点：`_handle_attack_card`（攻击声明）、`process_response`（伤害结算）、`_action_phase`（回合开始）、`_handle_death`（死亡/复活）

---

## 6. 加网络消息（客户端↔服务端新指令）

### 必改（3 处）
1. `scripts/autoload/network.gd` + `scripts/autoload/local_game.gd`：加同名 `send_xxx()` 方法（本地模式直调 match_state，网络模式发 `{"t":"xxx"}`）
2. `scripts/server/server_main.gd` → `_handle_message()` 的 `match data.t:` 加分发分支
3. `scripts/core/match_state.gd` → 对应处理函数（如 `process_action` 的 action 分支）

### 注意
- 本地与联机必须行为一致（共用同一 MatchState）
- 消息类型名：客户端小写（`play_card`），服务端广播带 `"t"` 字段

---

## 7. 加新场景

1. 创建 `scenes/xxx.tscn`（参考 main_menu：Control 根节点 + 锚点居中 + 触摸尺寸 ≥120px 按钮）
2. 场景切换：`get_tree().change_scene_to_file("res://scenes/xxx.tscn")`
3. 跨场景数据传递：**不要用全局变量**，用 autoload 缓存字段（`Network.bp_state_cache` / `LocalGame.last_game_result` 模式）——场景 `_ready` 读缓存
4. 场景脚本用 `_n()` 统一访问 LocalGame/Network

---

## 8. 加结算统计项

1. `scripts/core/match_state.gd` → `stats` 初始化字典加字段（init_match 处），在对应结算点累加（参考 damage_dealt/heal_total 埋点）
2. `scripts/core/match_state.gd` → `_check_permanent_death` 的 `game_result` 已自动带 stats（无需改）
3. `scripts/ui/settlement_ui.gd` → `_fmt_stats()` 加一行展示

---

## 9. 加获胜称号

- 只改一处：`scripts/core/match_state.gd` → `_calc_title(winner_idx)` 按 `stats` 条件加 `if ...: return "称号名"`
- 顺序即优先级（第一个命中的生效），默认兜底 `return "征服者"`

---

## 10. 加调试功能（debug 构建专用）

- 服务端处理：`match_state.gd` → `process_action` 的 `use_skill` 分支加 `if skill == "_debug_xxx": return _debug_xxx(...)`（参考 `_debug_end`）
- 调试按钮：`battle_ui._show_debug_menu()` 加一个按钮，调 `_n().send_use_skill("_debug_xxx", {...})`
- 所有调试技能走 `use_skill` 通道 = 服务端权威，本地/联机都能用；release 构建无调试按钮（`OS.is_debug_build()` 控制）

---

## 11. 卡牌流转规范（防牌堆污染，新增牌堆操作必读）

- **卡牌唯一合法结构**：`{uid: int, type_id: String}`。装备数据结构（`{id, data, ...}`）**不是卡牌**，禁止进入手牌/弃牌堆/牌堆
- **只走 CardSystem 的方法**：`add_to_hand(card)` / `play_card(uid)` / `discard_card(uid)` / `discard_all()` / `random_discard(n)` / `draw_cards(n)`——**禁止直接操作 `hand`/`discard`/`deck` 数组**（CardSystem 会在入口校验卡结构，非法卡被拒绝并 `push_error`）
- 需要新流转方式（如"从对方牌堆偷牌"）→ 在 CardSystem 加方法（内部走校验），不要在外部拼数组
- 弃牌堆重洗（`_recycle_discard`）会把内容倒回牌堆——**弃牌堆一旦混入非法数据，污染会扩散到牌堆和手牌**（历史教训：换装防具数据误入弃牌堆导致 AI 决策崩溃）

---

## 12. 结算优先级规范（判断顺序，新功能对照此表确认插在哪一层）

**攻击伤害结算**（`combat.calculate_attack` + `match_state.process_response` 实际顺序）：
1. **条件检查**：近战/重击必须贴脸；穿心面板-距离≤0 → 攻击无效，**卡不消耗**
2. **基础伤害**：按面板与距离计算（长弓：距离衰减-1 + 远程+1）
3. **武器加成**：烈焰剑+2 / 突刺+1（移动贴脸额外+3）/ 贤者之书+2 / 共鸣+2（连击≥2）
4. **Buff 修正**：`get_attack_modifier`（attack_up / attack_down / near_up 按伤害类型）
5. **防具减伤**（仅计算，不消耗耐久）：满耐久→完全免疫；其余→减半
6. **技能加成**：`on_attack_cast`（法师强化等）——**免疫优先，加成不能穿透满耐久防具**
7. **响应窗口**：格挡（减半）/ 牵制（减免，连弩+2）/ 闪避（归零）
8. **技能减伤**：`on_taking_damage`（圣骑士减伤、狂战士加攻）——仅最终伤害>0 时触发
9. **防具耐久消耗**：仅实际造成伤害时（免疫也算一次命中；**被闪避/0伤害不消耗**）；3次后碎裂
10. **扣 HP** → 命中特效（武器/角色技能）→ **死亡判定**（复活流程）

**判定阶段**（每回合开始 `_judgment_phase`）：
1. DoT 结算：灼烧（-2×2回，再次命中刷新）/ 中毒（-1×2层，可叠加）
2. 死亡检查 → 复活/淘汰

**优先级要点（容易打架的地方）**：
- 免疫 > 技能加成（加成不能穿透满耐久防具）
- 闪避 > 防具耐久（被闪避不消耗）
- 伤害 > 0 才触发"受伤类"技能
- 失败攻击（距离不够）不计入连击（共鸣判定）
- 死亡判定覆盖所有扣血路径：攻击 / DoT / 道具（移动、推人、吸引、威慑、暗影步）/ 复活失败

---

## 13. 加地格道具类型（item_system 注册表模式）

道具 = 可放置在地格、被踩后触发效果的元素（陷阱是默认道具）。核心在 `scripts/core/item_system.gd`。

### 必改（2 处）
1. `scripts/core/item_system.gd` → `_item_types` 注册表加一条配置：
   ```gdscript
   "新类型": {
       "name": "显示名",
       "damage": 2,                # 踩上固定伤害；或挂 on_step 自定义回调
       # "on_step": func(player_idx, item): return 伤害值,   # 自定义触发（优先于 damage）
       "stack": "unlimited",       # unlimited 无限叠 | single 同格同类仅1 | max:N 上限N
       "special": false,           # true = 特殊道具（一张摧毁可清掉指定格全部特殊道具）
   },
   ```
2. 棋盘显示：`scripts/ui/components/board_renderer.gd` → `item_marks` 加类型标记（如 `"trap": "X"`）

### 触发/放置规则（自动生效，无需改）
- 放置：目标格不能有单位；按 `stack` 堆叠规则校验
- 触发：踩上按注册表结算（一次性消耗），伤害属无来源伤害（计入 `damage_from_trap`）
- 摧毁：必须指定格子（客户端棋盘选格）；该格有 `special` 道具时一张摧毁清掉整格全部特殊道具

### 注意
- 若道具由新卡牌放置：按"第 1 章加一张新卡"流程，卡效果里调 `_m.item_system.place_item(player_idx, "类型", pos)`
- AI 决策（ai_player.gd）如需利用新道具，在 `decide_action` 加对应评分/放置逻辑

---

## 14. 加多段攻击角色（预留机制，如快枪手）

核心机制已预留：`match_state` 攻击流程按段循环（每段独立 计算→响应→扣血→命中特效→死亡判定），段间自动进入下一响应窗口，末段才消耗卡。**只需在 `character_skills.gd` 加角色分支**：

### 必改（3 个钩子，都在 `scripts/core/character_skills.gd`）
```gdscript
match _ms.players[player_idx].char_id:
    "gunslinger":
        # ① 远程/穿心固定消耗 2 攻击行动点（返回 -1 = 用卡牌默认消耗）
        func get_attack_cost(player_idx, type_id): ...
        # ② 远程/穿心返回 2（两段伤害；其他卡返回 1）
        func get_attack_hit_count(player_idx, type_id): ...
        # ③ 段伤害公式（返回 -1 = 标准公式）：
        #    普通远程 floor((面板-距离)/2)；穿心 floor((面板+3-距离)/2)
        func get_attack_base_damage(player_idx, type_id, distance): ...
```

### 机制行为（已实现，无需再改）
- 两段各自独立响应窗口（敌人需两张响应卡）；0 伤害段自动跳过不弹响应
- 圣骑士首伤-2 只减免第一段（`damage_reduction_used` 标记天然满足）；狂战士狂化每段触发
- 武器命中特效每段独立（毒牙两次等）；防具每段独立计算/消耗耐久
- 整卡只计一次连击（共鸣不误判）；卡在末段结算后消耗

### 注意
- 数据层：`scripts/data/character_data.gd` 注册角色（数值/技能描述）由平衡性开发者负责
- AI：`ai_player.gd` 若需快枪手智能出牌，在 `decide_action` 评估两段价值
- 客户端段号显示已接好（响应弹窗"第X/Y段"）

---

## 通用规则（所有扩展适用）

1. **服务端权威**：逻辑判定只在 `scripts/core/`，UI 只转发
2. **状态广播**：改完状态必须 `state_changed.emit(get_full_state())`（MatchState 内）或等信号自动触发
3. **本地/联机一致**：`LocalGame` 和 `Network` 走同一 MatchState
4. **改 core/ 后**：自我对战验证 + 通知主维护者部署服务器
5. **数值一致性**：改数据表注意总数（78 卡 / 8 角色 / 12 武器）与 GAME_RULES.md 同步
6. **文档同步**：改完在 GAME_RULES.md / RESPONSE_RULES.md / API_REFERENCE.md 同步相关规则

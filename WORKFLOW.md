# 卡牌对决 — 项目工作流程文档

> **给下一个 AI 对话的交接文档**  
> 当前阶段：架构和功能基本完成，需要重点修复**运行时逻辑错误**

---

## 一、项目概览

双人对战回合制卡牌游戏。78张共享牌堆、8角色、11格棋盘。Godot 4.7.1 + GDScript。服务端权威（WebSocket），客户端纯UI。

### 仓库
- GitHub: `https://github.com/41hu/card_duel`
- 本地: `D:\projects\card_duel`
- 服务器: `root@47.107.47.251`（阿里云 Ubuntu）

### 文件结构

```
card_duel/
├── project.godot              # 项目配置，autoload: Config, Network, LocalGame, McpInteractionServer
├── scenes/
│   ├── main_menu.tscn         # 主菜单（三页：主页/创建房间/加入房间）
│   ├── bp_scene.tscn           # BP禁选（GridContainer角色卡片）
│   ├── battle_scene.tscn       # 对战界面
│   ├── settlement.tscn         # 结算界面
│   └── server.tscn             # 服务端入口
├── scripts/
│   ├── autoload/
│   │   ├── config.gd           # 【重要】静态数据：78卡牌、8角色、12武器、响应规则表、枚举
│   │   ├── network.gd          # WebSocket客户端通信，信号消息
│   │   └── local_game.gd       # 本地自我对战（模拟Network信号，内部用MatchState）
│   ├── core/
│   │   ├── match_state.gd      # 【核心】服务端权威状态机，回合流程，消息处理
│   │   ├── character_skills.gd # 【重要】角色技能钩子系统（18个钩子），加新角色改这里
│   │   ├── card_effects.gd     # 卡牌效果注册表，加新卡改这里
│   │   ├── card_system.gd      # 牌堆/手牌/弃牌管理（双方共享牌堆）
│   │   ├── combat_system.gd    # 伤害计算/响应/武器防具效果
│   │   ├── movement_system.gd  # 11格棋盘/距离/陷阱/推拉
│   │   ├── equipment_system.gd # 武器幻化/防具管理
│   │   ├── status_system.gd    # Buff/DoT/冻结管理
│   │   └── bp_system.gd        # BP禁选流程（随机先手）
│   ├── server/
│   │   └── server_main.gd      # TCPServer + 房间管理 + 消息转发
│   └── ui/
│       ├── main_menu.gd        # 主菜单逻辑
│       ├── bp_ui.gd            # BP界面逻辑
│       ├── battle_ui.gd        # 【重要】对战界面（手牌渲染/响应弹窗/技能按钮/弃牌UI）
│       └── settlement_ui.gd    # 结算界面
├── GAME_RULES.md               # 原始游戏规则
├── RESPONSE_RULES.md           # 响应规则详解
├── start_server.sh             # 服务端启动脚本
└── deploy.sh                   # 服务器部署脚本
```

---

## 二、游戏流程

### 完整流程
```
主菜单 → 创建/加入房间 → 准备 → BP禁选 → 对战 → 结算 → 主菜单
```

### BP禁选（bp_system.gd）
1. 随机决定先手（`_bp_first = randi()%2`）
2. first_ban → second_ban → first_pick → second_pick
3. `picked_chars[0]` = 先手玩家选的，`picked_chars[1]` = 后手玩家选的
4. server_main.gd 根据 `_bp_first` 映射到 P1/P2

### 回合流程（match_state.gd）
```
_judgment_phase()   # 判定阶段：DoT结算、死亡检查
  ↓
_draw_phase()       # 摸牌阶段：抽N张（char_skills.draw_count）
  ↓
_action_phase()     # 出牌阶段：重置AP、emit状态、等待客户端操作
  ↓ (客户端点"结束出牌")
_discard_phase()    # 弃牌阶段：等待玩家弃牌至≤上限
  ↓ (客户端点"确认弃牌")
_advance_to_next_player()  # 切换到对手
```

### 攻击结算顺序
1. 声明攻击 → 2. 计算基础伤害(面板-距离) → 3. 武器加成 → 4. Buff修正 → 5. 零伤检查 → 6. 响应窗口 → 7. 响应效果(格挡/牵制/闪避) → 8. 技能增伤(char_skills.on_attack_cast) → 9. 消耗攻击卡 → 10. 扣HP → 11. 命中特效(武器+技能) → 12. 死亡判定

---

## 三、角色技能钩子系统

所有技能逻辑集中在 `character_skills.gd`，18个钩子：

| 钩子 | 触发时机 | 返回值 | 用途示例 |
|---|---|---|---|
| `on_turn_start(idx)` | 回合开始 | void | 重置状态、分配AP(邪术师+1) |
| `on_turn_end(idx)` | 回合结束 | void | 邪术师额外抽牌 |
| `on_opponent_turn_start(curr)` | 对方回合开始 | void | 未来扩展 |
| `can_attack_free(idx, type)` | 判断是否免费 | bool | 神射手首远程免费 |
| `on_attack_cast(idx, type)` | 攻击牌打出 | int(伤害加成) | 法师+2魔伤 |
| `on_attack_hit(att, def, dmg, type)` | 攻击命中后 | void | 剑士回血 |
| `on_taking_damage(def, att, dmg)` | 受伤前 | int(修正后伤害) | 圣骑士减伤/狂战士加攻 |
| `on_heal(idx, amount)` | 回复时 | int(修正后回复量) | 牧师额外+2 |
| `on_dot_damage(idx, dot_types)` | 受DoT伤害后 | void | 牧师清除对应DoT |
| `has_active_skill(idx)` | 检查主动技能 | String(技能名或"") | 法师/刺客按钮 |
| `use_skill(idx, skill, params)` | 执行主动技能 | {success, msg} | 法师弃牌/刺客闪现 |
| `draw_count(idx)` | 每回合抽牌数 | int | 默认2 |
| `can_upgrade_skill(idx)` | 是否可升级 | String | 未来扩展 |
| `upgrade_skill(idx, count)` | 执行升级 | {success, msg} | 弃N牌永久增强 |
| `is_immune(idx, effect)` | 免疫检测 | bool | 免疫冻结/DoT/位移 |
| `modify_max_hp(idx, delta)` | 修改生命上限 | void | 正加负减 |
| `modify_stat(idx, stat, delta)` | 修改面板值 | void | stat="near"/"range"/"magic" |
| `hand_limit_bonus(idx)` | 手牌上限修正 | int | 在基础值上加减 |
| `move_distances(idx)` | 移动步数选项 | Array[int] | 默认[1]，可[1,2] |
| `can_equip(idx, type)` | 装备限制 | String(空=可) | "weapon"/"armor" |
| `skill_game_limit(skill)` | 整局次数限制 | int | -1=无限 |
| `_heal_limit(idx)` | 每回合回复上限 | int | -1=无限 |
| `check_hand_condition(idx, cond)` | 手牌条件检查 | bool | 注册表模式 |
| `set_damage_bonus(idx, types, amt, label)` | 设置增伤标记 | void | 通用接口 |

### 玩家数据字典
```gdscript
{
    index, char_id, hp, max_hp, near_power, range_power, magic_power,
    position(3或7), weapon, armor, buffs, dots,
    frozen, frozen_lockout, frozen_move,
    damage_reduction_used, skill_used_this_turn, free_move_used,
    damage_bonus, combo_attacks_this_turn,
    ap_attack(2), ap_move(1), ap_function(1),
    upgrades, skill_counts, healed_this_turn
}
```

---

## 四、卡牌效果系统（card_effects.gd）

注册表模式。加新卡：
1. `config.gd` 的 `CARD_DB` 加一行定义 → `CARD_COUNTS` 加数量
2. 本文件 `_handlers` 字典加 `"type_id": _handler_func`
3. 写效果函数

### 卡牌响应规则（config.gd）
```gdscript
RESPONDABLE_CARDS = ["near","range","magic","heavy","pierce","chant","freeze"]
RESPONSE_BY = {
    "near":["near"], "heavy":["near"],
    "range":["range"], "pierce":["range","magic"],
    "magic":["range","magic"], "chant":["range","magic"],
    "freeze":["magic"]
}
```

---

## 五、网络协议（JSON）

客户端→服务端：`{"t":"消息类型", ...其他字段...}`
服务端→客户端：同上，服务端广播状态为 `{"t":"game_state", ...}`

| 消息 | 方向 | 说明 |
|---|---|---|
| create_room | C→S | 创建房间 |
| join_room | C→S | 加入房间 |
| ready | C→S | 准备 |
| bp_action | C→S | BP操作 `{action:"ban"/"pick", char_id}` |
| play_card | C→S | 出牌 `{card_uid, extra:{...}}` |
| end_turn | C→S | 结束出牌 |
| respond | C→S | 响应 `{respond:bool, card_uid}` |
| weapon_choice | C→S | 武器确认 `{accept:bool}` |
| discard_one | C→S | 弃单张 `{card_uid}` |
| confirm_discard | C→S | 确认弃牌 `{card_uids:[]}` |
| use_skill | C→S | 使用技能 `{skill:"xxx", ...}` |
| reveal_hand | C→S | 请求查看对方手牌 |

### extra 参数
- `as_type`: 把牌当作某类型打出
- `from_opponent`: 从对手手牌出牌
- `steps`: 移动步数（默认1）
- `direction`: 移动方向（-1左/1右）
- `trap_pos`: 陷阱位置
- `destroy_target`: 摧毁目标（"hand"/"equip"）
- `card_uid`: 法师技能选弃的卡

---

## 六、已知问题和待修复

> 2026-08-01 更新：23 条中的大部分已修复（见"已修复"区）。标注 [UI] 的归主维护者；无标注的为 `scripts/core/` 逻辑问题。

### 严重（崩溃/卡死）

1. **[UI] 结算界面永远空白** — ~~已修~~（结果缓存 + 结算读缓存）
2. **[UI] 对战中断线无反馈** — ~~已修~~（battle_ui 监听 server_disconnected）
3. **[UI] 武器选择弹窗无超时** — ~~已修~~（回合超时自动放弃武器）
4. **陷阱双重扣血** — ~~已修~~（移动/暗影步只扣一次）
5. **陷阱致死无死亡判定** — ~~已修~~（推人/吸引/威慑/暗影步补 _check_any_death）

### 逻辑错误

6. **冻结每局只生效一次** — ~~已修~~（跳过回合后解锁 lockout）
7. **BP 先手失效** — ~~已修~~（init_match 传 bp_first）
8. **被闪避仍消耗防具耐久** — ~~已修~~（防具耐久延迟到实际伤害时消耗）
9. **穿心卡恒能打出** — ~~已修~~（面板-距离≤0 无法打出，卡不消耗）
10. **摧毁装备失败仍消耗卡** — `match_state.gd:396-398` 未修
11. **响应窗口无独立超时** — ~~已修~~（20 秒超时默认不响应，避免软锁）
12. **三把武器效果未实现** — ~~已修~~（长弓+1/连弩牵制+2/突刺贴脸+3）

### 安全/瑕疵

13. **Android 返回键双击退出未生效**（1.0.17-1.0.19）— back_handler 已接通知/信号/输入三通道 + 400ms 防抖，但真机与模拟器均划/按一次直接退出（无提示）。
    **最终结论（2026-08-01 模拟器验证）**：Godot 4.7 Android 模板的 `GodotActivity.onBackPressed` **直接 finish Activity**，返回键事件根本不到达引擎层（logcat 仅 `OnGodotTerminating`，无 back 事件进入）——GDScript 层任何钩子都收不到。`adb input keyevent 4`、模拟器 UI 返回按钮、真机全面屏手势三条路径行为一致。
    **修复方向**：需自定义 Android 模板（重写 `onBackPressed` 把 back 传给引擎 → GDScript 拦截），涉及 `custom_template/debug` 配置 + CI 集成。用户决定暂不修（细枝末节），留档待查
14. **`_cheat` 无服务端校验** — `match_state.gd:184` 任意联网玩家可发
14. **响应未校验身份** — `match_state.gd:319` 攻击方可对自己"响应"
15. **本地模式残留** — 结算返回后 `LocalGame.game` 未清空，再开网络局状态错乱
16. **BP 超时后不广播** — `server_main.gd:49-54` 超时自动操作后双方 UI 停在旧阶段
17. **[UI] 弃牌确认连点** — 发送后按钮不禁用，第二次发空数组；点选时全量重建手牌，双击会取消选中
18. **[UI] 取消陷阱选择后 `_selected_type` 未清** — `battle_ui.gd:483-490` 点棋盘报"手牌中没有此卡"
19. **[UI] 剑士弹窗堆叠** — `battle_ui.gd:350-351` 条件触发时叠多层全屏弹窗
20. **[UI] 邪术师 AP 圆点硬编码** — `battle_ui.gd:388-392` 功能点 2 只显示 1 个圆
21. **[UI] 倒计时归零 UI 冻结** — `battle_ui.gd:234-250` 永久显示"1s"
22. **[UI] action_log `max_count` 参数被忽略** — `action_log.gd:14` 日志无限增长
23. **[UI] 连接失败永久挂起** — `main_menu.gd:276-292` 卡在"正在连接..."，且连点创建多个 WebSocket

### 已修复/已消失（2026-07-31 审查确认）

- ~~响应卡消耗和伤害结算~~ — 已修复（combat:169 + match_state:337 均消耗）
- ~~DoT 无实际伤害~~ — 已修复（`_judgment_phase` 已扣血）
- ~~魔法攻击间歇性"距离过远"~~ — 已不存在
- 弃牌连点服务端已加守卫（但 UI 侧残留，见 #17）
- 冻结跳过出牌阶段逻辑存在（但暴露新问题 #6 lockout 未重置）
- 圣骑士减伤显示正常

### 已完成的功能（可回归测试）
- BP流程、回合切换、出牌/弃牌
- 共享牌堆、洗牌
- 响应窗口（格挡/牵制/闪避）
- 卡牌颜色分类、行动点圆圈
- Buff/DoT显示
- 法师主动技能（选卡弃牌→魔法+2）
- 刺客主动技能（免费移动1格）
- 陷阱触发（走/推/拉/吸引/威慑）
- 防具衰减（免疫→减半→减半→碎裂）
- 武器幻化（装备/丢弃/被摧毁回池）
- 角色技能显示、HP条件检查、手牌条件检查
- 免疫系统（冻结/DoT/位移/技能伤害）
- 偷牌/还牌、查看对手手牌
- 整局技能次数限制、每回合回复上限
- 生命上限修改、面板值修改

---

## 七、测试方法

### 本地自我对战
1. Godot 编辑器打开项目
2. 点运行 → 主菜单 → "自我对战"
3. 随机选两个角色直接开打

### 服务端联机
1. 启动服务端（SSH 到服务器）：
```bash
cd ~/card_duel && git pull && pkill -f Godot && nohup ~/godot/Godot_v4.7.1-stable_linux.x86_64 --headless --path ~/card_duel scenes/server.tscn > server.log 2>&1 &
```
2. 客户端填 `ws://47.107.47.251:17890`
3. 创建/加入房间 → 准备 → 对战

### Git 操作
```bash
cd D:\projects\card_duel
git add -A
git commit -m "描述"
git push
```

### 测试环境注意事项（改代码后验证前必读，避免误判"修复没生效"）

1. **清理残留 Godot 进程**：多次运行会留下多个 Godot 进程，旧进程可能被复用（脚本缓存旧代码）→ 改代码后验证前先清理：
   ```bash
   tasklist | grep -i godot   # 看进程
   taskkill /F /PID <pid>     # 逐个清理后重新运行
   ```
2. **检查状态残留**：跑过人机对战后 `LocalGame.ai_mode` 可能残留（自我对战不重置），残留 AI 会自动出牌/响应干扰测试。
3. **eval 限制**（若用调试桥）：单行紧凑写法；多语句可能截断；多行 for 只执行第一次迭代；循环用 map/filter 单行；二维数组只显示第一项；eval 语法错误会卡死需重启。
4. **跨进程数字比较**：JSON 传输后整数变 float，GDScript `in` 是严格类型匹配（`37.0 in [37]` = false），比较前统一类型（如 `int(uid) in 数组`）。
5. **模拟器/真机验证**：确认 APK 是最新版本（`dumpsys package` 查 versionCode），旧版残留会白测。
6. **BP 30 秒超时**：测试 BP 流程要快，超时自动 ban/pick 并切场景。
7. **输入事件注入**：`Input.parse_input_event` 注入的鼠标按下在 GUI 上不可靠，按下/释放分两步，或直接用 `get_viewport().push_input()`。

---

## 八、调试工具

- **远程执行器**：`godot-remote-executor` skill，连到编辑器执行 GDScript（Token 在本地配置文件，不入库）
  - URL: `http://localhost:5302`
- **MCP Godot工具**：`mcp__godot__*` 系列，需要 `McpInteractionServer` autoload
- **服务端日志**：SSH 到服务器 `cat ~/card_duel/server.log`

---

## 九、注意事项

- GDScript 用 **Tab 缩进**，不用空格
- `match` 是关键字，不能做变量名（已全部改用 `_ms`/`_m`）
- `preload` 必须在引用前声明（const 顺序）
- 服务器监听 `tcpserver.listen(PORT)` 不要绑 `127.0.0.1`（外网连不上）
- 改任何代码后考虑三件事：服务端需要改吗？本地模式要同步吗？改完发状态更新了吗？
- `replace_all` 谨慎使用，容易误伤

# 踩坑手册（TRAPS）

> 本项目开发中踩过的坑与正确做法。**每次任务开始前扫一遍；踩到新坑立即追加到这里**。
> 目标：同样的坑不踩第二次。

---

## 1. Godot 引擎行为陷阱

### 1.1 z_index 不参与输入命中（血泪教训）
- **现象**：按钮设置了 `z_index=10`，画在全屏层之上、看得见，但点击永远无反应。
- **根因**：Godot 4 的输入命中按**场景树顺序**（同父节点下，后 add_child 的兄弟优先），`z_index` 只影响绘制顺序。
- **正确做法**：按钮要在全屏层（pick_root/edit_root 等）**之后** add_child（树序最后 = 输入最优先）；z_index 只用来控制绘制。判断一个按钮"按不动"时，先查它的 `get_index()` 是不是比全屏层小。
- 案例：deck_pick 的 back_btn（1.0.71 的 z_index=10 修复无效，1.0.73 改为树序最后才真正修好）。

### 1.2 ScrollContainer 触摸滚动
- Godot 4.7 `scroll_container.cpp` 只在 `is_touchscreen_available()==true` 时启用拖动滚动，且只处理 MouseButton/MouseMotion（触摸由 `emulate_mouse_from_touch=true` 模拟），**不处理 ScreenTouch/ScreenDrag**。
- 容器内按钮/卡牌要设 `mouse_filter = MOUSE_FILTER_PASS`，否则按钮把 MouseButton 拦下，拖动不生效（同源拖动 bug：点击和拖动都从同一个按下开始）。
- 想让点击穿透到下层（如日志盖住棋盘）又保留滚动：给 ScrollContainer 本身设 PASS（滚动发生时 accept 停止下传，纯点击不 accept 传给下层）。

### 1.3 ScrollContainer 内容水平裁剪
- **现象**：日志长行右侧被裁掉。根因：子 Label 不换行时自然宽撑大 VBox 最小宽 → 内容区比视口宽。
- **正确做法**：给 Label 设 `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART`，Label 最小宽归零，内容区回到视口宽。

### 1.4 Label 文本溢出 anchor 矩形
- Label 不裁剪：文本多于 anchor 矩形高度时**照样绘制**（超出部分浮在下方元素上）。布局计算时按"实际行数×行高"估，不能只看 offset_bottom。

### 1.5 Style.fs() 桌面放大 1.1 倍
- `Style.fs(28)` 在桌面（窗口宽≥1630）返回 `ceil(28*1.1)=31`，移动窄窗最高放大 1.7 倍。布局估算行高要用 fs 后的值（31px 字号≈43px 行高）。

### 1.6 MCP godot 工具链的坑
- **多进程端口冲突**：`run_project` 启动新实例时若旧实例没死干净，9090 端口被旧进程占，MCP 一直交互的是**旧代码**。改完代码"验证不生效"时，先 `Get-Process *Godot*` 看是否有多个进程，全杀后重启（`stop_project` 可能杀不干净，用 pwsh Stop-Process 兜底）。
- **eval 断点卡死游戏**：eval 代码里访问 null（如对局结束切场景后 `LocalGame.game.players`）、给 void 调用链式取值（`add_child(...).new()`）、定义嵌套函数/把 lambda 赋给 Node.process——都会触发 Debugger Break，之后所有 MCP 命令超时。只能杀进程重启。
- **eval 多语句**：可以写多行（用换行分隔），但别写嵌套 func/lambda 赋 process。
- **跑 ui_regression**：`var t = load(...).new()` + `get_tree().root.add_child(t)` + `t.start()` 三行分写；结果读 `user://ui_regression_result.txt`。
- **测完必清进程**：headless 测试客户端/服务器 job 结束后可能残留进程，占端口影响下次测试。

---

## 2. 联机协议与断线链路

### 2.1 断线各阶段处理原则（服务端 _on_peer_disconnected）
- 2 人房按 stage 区分：`waiting`=房间等人（通知存活方"对手已离开"）；`bp`/`deck`=流程已启动但未开局 → **必须给存活方发 game_over 结算**（否则客户端卡死在 BP/配置页）；`game`=对局中断线 → 存活方获胜结算；`ended`=已结算 → 直接清理。
- 判断"未开局"**不能**只靠 `room.match == null`：BP/deck 阶段 match 已创建但 `match.players` 为空。按 `room.stage` 判断最稳。
- 服务端 `_peers` 数组断线**不能 remove_at**（索引错位导致消息发错人），用 `peer.dead` 标记 + 保留槽位；广播/`_send_to` 出口统一跳过 dead peer。
- **player_index 与数组下标的一致性是不变量**：4 人房等待阶段删人时必须 `peer_names.remove_at(idx)` 和 `ready.remove_at(idx)` 同步压缩并**重排存活者 player_index**，补位 join 时 `ready.append(false)`；`_on_ready` 要防重复触发（stage 检查）和人数未满不开局（`peer_indices.size() < max_players` 直接 return）。
- 4 人房对局中断线者若是 `current_player`，要主动 `_advance_to_next_player()` 换人，否则软锁到 60s 超时。
- 客户端每个场景都要处理两条断线信号：对手断线（`game_ended` 带 reason=opponent_disconnected → 跳结算）和自己掉线（`server_disconnected` → 回主菜单）。漏一个就卡死。

### 2.2 状态清零不变量
- `Network._close()` 必须清 `bp_state_cache`/`battle_state_cache`/`deck_config_data`（残留会让本地局被误判联机）；**但 `last_game_result` 不清**——排空缓冲包时刚写入的结算数据要留给结算页读，它每次结算重写、不存在串局。
- `LocalGame.disconnect_from_server()` 必须复位 `tutorial_mode`（教程中返回键退出后再开 AI 局会误挂教程管理器覆写对局状态）+ 清缓存。
- 教程引导 UI 挂 `battle_ui` 下而非 `get_tree().root`：场景销毁自动释放，杜绝非正常退出的孤儿残留。

### 2.3 断线竞态
- `STATE_CLOSED` 分支要先 `while get_available_packet_count()>0` 排空缓冲包（最后一包可能是对手逃跑的 game_over 结算），再发 `server_disconnected`；且无论 `_active` 与否都要 `_close()` 清 socket（握手失败路径）。

### 2.4 测试环境坑
- 服务器房间号**递增不重置**（1000 起），重启服务器才会回到 1000。写死房间号的测试要先重启服务器，或按 network_error 重试下一个号。
- 端到端联机测试模板：本地起 `scenes/server.tscn`（headless）+ 多个 headless 客户端脚本（`-- role=A/B/C/D case=N` 参数化），验证以 A 的输出为准（主动断线方退出码 1 是预期）。临时测试脚本用完删除。
- `room.decks` 初始化用 `[[], []]`（与 deck_ready 赋值的数组类型一致），不要 `[{}, {}]`。
- **MCP 每次交互往返耗时数秒**：BackHandler 双击退出窗口（400ms~2s）无法用两次 MCP 按键模拟，用 eval 手动构造 `BackHandler._last_back_time = now - 1000` 后调 `_handle_back()`。

---

## 3. 双通道（LocalGame/Network）复用

- UI 通过 `_n()` 二选一：`LocalGame.game != null` → LocalGame，否则 Network。两者信号同名（state_updated/game_ended 等）。
- **共享缓存要清理**：Network.battle_state_cache / deck_config_data / last_game_result、LocalGame.game——场景切换时谁清、什么时候清，改动前先想"上一局数据会不会串到下一局"（本地局打完开联机局、联机断线后开本地局）。
- 结算页从 `last_game_result`/`game_result` 读数据，**必须容忍空字段**（stats/titles/battle_record 可能为空数组——断线结算就是这样），用 `.get(key, 默认值)` 不能直取。

---

## 4. UI 布局与场景

- 战斗界面是分区式布局（左日志/中棋盘/右对手面板/左下自己面板/底部手牌），坐标牵一发动全身。**改任何区域位置/尺寸后必须实测**：教程横幅、弹窗、卡详情、安全区偏移都要检查重叠。
- 教程引导横幅位置依赖布局：现在在顶部居中（y110 起，避开 PhaseLabel 到 y101、棋盘 y400 起）。教程文案中引用 UI 位置的词（"左下角面板""左侧日志"）与布局绑定，改布局要同步改文案。
- 全屏层（pick_root/edit_root/弹窗）与常驻按钮：见 1.1。
- 提示残留：需要"新提示覆盖旧提示"的 Label 用单例式管理（`_flash_label` 先 free 旧的再加新的），不要每次 add 新 Label。

---

## 5. 工作流约定（用户规则）

- **git push 必须先经用户明确同意**（历史教训：自动 push 越界过）。
- 版本发布链：改 `scripts/version.gd` bump → commit → push → CI 自动打包 APK + GitHub Release + 上传 version.json 到服务器 → 客户端比对提示更新。
- **改了 `scripts/server/server_main.gd` 必须提醒重启服务器**（root@47.107.47.251，deploy.sh/start_server.sh），否则新客户端跑旧服务器会出现协议不一致。
- 实现新功能每一步先问用户采用哪种方案。
- 测试工具常驻：`scripts/tests/ui_regression.gd`（UI 回归，改动 battle_ui 后必跑）、`balance_sim.gd`（AI 对局模拟）。
- 桌面实测窗口 1920×1080；真机横屏锚点相对布局自适应，绝对坐标估算时用锚点换算。

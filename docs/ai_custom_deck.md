# 自定义卡组模式 — AI 适配方案

> 目标：人机对战「自定义卡组」模式下，AI 根据 **人类对手选择的角色** 动态组建自己的 40 张临时卡组（角色模板 + 针对对手调整），并配合 AI 决策逻辑发挥卡组威力。
> 权威来源：**当前代码**（`scripts/data/*`、`scripts/core/*`）。`GAME_RULES.md` 已过时，仅作历史参考（差异见第三节）。

---

## 一、自定义卡组模式机制（以当前代码为准）

### 1.1 模式定义（`mode_data.gd` → `custom_deck`）
- 配置：`shared_deck: false` → **双方各自独立牌堆**（每副 40 张，抽完洗弃牌堆循环，见 `card_system.gd._recycle_discard`）
- 流程：BP 禁选 → 双方选角 → 进入 `deck_pick` 配置卡组 → 开战
- 人机：**人类(P0)配卡，AI(P1)自动用卡**（当前是写死的默认卡组，见第四节）

### 1.2 构筑规则（`deck_data.gd`，AI 组卡必须遵守）
- 总张数 **40**；四池总上限：攻击 17 / 战术 14 / 回复与数值 6 / 装备 5（池上限和 42 > 40，强制跨池取舍 2 张）
- 单卡上限：普通攻击 6、强化攻击 2、freeze 2、move 4、item 5、防具 1、其余默认 3
- 强化攻击子池 ≤5、武器子池 ≤3、防具子池 ≤2
- **回复套餐**（A/B/C 三选一，回复卡与数值卡互相挤占）：
  - A：heal_5×2（回10）｜数值卡 ≤4（单卡 ≤2）
  - B：heal_5×1 + heal_3×2（回11）｜数值卡 ≤3（单卡 ≤1）
  - C：heal_3×4（回12）｜数值卡 ≤2（单卡 ≤1）
- 默认套餐 B；校验入口 `DeckData.validate_deck(cards, package_id)`

### 1.3 武器幻化池（`deck_data.gd`）
- 每类型恰好 4 把（近/远/法各 4），默认 = 武器库每类型前 4 把；可自定义换入
- 场上武器全局不重复（`match_state.weapon_pools` 按玩家独立）
- 武器卡打出 → 从**自己池**中随机幻化一把未生成的 → 确认装备/丢弃

### 1.4 规则开关（`mode_data.gd` CONFIG_DEFAULTS）
- 手牌上限/下限、共享牌堆、无限出牌、冻结无冷却、天赐不限、复活上限——自定义卡组模式默认仅 `shared_deck:false`，其余默认

---

## 二、GAME_RULES.md 过时点（以代码为准，勿再用文档旧认知）

| 主题 | GAME_RULES.md（旧） | 当前代码（真） |
|---|---|---|
| 道具卡 | 「陷阱」×3 | type_id 改名 **`item`** ×3（2026-08 消歧义）；放置的道具类型由角色决定：默认陷阱 / 猎人捕兽夹(snare) / 巫女鸟居(torii)，踩上效果各异（`item_system.gd`） |
| 法师 | 弃牌强化+2 | 另新增**幻影**：弃魔法/吟唱获 1/2 层，闪避概率 = 层数/(层数+1)，永久叠加，闪避成功耗 1 层 |
| 圣骑士 | 首伤-2 | 另新增**反击**：用响应完全抵挡一次攻击后，下次攻击伤害+1（可叠加 2 回合） |
| 牧师 | 回复+2 / 清 DoT | 另新增**真言**：弃回复卡造成等值法术伤害（无视护甲，只能魔法响应） |
| 寻踪者 | 校准 | 另新增**追击**：近战命中获 1 层（持续 2 回合），可抵消一次校准清空 |
| 猎人 | 埋伏弃远程放 1 夹 | 弃**穿心**卡放 **2 个**夹子；捕兽夹可无限堆叠、一张摧毁清空同格全部 |
| 强化攻击 | 未提穿甲 | **heavy/pierce/chant 命中防具额外 -2 耐久**（`combat_system.pierce_armor`） |
| 穿心 | 远程结算后+3 | 另有「面板−距离 ≤0 无法打出」限制 |
| 冻结 | — | 冻结可被魔法卡闪避响应 |
| 铸甲师 | 护甲耐久+1 | 注魔换甲满耐久 4、修复 +2 耐久（耗攻击点+强化卡） |
| 饲甲人 | 活铠减半 | 活铠耐久 2 全类型减半、0 耐久无减伤、不碎裂、护甲卡=修复活铠 |
| 模式 | 仅经典 11 格 | 经典/快速/四人混战(六边形)/自定义卡组 四模式 + 房间规则开关 |
| 天赐 | 免费限 1 | 每回合限 1（`free_move_used` 标记）；快速/「天赐不限」时无限 |

---

## 三、AI 在自定义卡组模式的适配现状

### 已适配（`ai_player.gd`）
- **独立牌堆记牌**：`_global_left` 在 `independent_decks` 下直接数「牌堆+手牌+弃牌」实有数量（不再用 78 张基数推算），资源期判定正确
- **猎人卡组感知**：`_hunter_ambush_playbook` 统计自己 deck 的战术卡/攻击卡构成 → 战术流打法加成
- **卡组注入**：`match_state._build_card_system(idx, custom_decks)` 支持任意合法 40 张（uid = idx*1000+i 防跨玩家冲突）

### 缺失（本次要做的）
1. **AI 临时卡组**：`deck_pick._start_battle()` 写死 `DeckData.default_deck()` —— 不管对手选谁都用同一副通用卡组
2. **AI 武器幻化池**：写死 `DeckData.default_weapon_pool()` —— 不与对手/自身角色联动
3. **卡组构成影响决策**：除猎人埋伏外，AI 的防具/响应/控制决策不感知自己卡组构成（如卡组无远程牌时不该保留远程响应位）

---

## 四、AI 临时卡组构建器（已实现，2026-08-23 验证通过）

### 4.1 新增文件：`scripts/data/ai_deck_builder.gd`（静态工具，数据层）

```
static func build_deck(ai_char_id, opp_char_id, difficulty=2) -> Array   # 40 张 type_id，validate_deck 校验通过
static func build_weapon_pool(ai_char_id, opp_char_id) -> Dictionary     # 每类型 4 把
static func opp_main_attack_type(opp_char_id) -> String                 # 近战/远程/魔法（面板三属性 + 技能特判）
```

### 4.2 组卡原则：角色模板 + 针对对手调整

**角色定位模板**：
- 精细模板：**猎人**（**输出流**：range 6 + pierce 2 + magic 3（闪避）+ near 3 + heavy/chant 各 1 + move 4 + item 2（夹子辅助）+ attract 2，武器池换入风神弓；原"道具流 item×5"实测夹子对会避夹对手几乎无伤且占用输出卡位，已废弃）、**法师**（魔法爆发流：magic 6 + chant 2 + magic_weapon 3）
- 通用定位模板（其余 13 角色）：攻击 16（定位主攻 6+强化 2 + 闪避 magic 4 + 格挡 near 3 + 副强化 1）+ 战术 13 + 回复 6（B 套餐）+ 装备 5
- **模板张数必须恰好 40**：四池上限和 42 > 40（跨池取舍设计），攻击 16 / 战术 13 不满上限。历史教训：模板超 40 张（42/43/45）→ validate 失败 → `build_deck` 静默回退默认卡组 → **AI 实际一直在用默认卡组**。测试须抽查输出非默认卡组（`ai_deck_test.gd` 1.5 节，15 角色全过）

**针对对手调整**（`opp_main_attack_type` 读对手面板 + 技能特判，如魔剑士→近战、法师→魔法）：
- 防具 2 张：按对手主攻类型选主防 + 次防（对手魔法→magic_armor+range_armor 等）
- 武器：AI 定位类型武器 3 张
- 响应牌配比：攻击池已含闪避 magic 4 / 牵制 range 3-4 / 格挡 near 3-6 的基础盘

**校验兜底**：`DeckData.validate_deck(cards, "B")` 非法 → 回退 `DeckData.default_deck()`（防线上出错）

### 4.3 接入点（已改 `deck_pick.gd._start_battle()` 人机分支）

```gdscript
var ai_deck: Array = AIDeckBuilder.build_deck(str(chars[1]), str(chars[0]), LocalGame.ai_difficulty)
var ai_pool: Dictionary = AIDeckBuilder.build_weapon_pool(str(chars[1]), str(chars[0]))
LocalGame.start_ai_game(str(chars[0]), str(chars[1]), LocalGame.ai_difficulty,
    [decks[0], ai_deck], true, [pools[0], ai_pool])
```

### 4.4 验证结果（`scenes/test_ai_deck.tscn` + `scripts/tests/ai_deck_test.gd`，headless）

- 15 AI 角色 × 15 对手 = **225 组卡组全部合法**（B 套餐）
- 全部武器幻化池合法；猎人远程池 = [长弓, 鹰眼, 毒牙, 风神弓]（连弩换风神弓）
- 胜率对比（P1 新卡组 vs P0 默认卡组，各 12 局，hard 难度）：
  | 对局 | 对照组（默认 vs 默认） | 新卡组 P1 |
  |---|---|---|
  | 猎人 vs 斗士 | 5/12 | **6/12** |
  | 法师 vs 斗士 | 11/12 | **12/12** |
  | 猎人 vs 法师 | 2/12 | 2/12（天然克制，需决策层解决）|
  | 法师 vs 猎人 | 11/12 | 9/12（仍 75%+）|

### 4.5 后续增强（决策联动，可分批做）
- **AI 决策层读自己卡组构成**：卡组无某类响应牌 → 防守策略转向（多位移/防具替代）；卡组输出集中在某类型 → `_current_role` 定位漂移已天然支持
- **逐角色精细模板**：参考 `docs/ai_playbooks.md` 猎人道具流的做法（模板 + 打法闭环），从「通用定位模板 → 精细模板」逐个迭代
- **克制短板**：猎人打法师（魔 2 vs 魔 8）等天然劣势对局，卡组层面空间有限，靠决策层（贴脸近战 4 输出 + freeze 打断 + 闪避保命）改善

---

## 五、旧日志问题的新旧对照（评审基线修正）

| 旧日志问题 | 状态（2026-08-23 之后代码） |
|---|---|
| 穿心埋伏第二夹落 (0,0) | ✅ 已修（`_hunter_ambush_playbook` 用 `picked.size()>1` 守卫） |
| 猎人无 playbook | ✅ 已实现（埋伏 playbook + 夹子区 combo） |
| 角色名「弓手/剑士」 | 旧角色名，现为神射手/魔剑士，数值已变，日志不再有效 |
| 远程型输出荒废 | ⚠️ 需用**新日志**验证是否仍存在（猎人 playbook 的资源门槛/距离管理仍是疑点） |
| 防具针对性差 | ⚠️ 普通难度 `_opp_main_attack_type` 仍退化为角色定位，疑点保留 |
| 法师强化被闪避白费 | ⚠️ 需新日志验证（hard 读牌已实现） |

> 结论：8-03 的日志基本作废（旧代码旧数值）；8-22/8-23 的猎人日志部分有效但需对照新代码复核。**评审以用户新发的、当前版本的对局日志为准**。

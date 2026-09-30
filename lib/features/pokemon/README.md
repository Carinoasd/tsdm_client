# 宠物中心（pokemon）

Discuz! X5 宠物插件（`plugin.php?id=pokemon:pokemon`）的原生客户端，功能包括：我的宠物 / 宠物中心 / 背包 /
商店、宠物详情与装备、冒险地图与战斗。

服务端是论坛的插件，客户端只走它的 JSON API（`endpoint=...`），不解析游戏页面。本文件记录**这一模块的结构与
必须知道的约定**，改动前先读一遍。

## 目录结构

| 目录 | 职责 |
| --- | --- |
| `models/` | 接口 DTO（`dart_mappable` + 容错 `fromMap`）与业务判定。`pokemon.dart` 放宠物自身的规则（`needsHealing`、`negativeStates`、`isCarried/isStored/isActive`）；`models.dart` 是 barrel |
| `repository/` | 所有 HTTP。`pokemon_repository.dart` 是唯一的接口入口；`adventure_cache.dart` 是跨页缓存（地图、最高等级、本会话已结束的战斗）；`skill_order_store.dart` 存技能顺序（本机） |
| `cubit/` | `pokemon_cubit.dart`：宠物中心页的状态与动作；`battle_cubit.dart`：战斗状态机 |
| `view/` | 页面与 tab（`pokemon_page` 外壳 + `my_pokemon_tab`/`pokemon_center_tab`/`inventory_tab`/`shop_tab`，以及 `adventure_page`、`battle_page`、`pokemon_detail_page`、`pokemon_equipment_page`、`pokemon_storage_page`）。`battle_page.dart` 是页面与状态机，展示型的私有部件在 `battle_view.dart`（`part of`）里 |
| `widgets/` | 模块内复用的小部件（与仓库其它 feature 一致，放在 **feature 级** `widgets/`，不要放回 `view/widgets/`） |
| `utils/` | `action_feedback.dart`（接口错误 → 本地化文案）、`pokemon_style.dart`（属性/地区/状态 → 颜色与文案）、`pokemon_dialogs.dart`、`pokemon_image.dart`（图片 URL）、`item_merge.dart`（背包分页合并） |

## 编码约定

- 注释与文档一律**英文 `///`**，行宽 ≤ 120，公开成员必须有文档（严格检查会拦：`dart ./scripts/check_strict_analyzing.dart`）。
- 接口错误统一返回 `Either<AppException, T>`（`AsyncEither`），不要在 repository 里抛异常。
- 模型用 `dart_mappable`；改模型或 i18n 后必须重新生成：`dart run build_runner build`。
- 所有面向用户的文案走 i18n（`context.t.pokemon.*`），三份语言文件都要加：`lib/i18n/{zh-CN,en,zh-TW}.i18n.json`。
- 提交前：`flutter analyze lib`、`dart ./scripts/check_strict_analyzing.dart`、`flutter test`。

## 服务端约定与坑（重点）

改动前务必确认下面这些，它们都是踩过的坑：

1. **`X-Pm-Formhash`**：新版插件对 `api/index.php` 的所有请求做跨站校验，请求头必须带会话 formhash。
   客户端在 `_ensureFormHash` 里 GET 一次游戏页解析并缓存，遇到「formhash 校验失败」会重取一次并重试一次。
   （服务端改动见插件 PR #59，已先上线、后合并。）
2. **未登录**：返回 **403 + 空体**（旧版是 401 + JSON）。`_decodeEnvelope` 把它归一化成
   `PokemonApiException('需要登录', code: 401)`；有异常对象时优先判 `error.code`，只有拿不到对象时才匹配文案。
3. **`state` 状态码**（`plugin/api/pokemon.php: get_pokemon_state_text`）：
   `0` 濒危、`1` 正常、`2-4` 生病、`5-6` 饥饿、`7` 疲惫、`8-10` 兴奋、`11` 受伤、`12-14` 开心、`15` 惊慌、
   `16-17` 自恋、`18-19` 愤怒、`20-22` 虚弱。**只有 12 个负面状态会被治疗重置**，见
   `Pokemon.negativeStates`；兴奋/开心/自恋/愤怒是**故意不治**的，把它们当"需要治疗"会每次都白治一遍。
   界面上**不要直接显示服务端的中文 `state_text`**，用 `pokemonStateText(context, state, stateText)`。
4. **`site`**：`1` 首发、`2` 替补、`3` 仓库。服务端自己的判定是 `site < 3`，客户端统一用
   `isCarried` / `isStored` / `isActive`，不要再写 `site == 1 || site == 2`。
5. **`status: 'defeat'` 不代表战斗结束**：插件在我方倒下但仍可用替补时保留战斗，只是回 `defeat` 让前端弹换宠。
   所以战斗页在 `defeat` 后要 `finishDefeat`（= `user&action=heal_and_flee`，必清战斗且顺手治疗）并记住这场战斗，
   否则冒险页会用 `recover` 把它拉回来。
6. **治疗（`user&action=heal`）免费且幂等**：无条件回满 HP 与技能 PP，并把负面状态归 `1`。
   因此「PP 不满」也是一次有效治疗；`healParty()` 只挑 `needsHealing` 的宠物，并且**并发**发起（一只一个往返太慢）。
   **插件不会自动回血**：战斗结束既不清状态也不回 HP/PP（`clear_battle_state` 只清 npc 字段），所以网页版补满是
   因为**网页自己请求了 heal**。客户端因此必须主动治，而且**每一种离开战斗页的方式**（结果框「确定」/返回键/逃跑）
   都要走到同一处治疗，否则队伍就留在受伤状态。`PokemonRepository` 现在会复用同一个客户端（按账号失效），
   `PokemonPage` 也会在**上层页面被 pop 回来时刷新队伍**，否则治好了界面还显示旧的。
7. **开战前不必先治疗**：`battle&action=start` 会在首发宠物不适合出战时拒绝，`BattleCubit.start` 收到该拒绝后
   自己治疗一次再重试（`retryAfterHeal`）。这样「再战」常见情况只需一个往返。
8. **容量**：背包与仓库**共用** `pm_usersdata.boxnum`，把宠物放进仓库不会腾出位置；错误文案要解释这一点
   （`tr.boxFullHint`）。
9. **技能**：只有 4 个槽，`pm_myskill` 没有"槽位"列，插件的 `learn_skill` 会忽略 `slot_index`，且遗忘要求该技能
   **PP 已满**。客户端因此走「先遗忘、再学习」的两步，并把英文报错映射成中文文案。
10. **`recover` 的 404**（`No active battle`）是正常结果（没有进行中的战斗），不要当错误弹给用户。
    冒险页会被反复进入（从战斗页返回、切 tab），而几秒之内不可能凭空多出一场战斗，所以 `AdventureCache`
    把这次「没有战斗」的答案记住 10 秒（`markNoBattle`/`battleCheckFresh`），期间再进不重复问；一旦开战
    （`invalidateBattleCheck`）就立刻作废，避免漏掉自己刚开的那场。
11. **图片**：大图走 CDN `https://img.tsdm39.com/Pokemon/{pm,pmb}/<id>.gif`；小图与道具图标走论坛
    `source/plugin/pokemon/images/{spm,item}/...`（X3 时代的 `pokemon_system/images` 路径只有部分子目录还在，
    不要用）。
12. **接口文案不稳定**：插件除登录外基本不给稳定 `code`，客户端只能按文案匹配（`pokemonMessageHint` 等）。
    新增匹配时集中写在 `utils/action_feedback.dart`，并按「同一判断只写一处」的原则办。

## 测试与覆盖率

宠物相关回归测试（`test/regression/`）：`test_176`（模型/图片 URL）、`test_177`（冒险/战斗模型）、
`test_178`（技能/装备/商店模型、错误文案、状态码文案与 `needsHealing`）、`test_179`（弹窗）、
`test_180`（假 Dio：客户端复用与换号重建、formhash 只读一次、`healParty` 的候选筛选与并发、从不返回的调用会超时）、
`test_181`（页面 cubit 生命周期、状态栏开关乐观更新与校正、道具动作的请求与刷新、传输失败后重读战斗）、
`test_182`（背包合并、随身/仓库计数、已结束战斗的记账与跨账号隔离）、
`test_183`（横屏自查：宠物中心 4 个 tab、冒险页、战斗页在 792×368 带挖孔的横屏下不溢出；`recover` 答案的时效）。

需要假网络时，用 `getIt.registerSingleton<NetClientProvider>(NetClientProvider.buildNoCookie(dio: …))` 装一个
带拦截器的 `Dio`（见 `test_180`/`test_181`），不要真发请求。

最近一次 `flutter test --coverage` 的宠物模块行覆盖率：

| 层 | 行覆盖率 |
| --- | --- |
| models | 97.8% |
| repository | 48.1% |
| cubit | 22.0% |
| utils | 44.9% |
| view（页面/部件） | 0.4% |
| **合计** | **22.6%**（全仓 53.5%） |

短板仍很明显：**页面层目前只覆盖到横屏布局**（`test_183` 会真的构建页面外壳、4 个 tab、冒险页与战斗页，
但只断言不溢出），详情页、装备页与各分支逻辑仍未被覆盖。补测试优先从这里下手（页面用 widget test，
纯函数直接测）。

## 尚未处理

- 首次进入宠物中心要等 5 个并行接口（网络往返 ~2.5-3s）**加首次图片下载**，图片是一次性的，接口可以再想
  （背包/商店 tab 可以懒加载，`config` 可以做会话缓存 —— 都只省带宽，不省首屏时间）。
- 插件侧问题（本项目已反馈）：见 `tsdm-pokemon-plugin-dev/APP_INTEGRATION_ISSUES.md`
  （`get_maps` N+1、容量口径、技能槽位、`defeat` 语义、请求头未文档化等）。
- 上游相关 PR：#60（本模块提交的接口字段修复）、#59（formhash 校验）。

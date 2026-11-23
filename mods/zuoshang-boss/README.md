# 左殇 Boss 替换 · PBZZuoShangBoss

版本 **0.1.3-preview** ｜ 适用 Windows Steam 版影之刃零（build 26367565）｜ 需要 PBZ 兼容版 UE4SS

在原 Boss 生成流程里把生成类别换成「左殇」：单阶段 Boss 用最终战二阶段「龙体左殇」，已列出的双阶段 Boss 第一阶段用「银发左殇」、第二阶段用「龙体左殇」，三面魔偶的三个分体各替换为一个龙体左殇。

**这是预览版。** 荆野已通过替换、攻击、击败奖励与自动保存实测；其它 Boss 还没有逐场完成战斗与结算验收。

## 它怎么替换

- 只处理 Boss，不处理普通杂兵；在原生成器内更换生成类别，保留各 Boss 原来的生成器与怪物组。
- 血量、基础攻击按原 Boss 配置和正常生成后的等级重新计算；招式倍率来自左殇本体。
- 掉落接口用原 Boss 的类别和等级，不另掷一遍掉落、不额外发奖。
- 不修改原角色死亡锁血值，也不用强杀原 Boss 来模拟转阶段。

## 安装

1. 完全退出游戏，完整解压本文件夹。
2. 在此文件夹打开 PowerShell：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
   ```

   默认游戏目录是 `E:\SteamLibrary\steamapps\common\PBZ`；不在那儿就传参数：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -GameRoot "D:\SteamLibrary\steamapps\common\PBZ"
   ```

3. 脚本会先复制并校验存档备份，再安装模组；每次安装都在当前文件夹下新建 `backups\install-<时间戳>\`。**以命令输出的本次备份路径为准**，不要拿早期测试存档覆盖后来的进度。
4. 启动游戏，在 `ue4ss\UE4SS.log` 里找 `[PBZZuoShangBoss 0.1.3-preview]`：`ready=true` 表示接口就绪。
5. 先挑可重复进入的战斗试。出现卡阶段就退出游戏并卸载。

安装前请确认 `platform\steam\Mods\PBZCoop` 不在：本预览只做单机测试，检测到它会直接报错停止。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

只移除模组文件夹并先留备份，不动游戏存档。需要回滚存档时，退出游戏后把对应备份里的 `SaveGames` 文件夹恢复到 `ProjectPBZ\Saved\SaveGames`。

## 文件

| 文件 | 职责 |
| --- | --- |
| `PBZZuoShangBoss\Scripts\main.lua` | 启动、图鉴 Boss 索引、状态维护 |
| `rules.lua` | Boss 阶段选择规则 |
| `engine.lua` | 原生成器替换与生成完成登记 |
| `state.lua` | 实例与生命周期登记（生成名额、回收、换代） |
| `stats.lua` | 按原配置映射等级 / 血量 / 攻击 |
| `loot.lua` | 已登记实例的掉落来源映射 |
| `world.lua` | 分区关卡的实际游戏世界归属 |
| `Install.ps1` / `Uninstall.ps1` | 安装 / 卸载，含存档备份与校验 |
| `COVERAGE.txt` | 同类问题排查与覆盖边界 |
| `VALIDATION.txt` | 实测日志与离线检查记录 |
| `SHA256SUMS.txt` | 发行文件的 SHA-256 |

## 0.1.3 修了什么

- 原生 `Despawn` 回收角色、旧 UObject 仍有效时，释放旧生成名额，保留旧角色的掉落来源，下一次生成继续按原 Boss 来源替换。
- 生成名额按实际生成器对象区分，避免显示 ID 相同的生成器互相阻挡。
- 旧角色尚未确认重新绑定时保留原掉落来源；确认新绑定后先隔离旧映射，核对双向绑定、控制器、同生成器、同原类、初始化与奖励元数据后才换代。拒绝换代时保持隔离，不沿用旧 Boss 的奖励来源。
- 迟到或无效的旧回调不再吞掉新的待生成请求。
- 一并适配铁狂的出场脚本、三面魔偶主体的出场与死亡标签脚本，原脚本完整保留。

## 覆盖范围

共用同一套 `BP_AISpawner` 生成流程、已有现场证据的 Boss：荆野（JingYe）、花千笑（HuaQianXiao_Seq027）、铁狂（LuanShi_Seq030）、白赤练与献祭之蛇（ChiLian_Seq034 / ChiLianP2_Seq035）、三面魔偶主体与三体（SanTouMoOu / YuCong_P3_1、2、3）、六绝凶镰（HookManP2_Seq023）、活人偶清道夫（Scavenger_Seq101）。

「使用同一生成器」不代表每个 Boss 都出过同样的故障，也不代表逐场战斗、阶段结束与奖励都验收过。

## 边界

- 已经生成的 Boss 不会被事后隐藏或销毁；要在触发战斗**之前**装好模组。
- 生成器若带尚未适配的专用 AI 覆盖或额外脚本，会保留原 Boss 并记录 skip。Boss 名称来自图鉴数据表，不是完整的关卡生成器清单。
- 三面魔偶的转阶段、三体结束判定、剧情与奖励未验证；其它 Boss 的完整战斗、死亡重试、换图和多周目流程未逐场验证。
- 原生掉落调用若绕过被挂钩的接口，掉落映射可能失效，需要正常击杀实测。
- 仅按单机开发，没有和 PBZCoop 联机做兼容验收。

更多细节见 [`COVERAGE.txt`](COVERAGE.txt) 与 [`VALIDATION.txt`](VALIDATION.txt)；发行包原始说明见 [`docs/zuoshang-boss-manual.zh-CN.txt`](../../docs/zuoshang-boss-manual.zh-CN.txt)。

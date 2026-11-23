# 影之刃零 · 模组合集

针对《影之刃零》（Phantom Blade Zero）Windows Steam 版的两个 [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua 模组。本仓库放源码、说明与验证记录；可直接安装的完整包在 [Releases](../../releases) 页。

| 模组 | 版本 | 作用 |
| --- | --- | --- |
| [道具名称与距离提示](mods/item-beacon) `PBZItemBeacon` | 1.9.0 | 在当前已加载范围内提示道具、宝箱、书页、碎片、未激活铃铛的名称 / 距离 / 高差；F5 面板筛选并锁定目标 |
| [左殇 Boss 替换](mods/zuoshang-boss) `PBZZuoShangBoss` | 0.1.3-preview | 在原生成器内把 Boss 换成「左殇」，沿用原 Boss 的等级、血量、基础攻击与掉落来源 |

两个模组都以只读查询为主：**不修改游戏存档、不自动拾取、不自动战斗、不代替玩家推进剧情**。所有改动只作用于本次运行,重启游戏后回到默认状态。

## 环境要求

| 项 | 要求 |
| --- | --- |
| 游戏 | Windows Steam 版影之刃零（道具提示基于 build 26266538，Boss 替换基于 build 26367565） |
| 加载器 | PBZ 适配版 UE4SS `v3.0.1-1195-g1ceefac8`，来自 [KintaroModding/ue4ss](https://github.com/KintaroModding/ue4ss/releases/tag/v3.0.1-1195-g1ceefac8) |
| 安装目录 | `<游戏目录>\platform\steam\ue4ss\Mods\` |
| 运行模式 | 单机。未与联机模组（如 PBZCoop）做过兼容验收 |

## 安装

### 道具名称与距离提示

**全新安装（还没有 UE4SS）** —— 从 [Releases](../../releases) 下载 `PBZItemBeacon-1.9.0-full.zip`：

1. 完全退出游戏，把压缩包解压到任意普通文件夹。
2. Steam 库中右键「影之刃零」→ 管理 → 浏览本地文件，进入游戏根目录（里面已有 `platform` 文件夹）。
3. 把包内的整个 `platform` 文件夹复制进游戏根目录，与原有 `platform` 合并。包内已配置好自动启用,不需要手改文件。
4. 从 Steam 正常启动游戏并载入存档，提示自动生效。

安装后应存在：

```
<游戏目录>\platform\steam\dwmapi.dll
<游戏目录>\platform\steam\ue4ss\UE4SS.dll
<游戏目录>\platform\steam\ue4ss\Mods\PBZItemBeacon\Scripts\main.lua
<游戏目录>\platform\steam\ue4ss\Mods\PBZItemBeacon\enabled.txt
```

**已有同一款 PBZ 适配版 UE4SS** —— 只把 `PBZItemBeacon` 文件夹复制到 `Mods\`，确认 `mods.txt` 里有 `PBZItemBeacon : 1`，并保证 `Mods\shared\UEHelpers\UEHelpers.lua` 存在。这种情况不要覆盖自己的 `mods.txt`、`UE4SS-settings.ini` 和加载器 DLL。

### 左殇 Boss 替换

1. 完全退出游戏,解压 [`PBZZuoShangBoss-0.1.3-preview.zip`](../../releases)。
2. 在解压出的文件夹里打开 PowerShell：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
   ```

   游戏不在默认位置时加参数：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -GameRoot "D:\SteamLibrary\steamapps\common\PBZ"
   ```

3. 安装脚本会先复制并校验存档备份，再装模组，不会更换现有 UE4SS。
4. 启动游戏，在 `ue4ss\UE4SS.log` 里找 `[PBZZuoShangBoss 0.1.3-preview]`，`ready=true` 表示接口就绪。**这不代表所有 Boss 都已通过实战验收。**

## 仓库结构

```
├── mods/
│   ├── item-beacon/         道具名称与距离提示（只有 Lua 源码）
│   │   ├── README.md        安装、按键、配置项
│   │   └── PBZItemBeacon/   复制到 Mods\ 的模组目录
│   └── zuoshang-boss/       左殇 Boss 替换
│       ├── README.md        安装、规则、覆盖范围
│       ├── Install.ps1 / Uninstall.ps1
│       ├── PBZZuoShangBoss/ 模组本体
│       ├── COVERAGE.txt     同类问题排查与覆盖范围
│       ├── VALIDATION.txt   实测与离线检查记录
│       └── SHA256SUMS.txt   发行文件校验值
├── docs/                    发行包内原始说明（逐字保留）
└── releases/                发行说明，见 Releases 页
```

本仓库**不含** UE4SS 加载器二进制（`UE4SS.dll`、`dwmapi.dll`）。需要开箱即用请下载 Releases 里的完整包；只要 Lua 源码请直接看 `mods/`。

## 已验证到什么程度

两个模组都按「已完成验证的范围」发布，**不代表全功能、全地图、全 Boss 已验收**。

- 道具提示 1.9.0：189 项离线回归（分类与名称 68、主逻辑 69、选择列表 27、铃铛 25）；2026-11-08 在溪谷已加载 240 米范围内对 59 个目标做只读新旧比较，含未知名称的目标由 1 个降至 0 个。未验收：敲铃 / 拾取后的消失流程、路线步行、原生菜单隐藏恢复、逐帧无闪烁。
- 左殇替换 0.1.3-preview：荆野（JingYe）已通过替换、攻击、击败奖励与自动保存实测；花千笑、铁狂、三面魔偶等仅完成配置适配或部分现场确认，**未逐场实战验收**。

细节见各模组 README 与 `VALIDATION.txt`。

## 已知风险

- 修改游戏运行时的模组，装前请备份存档；两个包都只玩单机。
- 世界地图、特殊跳跃 / 攀爬、锁门与机关处的通行不作保证。
- 与其它模组、联机模组、不同版本加载器的组合没有逐一验证。
- 游戏更新后模组可能需要适配；失效时先卸载再排错。

## 许可

- 本仓库的 Lua 脚本与 PowerShell 脚本：[MIT](LICENSE)。
- UE4SS 加载器：[MIT](https://github.com/UE4SS-RE/RE-UE4SS)，完整包内保留其原始 `LICENSE` 与版权声明。
- 《影之刃零》及游戏内名称、数据归 S-GAME / 灵游坊所有。本仓库不含游戏程序或存档资源。

非官方模组，与游戏开发及发行方无关。使用风险自负。

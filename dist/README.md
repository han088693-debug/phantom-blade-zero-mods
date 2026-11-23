# 发布包

这里放可以直接安装的完整包，内容与对应版本发布时一致，未重新打包。

| 文件 | 版本 | 大小 | 说明 |
| --- | --- | --- | --- |
| `PBZItemBeacon-1.9.0-full.zip` | 1.9.0 | 8.7 MB | 道具名称与距离提示完整包，含 PBZ 适配版 UE4SS `v3.0.1-1195-g1ceefac8` |
| `PBZZuoShangBoss-0.1.3-preview.zip` | 0.1.3-preview | 34 KB | 左殇 Boss 替换，含 `Install.ps1` / `Uninstall.ps1`，需要已有 PBZ 兼容版 UE4SS |

校验：

```powershell
Get-FileHash .\PBZItemBeacon-1.9.0-full.zip -Algorithm SHA256
```

或比对 `SHA256SUMS.txt`。

安装步骤见各模组 README。左侧 `mods/` 目录只有 Lua 源码，方便阅读和提 issue；实际安装请用这里的压缩包。

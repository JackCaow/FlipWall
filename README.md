# FlipWall

把 YouTube 的科技、AI 与数码封面变成 macOS 翻牌动态壁纸。两行之间是翻牌的铰链，上面一张向下揭开，再落到下面一格。

## 安装

1. 从 [GitHub Releases](https://github.com/JackCaow/FlipWall/releases/latest) 下载并解压 `FlipWall-macOS-arm64.zip`。
2. 双击 `FlipWall.app` 可在本次登录中运行。需要在登录后自动启动时，运行同目录的 `Install.command`。它安装菜单栏应用、用户级 LaunchAgent 和 FlipWall 屏保，需要 Python 3，无需管理员权限。
3. 首次运行需要联网访问 YouTube。FlipWall 会立即下载第一批封面，下载完成后自动显示。之后每小时刷新一次，离线时播放缓存。

适用于 Apple Silicon，桌面最低要求 macOS 13。安装包采用本地签名，macOS 可能要求在「系统设置 → 隐私与安全性」确认打开。已在 macOS 27.2 的双屏环境验证。

## 桌面

- 各屏拥有独立画面，共用翻牌节奏。菜单栏的「显示器」菜单可按屏开关、暂停以及调节亮度和卡片密度。
- 按住 Option（⌥）点击封面，在默认浏览器打开对应视频。
- 封面来自配置频道的 YouTube 公开订阅源。FlipWall 用近 45 天候选的日均播放量估算热度，在频道之间轮流取样，并按视频 ID 和图片内容去重。封面由应用下载并保存在本机。

## 屏保与锁屏

在「系统设置 → 墙纸 → 屏幕保护程序 → 自定义 → 其他」中选择 **FlipWall**。屏保共用桌面最新一批封面。

需要按 ⌃⌘Q 锁定 Mac 时也继续翻牌，可从菜单栏开启「动态锁屏（实验性）」。它适用于 macOS 14.2 及以上，使用未公开的墙纸配置，锁定时切换已选中 FlipWall 屏保的墙纸条目，解锁后恢复。系统升级可能影响此功能。

## 构建

安装 Xcode Command Line Tools，在仓库根目录执行以下命令。构建出的 `FlipWall.app` 和 `ScreenSaver/FlipWall.saver` 可直接用于安装。

```sh
./build.sh
./ScreenSaver/build.sh
```

可在独立目录拉取封面并运行桌面自检。

```sh
state_dir="$(mktemp -d)"
./FlipWall.app/Contents/MacOS/FlipWall --refresh-only --state-dir "$state_dir"
./FlipWall.app/Contents/MacOS/FlipWall --self-test --state-dir "$state_dir"
```

## 配置

菜单栏的「打开素材与频道配置」会打开 `~/Library/Application Support/FlipWall/`。在 `channels.json` 中编辑频道名和以 `UC` 开头的频道 ID，保存后可以立即更新。菜单可退出当前实例，`Uninstall.command` 可移除菜单栏应用和登录启动项。

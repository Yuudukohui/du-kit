# du-kit

给 Windows 上用 DSH（DeepSeek Harness）的人准备的几个小工具。都是我自己撞墙撞出来的，
写下来是因为不想再撞第二次。

## dsh/clean-cookies.py

DSH 桌面端每次启动都会在 Electron 的 cookie 库里留一条 `dsh-auth-<hash(host:port)>`，
30 天有效。端口每次启动都会变，于是这些条目会一直堆。攒到大约 70 条时，请求头会超过上限，
启动报 `desktop welcome: Web authentication failed`（HTTP 431）。

这个脚本只删 `dsh-auth-*` 开头的行，别的 cookie 不碰。

```powershell
python clean-cookies.py --check        # 只看有多少条、离 431 还有多远
python clean-cookies.py --clean        # 删过期的
python clean-cookies.py --clean --all  # 全删（要重新登录一次，无其他损失）
```

**必须在 DSH 完全退出后运行**：客户端开着时，cookie 库被 Chromium 独占，打不开。

## windows/capture-window.ps1

抓一个窗口的画面——**包括被别的窗口挡住的窗口**。用来截图给 AI 看，或者给自己留证据。

```powershell
powershell -File capture-window.ps1                        # 前台窗口
powershell -File capture-window.ps1 -Title "记事本"          # 按标题找
powershell -File capture-window.ps1 -Title "游戏" -NoFront   # 不抢焦点
```

三个坑已经修在里面，写在这里免得你以为脚本坏了：

1. **窗口被挡住就截成黑的** → 用 `PrintWindow` 加 `PW_RENDERFULLCONTENT`（flag 2），
   DirectX 窗口在后台也能抓，不用抢焦点。
2. **抓到了却只有左上角一块** → 是 **DPI**。系统缩放 175% 时，`GetWindowRect` 给你的是
   逻辑尺寸（1463×823），程序实际画的是 2560×1440。脚本里先声明
   `SetProcessDpiAwareness(2)`，再取尺寸就对了。
3. **抓错窗口** → 模糊匹配会先命中同标题的前台程序，用足够具体的标题。

脚本会算“接近纯黑的像素占比”，超过 90% 就自动改成“前置窗口 + 屏幕抓取”，
并明确告诉你这次没抓到——不会把黑图当正常画面交上去。

## License

MIT

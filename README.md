# Fab 限时免费领取助手

自动领取 [fab.com](https://www.fab.com/) 上轮换的「限时免费」素材资产。

这些资产平时收费，Epic 每隔约两周挑 3 个做 100% 折扣限免，过了截止时间就恢复
原价、再也领不到了。手动盯着太累，这个程序替你盯。

## 它做什么

- **一键领取**当前批次的所有限免资产，已拥有的自动跳过
- **自动领取**：注册一个 Windows 计划任务，记住本批截止时间（那也正是下一批上线
  的时间），平时只在后台问一句「到点了没」——没到点立刻退出，不启动浏览器、不弹窗。
  正常情况下平均每两周才真正动作一次，其余日子零打扰
- **开机自动检查**（可选）：电脑经常在计划任务那个点没开的话，勾上它，开机后补一次检查
- 登录状态每 5 秒自动检测，登录成功会自己继续，不需要点任何按钮

## 快速开始

1. 下载整个文件夹（或 Release 包）
2. 双击 `Fab领取助手.exe`
3. 第一次会弹出一个浏览器窗口，在里面登录一次 Epic 账号即可，以后自动记住

详细说明见 [`使用说明.txt`](使用说明.txt)——那是给使用者看的，写得比较细。

> 如果双击 exe 没反应，或被 Windows SmartScreen / 杀毒软件拦下：
> 本程序没有数字签名（个人项目），点「更多信息」→「仍要运行」即可。
> 实在不行双击 `core\备用启动.bat`，效果一样。

## 从源码运行

仓库里已经带了 `core/node.exe` 和 `node_modules`，clone 下来就能直接跑，不需要装任何东西。

```
git clone https://github.com/Ker0el/fab-claimer.git
cd fab-claimer
core\备用启动.bat
```

## 目录结构

```
Fab领取助手.exe        瘦启动器，只负责拉起 core\gui.ps1
使用说明.txt           给使用者看的完整说明
core\                  程序本体
  node.exe             自带运行时（Node.js v24，免安装）
  gui.ps1              界面（WinForms）
  browser.ps1          浏览器定位 / 启动 / 验证
  claim.mjs            领取逻辑（Playwright 驱动 CDP）
  whoami.mjs           登录状态检测
  open-login.mjs       打开 Epic 登录页
  auto-claim.cmd       计划任务入口
  备用启动.bat          exe 被拦截时的备用入口
profile\               浏览器配置，登录态存这里（**不会进仓库**，见下）
logs\                  运行日志
```

## 几个实现上的选择

**浏览器检测为什么不是简单扫一遍常见安装路径。**
路径枚举本质是白名单，永远会漏——绿色版、非标准目录、国产壳浏览器都扫不到。
`browser.ps1` 的候选来源是：手动指定 → 上次成功用过的 → 常见位置 → 系统记录的
默认浏览器 → **注册表卸载表**（品牌和位置无关）→ PATH。而最终判据不是文件名，
而是**真的启动一次、确认它能开出 Chromium 的 CDP 端口**——找十个像浏览器的
文件，不如确认一个真能用的。

**为什么必须用独立浏览器配置。**
Chrome/Edge 从 136 版起禁止对「日常使用的配置」开放调试接口（防止恶意程序偷
Cookie）。本程序需要这个接口来模拟真人点击——Epic 结账有机器人检测，普通脚本
点不动——所以只能用一个独立配置，也就是 `profile\`。

**为什么用 `connectOverCDP` 而不是 `chromium.launch()`。**
以普通方式启动浏览器（只有 `--remote-debugging-port` 和独立 profile），
不经过 Playwright 的 `launch()`，就不会带上 `--enable-automation`，
`navigator.webdriver` 保持 `false`——这是最容易被识别的自动化指纹。

## 安全：`profile\` 绝对不能提交

`profile\` 里是你**真实的登录凭据**（`Default\Login Data`、`Default\Web Data`、
`Default\Network\Cookies`）。它已在 `.gitignore` 里排除。

如果你 fork 这个项目并打算提交自己的版本，**务必确认 `profile\` 没有被 `git add` 进去**。
一旦推到公开仓库，任何人都能拿着这份登录态登进你的 Epic 账号。

## 免责声明

- 本程序会**自动化操作你的 Epic 账号**。Epic 的服务条款通常不鼓励账号自动化，
  存在理论上的账号风险，请自行判断是否使用。
- 仅供个人学习和自用。因使用本程序导致的账号封禁、资产丢失或其它任何后果，
  作者不承担责任。
- 与 Epic Games、Fab.com 无任何关联，未获其授权或认可。
- 程序不含任何浏览器二进制，只在运行时调用你自己机器上已安装的浏览器。

## 许可证

[MIT](LICENSE)。第三方组件（Node.js、Playwright Core）的许可证见
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

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
- **自动更新**：启动时后台查一次 GitHub，有新版本就在界面上提示，点一下就能更新并自动重启
- 登录状态每 5 秒自动检测，登录成功会自己继续，不需要点任何按钮

## 快速开始

**方式一：装安装包（推荐）**

1. 从[仓库](https://github.com/Ker0el/fab-claimer)或 Release 下载 `FabClaimer-Setup-x.y.z.exe`
2. 双击安装（**不需要管理员权限**），装完自动启动
3. 第一次会弹出一个浏览器窗口，在里面登录一次 Epic 账号即可，以后自动记住

装到 `%LOCALAPPDATA%\Programs\FabClaimer`，卸载走「设置 → 应用」，
卸载时会问你要不要连登录状态一起删。

**方式二：直接用免安装版**

1. 下载整个文件夹（或 clone 仓库）
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
version.json           当前版本号 + 可更新的文件清单（自动更新用）
core\                  程序本体
  node.exe             自带运行时（Node.js v24，免安装）
  gui.ps1              界面（WinForms）
  browser.ps1          浏览器定位 / 启动 / 验证
  claim.mjs            领取逻辑（Playwright 驱动 CDP）
  whoami.mjs           登录状态检测
  open-login.mjs       打开 Epic 登录页
  update.mjs           自动更新：查版本 / 下载 / 替换并重启
  auto-claim.cmd       计划任务入口
  备用启动.bat          exe 被拦截时的备用入口
profile\               浏览器配置，登录态存这里（**不会进仓库**，见下）
logs\                  运行日志
installer\             打包成安装程序（开发用，不影响运行）
  build.ps1            构建入口：挑文件 → 自检 → 调 ISCC
  fab-claimer.iss      Inno Setup 脚本
```

## 打包安装程序

```
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

产物在 `installer\Output\FabClaimer-Setup-<版本>.exe`，约 26 MB（未压缩约 102 MB，
大头是 `node.exe`）。需要本机装了 [Inno Setup 6](https://jrsoftware.org/isinfo.php)。

**这个脚本存在的唯一理由是防一件事：把 `profile\` 打进安装包。**
那是真实 Epic 登录凭据（216 MB），和"绝不能进公开仓库"是同一件事，
而且安装包发出去撤不回来。所以它不依赖 Inno 的 `Excludes`（写错一个字不报错，
只会安静地打进去），而是：

1. **白名单复制**到 `_stage\` —— 根目录的文件一个个点名，不写"除了这些全都发"
2. **自己数一遍**：`profile\`、`logs\`、`settings.json`、`cdp-port.txt` 任何一个
   出现就直接失败；还会全树搜 `Cookies` / `Login Data` / `Web Data` 这类文件名
3. `.iss` 里还有一道**编译期硬闸**（ISPP `#error`）兜底，改坏排除规则也拦得住

装到 `%LOCALAPPDATA%\Programs` 而不是 Program Files，是必须的而不是偏好：程序把
`profile\`、日志、领取记录都写在**程序目录旁边**，装到 Program Files 不可写，
Chrome 存不下登录态；而且自动更新要往 `core\` 里写文件，那需要管理员权限，
后台更新弹不出提权框，等于永远更新不了。

## 自动更新

启动时后台问一次 GitHub：「`main` 分支上的 `version.json` 比我新吗？」
有新版本就在黄色提示条上问一句，**点了才下载**（不做静默自动更新）。
下载全部成功之后才动现有文件，而且由独立进程在界面退出之后才覆盖、再重启界面——
绝不留下「半个新版本 + 半个旧版本」的状态。

版本号放在仓库根目录的 `version.json`，发新版时改 `version` 和 `notes` 即可，不需要
另外打 Release 包：

```json
{ "version": "1.0.1", "notes": "修了什么", "files": ["core/gui.ps1", "..."] }
```

更新哪些文件由 `files` 清单指定，客户端还会再过一道白名单（`core/update.mjs`
里的 `ALLOW`）。**`profile\`、`logs\`、`settings.json`、`claimed.json`、
`node.exe`、`node_modules\` 永远不在白名单里**——这是防事故的规则，不是防入侵的：
能把仓库改掉的人本来就能改 `claim.mjs` 去读你的 `profile\`，程序内部挡不住。

两个已知限制：国内直连 `raw.githubusercontent.com` 可能不通，不通时静默跳过
（界面右下角有「检查更新」按钮可以手动重试并看到失败原因）；只有打开界面的用户
才会收到更新提示，只用计划任务、从不打开界面的用户不会自动升级。

发版时注意两件事（都是实测踩出来的）：

- **push 完等一两分钟再告诉别人。** GitHub 的 raw CDN 有传播延迟，刚 push 的
  文件可能还是 404 或者旧的。更新器会校验暂存下来的 `version.json` 版本号对不对，
  对不上就整轮作废重来 —— 不会留下「版本号是新的、代码是旧的」这种再也修不回来的状态。
- **行尾要自己补。** raw 接口给的是仓库 blob 原样字节（LF），不会做 git checkout
  时的行尾转换。而 `.gitattributes` 要求 `.cmd`/`.bat`/`.ps1` 是 CRLF（批处理是 LF
  会直接坏掉），所以 `core/update.mjs` 里有个 `normalizeEol()` 按同样的规则补回来。

## 几个实现上的选择

**浏览器检测为什么不是简单扫一遍常见安装路径。**
路径枚举本质是白名单，永远会漏——绿色版、非标准目录、国产壳浏览器都扫不到。
`browser.ps1` 的候选来源是：手动指定 → 上次成功用过的 → 常见位置 → 系统记录的
默认浏览器 → **注册表卸载表**（品牌和位置无关）→ PATH。而最终判据不是文件名，
而是**真的启动一次、确认它能开出 Chromium 的 CDP 端口**——找十个像浏览器的
文件，不如确认一个真能用的。

**为什么复用端口上的浏览器之前还要再确认一次。**
「端口上有个 Chromium」不等于「这个能用」。实测踩过：另一个工具在本机开了一个
**无头** Chrome 占着 9222，本程序直接接了上去，症状是「没有窗口 + 未登录 +
被 Cloudflare 拦」——三条全都没指向真正的原因。所以复用前还要过两道：
不是 `HeadlessChrome`（无头没有窗口，用户没法登录、也没法过人机验证），
且 `settings.json` 里的 `cdpPid` 还活着（确认是自己启动的那个）。不满足就换个
端口重开，不去动别人的浏览器。

**为什么必须用独立浏览器配置。**
Chrome/Edge 从 136 版起禁止对「日常使用的配置」开放调试接口（防止恶意程序偷
Cookie），而本程序要靠这个接口来驱动浏览器完成领取流程，所以只能用一个独立
配置，也就是 `profile\`。

**为什么用 `connectOverCDP` 而不是 `chromium.launch()`。**
程序以标准方式启动浏览器（只带 `--remote-debugging-port` 和独立 profile），
再用 CDP 接上去，而不是走 Playwright 的 `launch()`。这样跑的就是你机器上
原本那个浏览器，不需要额外下载一份浏览器二进制。

## 安全：`profile\` 绝对不能提交

`profile\` 里是你**真实的登录凭据**（`Default\Login Data`、`Default\Web Data`、
`Default\Network\Cookies`）。它已在 `.gitignore` 里排除。

如果你 fork 这个项目并打算提交自己的版本，**务必确认 `profile\` 没有被 `git add` 进去**。
一旦推到公开仓库，任何人都能拿着这份登录态登进你的 Epic 账号。

## 免责声明

- 本程序会**自动化操作你的 Epic 账号**。Epic 的服务条款通常不鼓励账号自动化，
  账号存在被限制或封禁的风险，请自行判断是否使用。
- 仅供个人学习和自用。因使用本程序导致的账号封禁、资产丢失或其它任何后果，
  作者不承担责任。
- 与 Epic Games、Fab.com 无任何关联，未获其授权或认可。
- 程序不含任何浏览器二进制，只在运行时调用你自己机器上已安装的浏览器。

## 许可证

[MIT](LICENSE)。第三方组件（Node.js、Playwright Core）的许可证见
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

# 信息屏应用商店 / Info screen app store

荣悦 E5 OpenWrt 信息屏（[e5-infoscreen](https://github.com/Enceka/infoscreen)）的应用商店。
屏幕上：高级 → 应用管理 → 应用商店。每次推送到 `main`，CI 检查所有应用，打包后发布到
GitHub Pages（`https://enceka.github.io/infoscreen-plugins/index.json`），设备从那里读取。

The app store of the E5 OpenWrt info screen.  On the screen: 高级 -> 应用管理 -> 应用商店.  Each push to
`main` checks every app, packs them and publishes the store on GitHub Pages, where the devices read it.

## 网页商店 / Web storefront

打开 [应用商店](https://enceka.github.io/infoscreen-plugins/) 浏览、搜索和下载应用，
查看安装方法；页面支持中文和英文、手机和桌面。网页从 `index.json` 读取实际应用列表，
设备也继续使用这个索引。前端源码位于 `site/`，无需 Node.js 或额外构建依赖。

本地预览：运行 `python3 tools/build.py`，然后 `python3 -m http.server 8000 --directory dist`，
打开 `http://localhost:8000`。现有 Pages 工作流会同时发布网页、索引和应用包。

Browse, search and download apps at the [web storefront](https://enceka.github.io/infoscreen-plugins/).
The responsive Chinese/English site reads the same `index.json` as the devices. Source lives in `site/`;
no Node.js build is needed. Run `python3 tools/build.py`, then
`python3 -m http.server 8000 --directory dist` to preview at `http://localhost:8000`.

### 访问与下载统计 / Visit and download counters

网页通过[不蒜子公开 API](https://github.com/soxft/busuanzi/wiki/API)保存累计计数：
页脚显示商店访问次数，应用卡片和详情显示各应用的**网页下载点击次数**，同一个应用的
不同版本合并计算。数据从接入时开始累计，没有历史访问记录回填；不包含设备商店下载、
直接访问包链接，也不能代表文件下载完成。刷新、搜索、筛选和切换语言只读取下载计数。

统计使用独立的页面计数键（商店首页与 `__stats__/downloads/<id>`），不会把下载点击
加到商店访问次数中。统计请求不发送 Cookie 或个人标识，不加载第三方脚本；服务仍会
接收到发起请求的 IP 地址。计数服务不可用时显示 `—`，下载链接继续正常工作。
构建会把部署地址写入页面；只有从这个地址打开的正式网站才会记录事件，本地预览不计数。

The footer shows store page views; app cards and details show **website download-button clicks**,
combined across versions. Counters start when enabled, with no historical backfill. Device-store and
direct-package downloads are excluded, and clicks do not confirm completed downloads. The Busuanzi API
stores the counts; previews do not send production events. Statistics failures never block downloads.

## 提交一个应用 / Adding an app

1. `plugins/<id>/`：`manifest.json`、页面（默认 `index.html`），需要后台时加 `backend.uc`。
   接口见 e5-infoscreen 的 [docs/API.md](https://github.com/Enceka/infoscreen/blob/main/docs/API.md)
   第 5 节；`plugins/bigclock` 是个最小的例子。
2. 本地检查：`python3 tools/check.py`，打包试试：`python3 tools/build.py`（生成 `dist/`）。
3. 提 Pull Request；CI 通过、审阅之后合并，下一次发布就上架了。改版本时提高 `version`，
   屏幕据此显示“更新”。

## 规则 / The rules (tools/check.py)

* **manifest**：`id` 与目录名相同（小写字母、数字、`-`、`_`，最多 32 个字符）；`api_version`
  是屏幕支持的（目前 2，兼容 1）；`version` 是点分数字；`name` 和 `description` 都要有 `zh` 和 `en`；
  `entry` 是应用里的文件；设置项的 `uci` 用 `e5-plugin-<id>.<section>.<option>`。
  输入法应用可设置 `input_method: true`，通过 API 2 的 `e5.input()` 向宿主当前输入框提交文字。
* **文件**：只允许 html、js、css、json、uc、svg、txt、md 和常见图片、woff2；没有隐藏文件、
  没有链接；整个应用不超过 2 MB。
* **风格**：UTF-8，LF 换行，文件以换行结尾，行尾没有空格。
* **安全**：前端不加载别的主机的脚本和样式，不直接请求外网（需要时通过后台），不用
  `eval`、`new Function`、`document.write`、带字符串的 `setTimeout`。
* **后台**（`backend.uc`）以 root 运行：检查会列出它执行命令、写删文件、发 AT 指令、改 uci
  的地方，审阅时逐条看过才合并。商店里标明“含后台”。

## 发布 / Deployment

仓库 Settings → Pages → Source 选择 **GitHub Actions**。商店需要工作流生成的
`dist/index.json` 和应用包；选择从 `main` 根目录部署只会发布源码，无法生成商店索引。
如果首次工作流运行时 Pages 尚未开启，配置好后在 Actions → store 重跑失败任务，
或使用 **Run workflow**（main 分支）。工作流先读取 Pages 配置，再使用其实际站点地址打包。

检查结果：`https://enceka.github.io/infoscreen-plugins/index.json` 应返回 JSON，
其中每个应用的 `url` 都应能下载到对应包。CI 成功后再从设备刷新商店。

Set Settings → Pages → Source to **GitHub Actions**. The store needs the
workflow-generated `dist/index.json` and packages, rather than a deployment
of the source branch. If the first run failed before Pages was enabled, rerun
the failed job or use **Run workflow** on main. The build uses the configured
Pages base URL. Check both the public index and its package URLs before
refreshing the store on a device.

## 许可 / License

MIT（见 `LICENSE`）；每个应用可在自己的目录里另附许可。

## 电话应用

`plugins/phone/` 是独立更新的电话应用，当前版本为 `1.4`。需要信息屏 1.5.1（API 2）及
OpenWrt 的 `e5-voice-audio` 音频服务。核心负责通用通知展示，插件负责拨号、
接听、挂断、通讯录和铃声/震动/亮屏设置；声音和震动由后台服务执行，
关闭电话页面后仍可提醒。设置位置：高级 → 应用管理 → 电话 → 设置。
铃声音量跟随信息屏的“声音”设置；音量为零时仍可使用震动。

应用包通过 `python3 tools/build.py` 生成到 `dist/packages/phone-1.4.tar.gz`，
可用 `/usr/libexec/e5-infoscreen/plugin install FILE` 安装，后续通过应用商店更新。
当前短信/通话仍使用系统选择的 SIM，双卡同时接收和每次选卡需要底层双卡
事件/端口支持，尚未按 Android 的双卡待机方式实现。电话数字盘的方向键按屏幕网格
移动：上下沿列，左右沿行；实体拨号键以独立的 `kind: "call"` 事件提供给应用。

Phone 1.5 supports per-call SIM selection and source labels with the E5
ModemManager r917 dual-voice adapter. The selected data SIM remains independent.

SIM2 下行与来电提醒已实测；SIM2 麦克风上行、来电接听音频和 30 秒持续通话尚未验证。
选卡不会切换上网卡；已有通话时不会自动挂机或重拨。

设备适配中的电话界面与共享传输改动已合入 `plugins/phone`，来源和依赖见 [迁移说明](docs/DEVICE-INTEGRATION.md)。

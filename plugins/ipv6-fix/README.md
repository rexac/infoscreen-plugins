# IPv6 RA 路由修复 / IPv6 RA route repair

将工作区 `ipv6-fix/IPv6 RA路由修复.js` 的 RA 续期功能改写为 infoscreen API 2 插件。
适配 OpenWrt E5，界面与后台不依赖 Android/UFI-TOOLS。来源目录中的 `rdisc6` 是
aarch64 Linux musl 静态 PIE 程序，已在 OpenWrt E5 上验证可执行。
插件 1.1 起直接内置这份预编译程序（`bin/rdisc6`，权限 0755），安装即用。
仓库检查仅对此固定路径和 SHA-256 设置例外，不放开其他原生程序。

安装生成的 `ipv6-fix-1.11.tar.gz`，打开应用即可使用。需要 OpenWrt 的 `flock`、
支持 IPv6 route expires 的完整 iproute2，以及 ucode 的 fs/uci 模块。
aarch64 主机优先使用插件内置的 `bin/rdisc6`，其他架构回退查找系统 `PATH`。

## 与原插件对应的功能

- 状态卡显示运营商、活动数据口、IPv6 ping 连通性、调度状态/间隔、rdisc6 状态、
  上次成功刷新策略和当前默认路由。
- 剩余有效期读取内核路由 expires，按秒倒计时；进度条分母使用本接口、同网关
  最近收到且尚未失效的 RA Router Lifetime。未收到 RA 时不猜测百分比。
  静态路由无倒计时，不作为连通性正常的依据。
- 立即刷新：请求真实 RA，保留内核已按该 RA 完成的续期；若 OpenWrt 没有自动
  安装/续期，则按本次 RA 的网关、有效期及 preference 写入带 expires 的路由。
  已有路由保留原表、metric 和 hoplimit；静态路由同样检查和刷新。
  续期不先删除路由；没有有效 RA 时保留现有路由并报告失败，不人为延长期限。
  路由写入后读回校验，并执行 IPv6 ping；ping 不通则不报告修复成功。
- 删除当前路由：两秒内连续三次确认才提交，后台也要求明确的删除确认值。
  根据活动 WAN、网关、表和 metric 精确删除；多路由或源特定路由会跳过。
- 启动/停止调度，间隔提供原版的 5/15/30 分钟和 1/2/6 小时选择，配置保存在
  `e5-plugin-ipv6-fix.settings.interval`，也保留宿主应用设置入口。
- 日志刷新/清空；每 2 秒自动刷新日志，每 5 秒刷新状态，最多显示最后 40 行并自动滚动。
  历史失败记录会保留用于排查，不代表当前故障。

按用户要求不提供开机启动和依赖管理。脚本安装/更新和卸载由信息屏应用管理处理，
无需在插件内再次安装一套 Android 脚本。中文应用名与页面标题为“IPv6 路由修复”，
宿主顶部栏 `short_name` 为“路由修复”（需要宿主支持）。

## OpenWrt 适配

从 netifd 的 `network.interface.wan` 选择活动的 `sipa_ethN`，从信息屏 ModemManager
状态读取运营商，替代 Android getprop。不对运营商做 Android 属性字符串白名单判断。
不猜测 `fe80::2`；缺失默认路由时只根据本次收到的有效 RA，在 main 表以
metric 1024 创建带真实 expires 的默认路由。不改变内核 accept_ra 设置。
Router Lifetime 为零或缺失 sender 时不续期；无有效 RA 报告 `no_ra`。

调度使用本次开机期间的独立 `scheduler.uc` 进程，不创建 cron 或开机服务。
启动后每 5 秒判断是否到期；所选间隔从上次运行时间计算，修改配置后无需重启。
剩余有效期不足 RA lifetime 的 20%（提前量下限 120 秒、上限 300 秒）时提前续期。
健康探测最多每分钟一次；失败每 60 秒重试。页面显示下次计划刷新倒计时，日志记录
自动触发的原因、配置间隔、距上次运行秒数及剩余 RA 时间。

仅当 `/tmp/e5-ipv6-fix/schedule` 存在时运行，关闭页面后继续，重启后停止。
停止后调度进程约一秒退出；正在执行的修复任务会先完成。独占 scheduler.lock 避免
重复调度进程，worker 的 flock 继续串行化手动与自动修复。
升级旧版后重新应用调度状态，会只移除 `# e5-ipv6-fix` 标记的旧 cron 行，保留其他任务。
日志和结果在 `/tmp/e5-ipv6-fix`，重启清空；不提供开机启动或依赖管理。
卸载前停止调度；直接卸载后调度进程会检查 worker 存在性并退出。

内置 `bin/rdisc6` 随插件更新和卸载，不写入 `/usr/bin`。卸载前停止调度；
直接卸载时调度进程检查 worker 存在性并退出，重启后运行标记也会消失。

触屏可操作全部按钮；方向键上下选择控件，确认键执行，间隔弹层支持方向键选择、确认键保存与返回键取消；
日志区用上下滚动、左右移出，返回键退出。支持中文和英文。

验证：`python3 tools/check.py`、`python3 tools/build.py`、
`python3 tests/native-package.py`、`node tests/ipv6-view.cjs`，设备上运行
`ucode tests/ipv6-fix.uc plugins/ipv6-fix/worker.uc` 和
`ucode tests/ipv6-controls.uc plugins/ipv6-fix/backend.uc`。
后台以 root 运行；请求值严格校验，所有 shell 参数采用固定命令或引用转义。

## 静态编译 rdisc6 1.0.8

在 Linux 编译主机运行（musl.cc 工具链本身不能直接在 macOS 上执行）：

```sh
wget https://musl.cc/aarch64-linux-musl-cross.tgz
tar xf aarch64-linux-musl-cross.tgz
export PATH="$PWD/aarch64-linux-musl-cross/bin:$PATH"
wget https://www.remlab.net/files/ndisc6/ndisc6-1.0.8.tar.bz2
tar xf ndisc6-1.0.8.tar.bz2
cd ndisc6-1.0.8
./configure --host=aarch64-linux-musl CC=aarch64-linux-musl-gcc LDFLAGS="-static"
make
find . -type f -name rdisc6 -exec file {} \;
```

当前包使用用户提供的预编译文件原样副本，不是本次重新编译的产物。
若替换 `bin/rdisc6`，须设权限为 `0755`，验证 E5 兼容性，并同步更新
`UPSTREAM.json` 和 `tools/check.py` 中的 SHA-256。

随包提供官方 `sources/ndisc6-1.0.8.tar.bz2`、上游 `COPYING.ndisc6.txt` 和
`UPSTREAM.json` 中的来源、版本、构建参数与校验值。rdisc6 按上游 GPL 条款分发，
不适用仓库默认的 MIT 许可；静态链接的 musl 版权声明见 `COPYING.musl.txt`。
原始源码和配置脚本保存在源码压缩包中；上面的命令记录了原作者提供的交叉编译方法。

## E5 实测（2026-10-16）

本地依赖文件 SHA-256：
`db1c09c77f9aa98d92fc0bc95070019d6da0698bf44666726c1d46eec0125838`。
`file` 检查为 ELF64 aarch64 static PIE；设备 `--version` 返回 ndisc6 1.0.8，
构建参数包含 `--host=aarch64-linux-musl` 和 `LDFLAGS=-static`。

临时上传后运行 `rdisc6 -1 -n -r 2 -w 3000 sipa_eth0`，退出码为 0，
收到 `fe80::1` 的 RA：Router Lifetime 为 3600 秒，前缀为
`2408:844b:4230:733::/64`。最初测试使用临时文件；1.1 起通过插件包自带此依赖。

当时接口 `forwarding=1`、`accept_ra=0`、`accept_ra_defrtr=1`。
紧接 RS 的路由快照尚未显示默认路由；用户随后反馈 IPv6 已恢复，复查确认出现：

```text
default via fe80::1 dev sipa_eth0 proto static metric 512 pref medium
```

向 `2400:3200::1` 的 3 次 IPv6 ping 全部成功，丢包率 0%。
`accept_ra=0` 不能作为整体 RA 处理失败的依据，OpenWrt 用户态仍可能处理 RA；
具体由哪个服务安装该静态路由尚未追踪。插件也将 RS 后出现的无有效期默认路由
识别为可用，保留其原有属性；状态为 `route_available`，不强行改写成 `proto ra`。
本次复查确认的是 E5 主机出网，未单独测试 LAN 客户端。


1.6 修复“删除后刷新提示未找到默认路由”：实测 RA 可达但内核未自动安装路由。
插件从本次 RA 的 `fe80::1` 恢复 `main` 表默认路由，读回为
`proto ra metric 1024 expires 65534sec pref medium`，策略为 `ra_discovered`。
通过页面同一 `/refresh` 接口验证，IPv6 ping 3/3 成功、丢包率 0%。
隔离测试覆盖有效 RA 恢复、零 lifetime、缺失 sender 和非链路本地 sender。


1.7 取代 1.6 的固定 65535 秒策略：路由 expires 和进度条均依据实际 RA，
每次刷新均验证 IPv6 ping，静态路由不会直接报告无需处理。隔离测试覆盖
RA 3600/1800 秒、静态路由转换、无 RA 保留、失联检查及到期前自动续期。

1.7 E5 实测：通过页面 `/refresh` 接口收到 lifetime 3600 秒，路由读回
`expires 3599sec`，随后按真实时间递减；`ra_lifetime` 返回 3600，ping 3/3 成功。
现有 3600 秒调度保持启用，健康且剩余有效期充足时 auto 检查不会重复写路由。
提前续期通过隔离测试验证；本轮未等待完整一小时，不能据此宣称长期掉线已解决。

1.9 将最长刷新间隔的原生 select 改为页面内深色弹层，统一选项、选中状态和取消按钮配色；支持触屏、方向键、确认、返回及 Tab 焦点限制。

1.10 移除每分钟 cron，改为运行期调度；增加下次刷新倒计时与调度原因日志。

1.11 修复 BusyBox flock 不支持 -w 导致日志清空一直失败，改用 timeout 限制等待；
清空成功后立即清理页面日志，丢弃清空前发出的状态/日志请求，防止旧内容回填。

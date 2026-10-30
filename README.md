# 在 Windows 11 沙盒（Windows Sandbox）中编译 OpenResty 1.31.8.1 x64

本文档描述如何在一台 **Windows 11** 主机上，用一次性 **Windows Sandbox** 会话编译出
OpenResty **1.31.8.1（nginx core 1.31.8 / OpenSSL 3.5.9 / LuaJIT 2.1-20261023）** 的
Windows 64 位原生版本。

---

## 0. 先明确一件事：官方没有 Windows 二进制包

- [下载页](https://openresty.org/en/download.html) 只提供 Linux 包（apt/dnf/apk）、Docker 镜像、Homebrew 和源码 `openresty-1.31.8.1.tar.gz`。
- OpenResty 历史上最后一个官方 Windows 二进制是 `openresty-1.9.15.1-win32.zip`（2016 年，32 位）。
  `doc/README-windows.md` 里“官网提供 Win32/Win64 二进制”的说法已经过期。
- Windows 版 nginx 端口本身的功能限制（编译产物也逃不掉）：
  - 只有 `select()` 事件模型，**没有 IOCP**；
  - 单 worker、`FD_SETSIZE=1024`（即并发连接上限 ~1024）；
  - 官方明确说：**仅用于本地开发，不要用于生产**。
  
  要在 Windows 上跑生产级 OpenResty，正确做法是 WSL2 + 官方 Linux 包，或 Docker。

所以下面编译出来的是一个**可用于开发/调试的原生 exe**，不是生产件。

---

## 1. 前提条件

| 项目 | 要求 |
|---|---|
| 版本 | Windows 11 **专业版 / 企业版 / 教育版**（家庭版没有 Sandbox） |
| 虚拟化 | BIOS/UEFI 开启 VT-x/AMD-V；`任务管理器 → 性能 → 虚拟化：已启用` |
| 功能 | 可选功能里勾选 **Windows 沙盒**（`Windows Sandbox`），需重启 |
| 磁盘/内存 | 沙盒内约需 6–8 GB 临时空间；建议给沙盒 8 GB 内存 |
| CPU | 建议 4 核以上（`-j` 并行编译；OpenSSL 是耗时大头） |

开启沙盒（管理员 PowerShell，**只在新机器上做一次**，沙盒内部不用做）：

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -All
```

---

## 2. 为什么放在沙盒里编译

好处：

- 污染隔离：MSYS2、`pacman` 装的 100+ 个包、几 GB 中间产物全部随会话丢弃，主机不留垃圾；
- 可复现：每次从同一个 MSYS2 基线 + 同一份脚本开始，不受主机已有工具链干扰；
- 映射目录只暴露一个文件夹给 VM。

代价（重要）：

- **沙盒无持久化**：关掉窗口 = 全丢。MSYS2 约 3–5 分钟需要**每次重建**；
- 编译本身约 **15–40 分钟**（取决于核数），期间**不要关窗口**；
- 映射目录默认只读，本方案里显式设为可写，产物直接落回主机。

> 如果只是偶尔编一次：按下面流程走完，把 `dist\openresty-1.31.8.1-win64.zip` 留在主机上即可。
> 如果要反复编多次：改用 Hyper-V 虚拟机 / 持久化 VM，别用沙盒。

---

## 3. 文件说明

```

【整个目录，需要放到路径：D:\openresty-win64】

openresty-win64\
├─ 01-OpenRestyBuild.wsb   STEP 1：沙盒配置（映射本目录可写、8 GB 内存、启用网络）
├─ 02-run-setup.cmd        STEP 2：沙盒内装 MSYS2 + 工具链 → setup-msys2.ps1
├─ 03-run-build.cmd        STEP 3：沙盒内编译打包 → build-all.ps1 → build-openresty.sh
├─ set-clash-proxy.cmd     可选：探测本机代理/主机网关并设置 HTTP(S)_PROXY
│                          （02/03 自动调用；可改名 00-set-clash-proxy.cmd）
├─ setup-msys2.ps1         被 02 调用：静默安装 MSYS2 到 %LOCALAPPDATA%\msys64
├─ build-all.ps1           被 03 调用：切到 MINGW64 环境，产物落到 dist\
├─ build-openresty.sh      实际构建脚本（等价于 util/build-win32.sh，带 ERR trap）
├─ README.zh-CN.md         本文档
├─ LICENSE                 MIT
├─ .gitignore              排除 deps\ dist\ log\ 与二进制
├─ msys2-x86_64-latest.exe 可选：预下载的安装器（有它就不再联网下载，不进仓库）
├─ deps\                   四个源码包的下载缓存（不进仓库，可手工放入）
├─ dist\                   产物：openresty-<版本>-win64.zip（不进仓库）
└─ log\                    全部日志（不进仓库，自动保留最近 20 份）
```

执行顺序就是编号顺序：**01 → 02 → 03**。三个入口都支持参数直传：
`02-run-setup.cmd -PacmanMirror <url>`、`03-run-build.cmd -Jobs 4 -Version 1.32.1.1`。

两个 ps1 都带：分阶段进度、transcript、失败时的结构化报错块（阶段 / 行号 / 栈 / hint / 诊断），
以及 `0`/`1` 退出码。详见第 5 节。

### 3.1 需要联网下载的东西（哪些走 GitHub）

| 依赖 | 版本 | 体积 | 来源 | 走 GitHub？ |
|---|---|---|---|---|
| MSYS2 安装器 | latest | 81–120 MB | `github.com/msys2/msys2-installer` → 备用 `repo.msys2.org/distrib/` | **是**（已有官方镜像兜底） |
| pacman 包（工具链 / base-devel / perl …） | — | 300–500 MB | `repo.msys2.org`、`mirror.msys2.org` 等 MSYS2 镜像 | 否 |
| OpenResty 源码 | 1.31.8.1 | 6.5 MB | `openresty.org/download/` | 否 |
| **OpenSSL** | 3.5.9 | **50.8 MB** | `github.com/openssl/openssl/releases` | **是（体积最大、最易被重置）** |
| PCRE2 | 10.49 | ≈2.5 MB | `github.com/PCRE2Project/pcre2/releases` | 是（小文件，风险低） |
| zlib | 1.3.2 | ≈1.3 MB | `zlib.net` → 备用 `zlib.net/fossils/`、`github.com/madler/zlib` | 否（备用源是） |

编译期真正从 GitHub 拉的是 **OpenSSL + PCRE2 ≈ 53 MB**，加上安装器 81 MB。

**缓解措施**：`build-openresty.sh` 现在把四个 tarball 下载到 `openresty-win64\deps\`
（映射目录里，**跨沙盒会话保留**，重建沙盒不用重下），并且：

- `-C -` 断点续传：被重置后从断点继续，而不是从头再来；
- `--retry 8 --retry-all-errors`：把 curl 的 56（接收失败）也纳入重试；
- 先写 `.part`，`gzip -t` 校验通过才改名，半成品永远不会被当成完整包；
- zlib 带三层备用源。

手工预下载（主机上任选 HTTP 客户端，支持断点续传的最好），把文件放进 `deps\` 即可：

```
https://openresty.org/download/openresty-1.31.8.1.tar.gz
https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.gz
https://zlib.net/zlib-1.3.2.tar.gz
```

MSYS2 故意装到 `%LOCALAPPDATA%\msys64`（即 `C:\Users\WDAGUtilityAccount\...`），
**不需要管理员权限**，也避开 `C:\msys64` 的 UAC 弹窗。

---

## 4. 操作步骤

### 4.0 `.wsb` 只能在**主机**上运行，不是在沙盒里

`.wsb` 是“用哪些设置启动沙盒”的描述文件，由**宿主机的 Windows Sandbox 客户端**读取。
沙盒镜像里没有 Windows Sandbox 这个可选功能，也不支持嵌套虚拟化，所以：

- ❌ 不能把 `01-OpenRestyBuild.wsb` 复制进沙盒里双击；
- ✅ 在**主机**上双击 / 命令行启动它，沙盒按配置起来后，目录才会出现在沙盒桌面。

启动方式（主机上任选其一）：

```powershell
# 方式 1：双击（若被记事本抢走关联，右键 → 打开方式 → Windows 沙盒）

# 方式 2：命令行直接执行 .wsb（等价于把 .wsb 当可执行文件）
"$env:USERPROFILE\openresty-win64\01-OpenRestyBuild.wsb"

# 方式 3：显式调用客户端
& 'C:\Windows\System32\WindowsSandbox.exe' "$env:USERPROFILE\openresty-win64\01-OpenRestyBuild.wsb"

# 方式 4：Start-Process
Start-Process "$env:USERPROFILE\openresty-win64\01-OpenRestyBuild.wsb"
```

> 上面假设仓库克隆到 `%USERPROFILE%\openresty-win64`。放在别处时，把这四条路径换掉，
> 同时把 `.wsb` 里的 `<HostFolder>` 改成同一个目录（`.wsb` 只接受绝对路径）。

先确认功能已启用，否则双击只会报错或毫无反应：

```powershell
Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM |
    Select-Object FeatureName, State        # 需要 State = Enabled
```

启动成功的标志：沙盒桌面（`C:\Users\WDAGUtilityAccount\Desktop`）上出现 `openresty-win64` 文件夹，
且主机上该文件夹里能新建文件（说明是可写映射而不是只读）。

### 4.1 在主机上启动沙盒

双击 `01-OpenRestyBuild.wsb`，或在主机 PowerShell 里：

```powershell
WindowsSandbox.exe .\01-OpenRestyBuild.wsb
```

沙盒里目录会出现在 `C:\Users\WDAGUtilityAccount\Desktop\openresty-win64`。
（`WDAGUtilityAccount` 是沙盒的固定账户名。）

### 4.1.1 可选：让沙盒走主机 Clash（GitHub / OpenSSL 下载不再被重置）

Windows Sandbox 是独立 VM：沙盒里的 `127.0.0.1` 指沙盒自己，主机上的
`127.0.0.1:7890` 在沙盒里不可见。本机 Clash Verge 当前是 `mixed-port: 7890`
+ `allow-lan: false`（只监听 loopback），所以要么让 Clash 监听沙盒可达的地址，
要么在主机上做端口转发。

#### 方案 A（推荐）：Clash 开 Allow LAN + 防火墙只放行沙盒网段

主机侧：

1. Clash Verge Rev → 设置 → **局域网连接（Allow LAN）** 打开，确认 mixed-port 为 `7890`。
   等价于运行配置里的 `allow-lan: true` + `bind-address: "*"`。
2. 管理员 PowerShell 放行入站（`172.16.0.0/12` 覆盖 Windows Sandbox 的 NAT 网段）：

```powershell
New-NetFirewallRule -DisplayName "Clash for Windows Sandbox" `
  -Direction Inbound -Action Allow -Protocol TCP -LocalPort 7890 `
  -RemoteAddress 172.16.0.0/12 -Profile Any
```

> 沙盒网段以沙盒里 `ipconfig` 为准（Windows Sandbox 一般是 `172.x.x.0/24`，
> 主机是 `.1`）；如果实际不是 `172.16.0.0/12`，把 `-RemoteAddress` 换成该网段。

3. 想再收紧，在 Clash Verge 的 **Merge.yaml / 配置覆写**里加：

```yaml
allow-lan: true
bind-address: "*"
lan-allowed-ips:
  - 172.16.0.0/12
# 需要认证时：
# authentication:
#   - "user:password"
```

沙盒侧（先确认能通）：

```powershell
$gw = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 |
       Sort-Object RouteMetric | Select-Object -First 1).NextHop
"host = $gw"
Test-NetConnection $gw -Port 7890        # TcpTestSucceeded : True
```

然后直接 `.\02-run-setup.cmd` / `.\03-run-build.cmd` 即可：这两个入口会先调用
`set-clash-proxy.cmd`，探测网关并设置 `HTTP_PROXY` / `HTTPS_PROXY` /
`ALL_PROXY`，PowerShell → `cmd` → MSYS2 `pacman`/`curl`/`git` 都会继承。

也可以手动执行。注意 `set-clash-proxy.cmd` 改的是**它所在的那个 cmd 进程**的环境，
所以要在 cmd 窗口里跑（PowerShell 里直接跑 `.cmd` 是子进程，变量不会回传）：

```bat
cd /d %USERPROFILE%\Desktop\openresty-win64
set-clash-proxy.cmd
curl.exe -I https://github.com           :: 应返回 200/301
```

在 PowerShell 里则直接设 `$env:`：

```powershell
$gw = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 |
       Sort-Object RouteMetric | Select-Object -First 1).NextHop
$env:HTTP_PROXY  = "http://${gw}:7890"
$env:HTTPS_PROXY = $env:HTTP_PROXY
$env:ALL_PROXY   = "socks5h://${gw}:7890"
curl.exe -I https://github.com
```

只想给单条命令用：

```powershell
curl.exe -x "http://${gw}:7890" -I https://github.com
git -c http.proxy=http://${gw}:7890 clone https://github.com/...
```

验证成功：`curl` 返回 200/301，且 Clash Verge 的“连接”页能看到来源为
`172.x.x.x` 的请求。

#### 方案 B：主机 portproxy（Clash 保持 `allow-lan: false`）

不想让 Clash 监听 `0.0.0.0` 时，可在主机上做端口转发（把主机 loopback 端口
“反代”到沙盒可达的 vEthernet 地址）：

```powershell
# 管理员；$gw 换成沙盒里打印出来的那个地址（主机 vEthernet IP，一般 172.x.x.1）
$gw = "172.20.0.1"

netsh interface portproxy add v4tov4 `
  listenaddress=$gw listenport=17890 `
  connectaddress=127.0.0.1 connectport=7890

New-NetFirewallRule -DisplayName "Clash portproxy for Sandbox" `
  -Direction Inbound -Action Allow -Protocol TCP -LocalPort 17890 `
  -RemoteAddress 172.16.0.0/12 -Profile Any
```

沙盒里用 `http://${gw}:17890`。注意：主机 vEthernet 地址每次开沙盒可能变，
要重新添加；`IP Helper`（iphlpsvc）必须运行；清理用
`netsh interface portproxy delete v4tov4 listenaddress=$gw listenport=17890`。

#### 方案 C：TUN（不推荐，除非 A/B 都不行）

Clash Verge 开 TUN + auto-route 后，沙盒的 NAT 流量**可能**被主机路由接管，
但并非所有 Windows / HNS 组合都生效，且 TUN 需要管理员/服务，容易和
Hyper-V、WSL 冲突。开完先在沙盒里 `curl.exe -I https://github.com` 实测。

> 代理只覆盖 TCP；UDP/QUIC 不走 HTTP 代理。遇到某个工具不认 `HTTP_PROXY`，
> 优先查它自己的代理选项，而不是关防火墙。

### 4.2 沙盒内：装工具链（每次新会话都要做，约 3–5 分钟）

打开沙盒里的 **PowerShell**：

```powershell
cd $env:USERPROFILE\Desktop\openresty-win64

.\02-run-setup.cmd        # 推荐：窗口不会关，全程记录到 setup-log.txt
```

等同于手动执行（两种写法等价，任选其一）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File .\setup-msys2.ps1
```

> 手动跑上面这条（而不是 `02-run-setup.cmd`）时，先在 cmd 里 `set-clash-proxy.cmd` 再启动
> PowerShell，或按 4.1.1 在 PowerShell 里设好 `$env:HTTP_PROXY`/`$env:HTTPS_PROXY`，
> 否则子进程拿不到代理变量。

脚本做三件事：静默安装 MSYS2（nightly 安装器的 `in --confirm-command` 模式）→ `pacman -Syuu` 两遍（第一遍升级 `msys2-runtime` 时 shell 会被杀掉，这是已知行为，第二遍收尾）→ 安装
`mingw-w64-x86_64-toolchain base-devel perl patch zip curl wget`。

最后会打印校验信息，应当是：

```
MSYSTEM=MINGW64
x86_64-w64-mingw32
GNU Make x.y
perl msys        # 或 cygwin
```

> `gcc -dumpmachine` 必须是 `x86_64-w64-mingw32`。如果是 `x86_64-pc-msys`，说明你在 MSYS 而不是 MINGW64 环境里，构建会失败。

### 4.3 沙盒内：开始编译（15–40 分钟）

```powershell
.\03-run-build.cmd -Jobs 4      # 或：.\03-run-build.cmd（取 CPU 数）
```

等价写法：`powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File .\build-all.ps1 -Jobs 4`
（手动跑时先在 cmd 里 `set-clash-proxy.cmd`，或在 PowerShell 里设好 `$env:` 代理。）

`-Jobs` 不写则取沙盒可见的 CPU 数；内存 4 GB 时建议 `-Jobs 2`。

脚本流程：

1. 环境自检（`MSYSTEM=MINGW64`、编译器 target、`perl`/`make`/`patch`）；
2. 下载 4 个源码包到 `~/orbuild-1.31.8.1/dl`：
   `openresty-1.31.8.1.tar.gz`、`openssl-3.5.9.tar.gz`、`pcre2-10.49.tar.gz`、`zlib-1.3.2.tar.gz`；
3. 解包到 `objs/lib`，并给 OpenSSL 打上 OpenResty 补丁
   `patches/openssl-*-sess_set_get_cb_yield.patch`（`ssl_certificate_by_lua*` 需要，补丁文件名按通配匹配，避免版本号变化导致卡住）；
4. `./configure --platform=msys ...`（参数与官方 `util/build-win32.sh` 一致：
   `--with-cc-opt='-DFD_SETSIZE=1024'`、`--with-select_module`、`--with-stream`、`--with-http_v2_module`、
   `--with-luajit-xcflags="-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT"` 等）；
5. `make -j$JOBS` → `make install DESTDIR=stage`；
6. `nginx.exe -V` 冒烟测试；
7. 打包为 `dist\openresty-1.31.8.1-win64.zip`（无 `zip` 时退化为 `.tar.gz`）。
   压缩包内**含一层同名目录** `openresty-1.31.8.1-win64/`，解压后所有文件都在这一层里，
   不会散落到当前目录；脚本打包后会校验首个条目确实是该目录，否则直接报错。
   打包前会把目录整理成**与官方 Windows 包一致的布局**（官方解压后只有 18 个条目）：
   - 删除官方包没有的：`md2pod.pl`、`nginx-xml2pod`（文档生成器）、`opm`、`resty.index`、`site/`
   - 保留官方包有的：`pod/`、`restydoc`、`restydoc-index`（离线文档）
   - 补齐官方包有的：`resty.bat` / `restydoc.bat` / `restydoc-index.bat`（Perl 脚本的 cmd 包装）、`README.txt`
   - **不生成** `openresty.exe`：官方包里只有 `nginx.exe` 一个二进制。
     需要 `openresty -s stop` 这种写法时，重编加 `OPENRESTY_EXE=copy` 会额外复制一份（体积翻倍）。

   最终条目：`conf/ html/ include/ logs/ lua/ lualib/ pod/`、`COPYRIGHT`、`lua51.dll`、
   `luajit.exe`、`nginx.exe`、`README.txt`、`resty`、`resty.bat`、`restydoc`、
   `restydoc.bat`、`restydoc-index`、`restydoc-index.bat`。

### 4.4 回到主机使用产物

主机上会出现 `openresty-win64\dist\openresty-1.31.8.1-win64.zip`，解压到 `C:\` 即可得到 `C:\openresty-1.31.8.1-win64\`：

```powershell
Expand-Archive .\openresty-win64\dist\openresty-1.31.8.1-win64.zip -DestinationPath C:\ -Force
C:\openresty-1.31.8.1-win64\nginx.exe -V
```

想放到别处，把整个目录移走即可（`nginx.exe` 用相对前缀 `--prefix=.`，整个文件夹可以任意搬迁）：

```powershell
Move-Item C:\openresty-1.31.8.1-win64 C:\openresty
```

启动 / 停止（Windows 版 nginx 没有服务模式，用 `start` 起）：

```powershell
cd C:\openresty-1.31.8.1-win64
start nginx                 # 或 start nginx -p .\myapp
tasklist /fi "imagename eq nginx.exe"
nginx -s reload             # 重载配置
nginx -s quit               # 优雅退出；强杀用 taskkill /pid <PID> /F
```

`resty` 命令行需要 PATH 里有 Perl（Strawberry Perl 或 MSYS2 的 perl 均可）：

```powershell
resty -e "ngx.say('Hello, OpenResty!')"
```

---

## 5. 日志与报错信息

两个 `.ps1` 都做了完整的错误上报，失败时不需要猜：

| 文件 | 由谁产生 | 内容 |
|---|---|---|
| `log\setup-<时间戳>.txt` | `setup-msys2.ps1` | 全量 transcript：每条命令、每个退出码、诊断段 |
| `log\build-<时间戳>.txt` | `build-all.ps1` | 全量 transcript（含编译输出） |
| `log\build-output-<时间戳>.log` | `build-all.ps1` | 构建脚本的原始 stdout/stderr，失败时自动打印末尾 40 行 |

时间戳格式 `yyyyMMdd-HHmmss`（如 `build-20261030-114928.txt`）。每次运行新建一份，
自动只保留最近 20 份；根目录下的旧 `setup-log.txt` / `build-log.txt` / `build-output.log` 不再生成。

失败时终端会输出结构化的报错块：

```
---------------- SETUP FAILED ----------------
phase      : install toolchain
message    : package installation failed (exit 1) - see the pacman output above
category   : OperationStopped
location   : line 214: Fail "package installation failed (exit $code) ..."
stack      : ...
elapsed    : 2.3 min
hint       : pacman mirror issue - retry; if it persists run pacman-key --init inside MINGW64

--- diagnostics ---
install root : C:\Users\WDAGUtilityAccount\AppData\Local\msys64 [no bash.exe]
TEMP         : C:\Users\WDAGUtilityAccount\AppData\Local\Temp [ok]
free C:      : 38.2 GB
HTTPS_PROXY  :   HTTP_PROXY:
winhttp      : ...
connectivity : curl ... HTTP 200
```

字段含义：

- **phase** —— 失败发生在哪一步（preflight / download installer / silent install / pacman core update / install toolchain / verify toolchain / build / verify artifacts）；
- **location** —— 脚本行号 + 出错那一行源码，`setup-msys2.ps1` 与 `build-all.ps1` 各自独立编号；
- **hint** —— 按消息模式匹配的处置建议（curl 退出码 6/7/22/28/35、下载被截断、安装器 exit 1、pacman 失败等）；
- **diagnostics** —— 安装根、TEMP、磁盘余量、代理设置、到 GitHub 的实际连通性。

两个脚本都以退出码结束：`0` 成功、`1` 失败，方便在自动化里判断。
`build-openresty.sh` 另外加了 `trap ... ERR`，bash 内部失败会打印 `ERROR: <file>:<line> exited <code> while running: <command>`。

排查时把对应日志文件的末尾 30–50 行贴出来即可定位。

## 6. 说明与限制

- 实测情况（Windows 11 沙盒，PS 5.1.26100，6 核）：
  `setup-msys2.ps1` 完整跑通（9 分钟 / 2.3 分钟，gcc 16.2.0 + make 4.4.1）；
  `build-all.ps1` 已产出 `dist\openresty-1.31.8.1-win64.zip`（21 MB），
  `nginx.exe -V` 输出 `openresty/1.31.8.1`、`built with OpenSSL 3.5.9`、`TLS SNI support enabled`。
  全流程约 25 分钟（6 核 `-j6`），其中 OpenSSL 编译占大头。
- 产物是 `select()` + 单 worker + 1024 连接的开发版本；压测/生产请用 WSL2 或 Docker 的官方 Linux 包。
- **调试符号一律保留**（与官方一致）：`nginx.exe` 约 45 MB、zip 约 21 MB 属正常。
  不提供 strip/去 `-g` 选项——需要看 C 栈时直接 GDB 即可，见 9.4。

---

## 7. 升级到新版本

版本号是**单一来源**，不需要改多处。四个值集中在 `build-openresty.sh` 顶部：

```bash
VERSION="${VERSION:-1.31.8.1}"        # OpenResty 版本
OPENSSL_VER="${OPENSSL_VER:-3.5.9}"
PCRE2_VER="${PCRE2_VER:-10.49}"
ZLIB_VER="${ZLIB_VER:-1.3.2}"
```

### 7.1 两种方式

**A. 不改脚本，命令行覆盖（推荐，便于随时回退）**

```powershell
.\03-run-build.cmd -Jobs 6 -Version 1.32.1.1 -OpenSSLVer 3.6.0 -Pcre2Ver 10.50 -ZlibVer 1.3.2
```

`03-run-build.cmd` 会把参数原样传给 `build-all.ps1`，后者再导出成环境变量给 bash。只传 `-Version` 时，其余三项沿用默认值（可能是旧版本，见 8.2）。

**B. 改默认值（长期切到新主线）**

直接改上面那 4 行，然后 `.\03-run-build.cmd` 即可。

### 7.2 需要一起确认的三件事

1. **组件版本要跟着改**。OpenResty 每个版本捆绑的 OpenSSL / PCRE2 / zlib 是变化的，必须与版本对应，否则会链接进旧库。
   来源：发布说明 `https://openresty.org/en/changelog-<数字>.html` 的 Components 一节，或 `openresty -V` 输出。
2. **OpenSSL 补丁要能打上**。脚本按“精确版本 → 同主次版本 → 全部”顺序逐个 `patch -F0 --dry-run` 试，自动挑选；
   若新版 OpenSSL 一份都不匹配，会明确报错并列出候选，可用 `SKIP_OPENSSL_PATCH=1` 跳过（只影响 `ssl_session_*_by_lua` 的 yield 能力）。
3. **configure 选项可能变**。若新版 OpenResty 增删了模块（例如去掉 `--without-http_rds_json_module` 支持的模块），
   `configure` 会报 `invalid option`。此时对照该版本自带的 `util/build-win32.sh` 同步参数即可。

### 7.3 不需要改的东西

| 项 | 原因 |
|---|---|
| 包名 / zip 名 | `PKG="openresty-$VERSION-win64"` 自动跟随 |
| `README.txt` 内容 | 版本与组件号从变量和 `build/nginx-*`、`build/LuaJIT-*` 目录名推导 |
| 目录布局、`.bat` 包装 | 与版本无关（`openresty.exe` 默认不生成，`OPENRESTY_EXE=copy` 才加） |
| 补丁选择、`deps\` 缓存 | 按版本号命名，旧包不会冲突；可手动清理 `deps\` 里的旧 tarball |
| `setup-msys2.ps1`、`.wsb` | 与 OpenResty 版本无关 |

### 7.4 升级后的验证清单

```powershell
# 产物名应带新版本号
Get-ChildItem .\dist

# 关键字：新版本号 + 新 OpenSSL + "TLS SNI support enabled"
C:\openresty-<新版本>-win64\nginx.exe -V
```

再跑一次 `resty -e "ngx.say(ngx.config.ngx_lua_version)"` 确认 Lua 侧正常，最后按 4.4 的流程起服务验证 HTTP 200。

---

## 8. 编译速度

### 8.1 实测数据（Windows 11 沙盒，6 vCPU / 8 GB，`-j6`）

| 场景 | 耗时 | 说明 |
|---|---|---|
| 完整编译（含打包） | **14 分 19 秒** | 2026-10-30 11:49:28 → 12:03:47，`RESULT: OK` |
| 其中 `make install` + 目录整理 + zip | 约 1.5 分钟 | 见日志尾段 |
| `setup-msys2.ps1`（网络好） | 2 分 14 秒 | 144 MB pacman 包 |
| `setup-msys2.ps1`（首次，镜像慢） | 9 分 01 秒 | 同样内容，仅网络差别 |
| 失败在打补丁那次 | 18 秒 | 秒级失败，说明前置阶段很快 |

时间分布：**OpenSSL 编译占一半以上**（约 2000 个 .c 文件），nginx + 40 多个模块约 5–6 分钟，
LuaJIT 约 1 分钟，configure 约 1.5 分钟，下载为 0（`deps\` 命中缓存）。

### 8.2 能显著提速的场景：重复构建

只改了打包逻辑、`.bat` 内容、README 或编译参数时，**不需要从零重编**：

```powershell
.\03-run-build.cmd -Reuse        # 复用 objs\，只重跑 make(空转)+install+打包，约 40 秒
```

原理：`REUSE=1` 时跳过“解包 → 打补丁 → configure”，直接 `make`（源码未变则为 no-op）。
日志里会打印 `REUSE=1: reusing the existing build tree`。

> 前提是同一个沙盒会话（`~/orbuild-<版本>` 还在）。沙盒关掉就没有可复用的树，只能全量重编。

### 8.3 首次编译还能怎么调

| 手段 | 效果 | 代价 |
|---|---|---|
| `-Jobs 8`（6 核超订） | 约 5–10% | 内存吃紧时反而更慢；8 GB 建议不超过 8 |
| 去掉 `-g` 调试符号（**不采用**） | 约 10–15%，`nginx.exe` 从 45 MB 降到十几 MB | 失去 GDB 调试能力，产物与官方不一致 |
| 打补丁/configure 之外减少模块（`--without-http_*`） | 每去掉一批模块省几十秒 | 功能缺失 |
| `deps\` 缓存（已默认开启） | 每次省 1 分钟下载 | — |

代价为“失去调试能力”的那两项默认**不开启**，需要的话自行改 `configure` 那一段。
另外不要把 `WORK` 放到映射盘：沙盒映射目录的 I/O 明显慢于 VHD 内的 `$HOME`，会拖慢编译。

### 8.4 关于 `-g`：保留，不裁剪

本项目**保留全部调试符号**，与官方 Windows 包一致（`README-windows` 原文：
“Debug symbols are enabled even in release builds”）。因此：

- `nginx.exe` 约 45 MB、压缩后 zip 约 21 MB，这是预期大小，不是异常；
- 出 C 层问题时可以直接用 MSYS2 GDB 看到源文件与行号，无需重新编译；
- 去掉 `-g` 只省 10–15% 编译时间和体积，但会失去上述能力，**已明确不采用**。

---
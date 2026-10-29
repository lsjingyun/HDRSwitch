# HDRSwitch

macOS 菜单栏小工具：**一键开关外接显示器的 HDR**。播 HDR 片源时自己打开，播完自己关掉，顺手把刷新率还给你。

| HDR 关闭 | HDR 开启 |
| :--: | :--: |
| ![关闭](docs/menubar-off.png) | ![开启](docs/menubar-on.png) |

**为什么需要它**：很多显示器在 144Hz 这类高刷模式下，链路带宽已经被吃满，macOS 干脆把 HDR 开关整个藏起来——系统设置里根本找不到（[为什么](#为什么开-hdr-会自动变成-60hz)）。HDRSwitch 在开 HDR 时自动切到带宽允许 HDR 的模式（如 5K@60Hz），关掉时再切回原来的 144Hz。

**除了开关，它还自己判断片源**

- 读容器的色彩标记：mp4 走 AVFoundation，mkv 自己解析 EBML，容器里没写就继续读码流的参数集（SPS/VUI）——不靠文件名猜
- Infuse 播**本机 SMB 共享**时，反查 `smbd` 持有的句柄，判定和本地文件一样精确
- 网页视频（B 站 / YouTube）让浏览器跑一小段 JS 读实测画质；YouTube「SDR 下不给 HDR 选项」的死结也解了
- 切一次只黑一次屏，约 0.7 秒

## 下载

**[HDRSwitch-1.0.1.dmg](https://github.com/lsjingyun/HDRSwitch/releases/latest/download/HDRSwitch-1.0.1.dmg)** · 1.2 MB · 通用二进制（Apple Silicon + Intel） · [更新记录](https://github.com/lsjingyun/HDRSwitch/releases)

打开 dmg，把 `HDRSwitch.app` 拖进「应用程序」。本地 ad-hoc 签名、没有 Apple 公证，第一次打开会被拦一次：**按住 Control 点它 → 打开**。

## 要求

macOS 13 及以上。实测环境为 macOS 26/27 + M4 Pro + LG 5K（HDMI 直连）。

## 自己编译

只需要 Xcode 命令行工具：

```bash
./build.sh      # → HDRSwitch.app，双击即用
./package.sh    # → build/HDRSwitch-1.0.0.dmg，可分发
```

面向使用者的完整说明：**<https://lsjingyun.github.io/HDRSwitch/>**（即 [`docs/index.html`](docs/index.html)，单文件、无外部依赖，DMG 里也带一份，⌘P 可存 PDF）。
下面这份偏实现笔记——原理、踩过的坑、验证数据。

## 使用

| 操作 | 效果 |
| --- | --- |
| 点击菜单栏 `HDR` 图标 | 切换 HDR（图标变亮 + 下方出现横线 = 已开启） |
| 右键点击图标 | 打开菜单（切换 / 选显示器 / 开机自启 / 诊断 / 退出） |
| `⌘⌥H` | 全局快捷键，任何界面下都能切换 |
| 在「应用程序」里再双击一次 App | 弹一条当前状态提示（不再擅自切换，避免误触） |

命令行（方便接快捷指令 / 自动化）：

```bash
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch status   # 查看当前状态
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch on       # 开
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch off      # 关
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch toggle   # 反转
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch list     # 所有显示器
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch sessions # 当前检测到的播放
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch detect 文件 # 判断某个片源是否 HDR
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch auto     # 前台跑监视器，实时看判定
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch why      # 不切换时用它看原因（现场信号 + 状态 + 最近日志）
```

## 自动切换（默认开启）

**播放 HDR 片源时自动开 HDR，退出播放后再自动切回 SDR + 原来的 144Hz。**

实测时间线（IINA 播放一段 HEVC 10bit PQ 片源）：

| 时刻 | 发生的事情 |
| --- | --- |
| 打开片源 | 1～2 秒内识别出 `hvc1 · PQ · BT.2020` |
| +3～4 秒 | 自动切到 5K@60Hz 并打开 HDR，headroom 从 1.0 升到 2.18（确认真 HDR 输出） |
| 退出播放器 | 保持 30 秒宽限期（防止暂停/切集来回跳） |
| +30 秒 | 关闭 HDR，恢复 144Hz |

### 它怎么判断「这是 HDR 片源」

不是靠猜，也不靠文件名（文件名只作兜底），分两条路：

**第一条：能拿到片源文件（本地文件 / 挂载盘）→ 精确判定**

1. 直接读播放器进程的文件句柄（`proc_pidfdinfo`），拿到当前加载的媒体文件，不需要任何系统权限，也不启动子进程；
2. 读容器的色彩标记：
   - `.mp4 / .mov` → AVFoundation 读视频轨的 `ColorPrimaries` / `TransferFunction`；
   - `.mkv / .webm` → 自己解析 EBML，读视频轨的 `Colour` 元素（`TransferCharacteristics` / `Primaries` / `MasteringMetadata`）；
   - **容器里没写 Colour 的 mkv**（WEB-DL 常见，例如 `把黑夜点燃` 那一集）→ 继续解析码流的参数集：从 `hvcC`/`avcC` 里取出 SPS，按 HEVC/H.264 语法逐位读到 VUI，取 `colour_primaries` / `transfer_characteristics`。所以能报出 `HEVC · 3840×1608 · 10bit · PQ · BT.2020`，而不是靠文件名猜；
3. 判定规则（偏保守，宁可漏判也不误判成 HDR）：
   - 传输特性是 PQ（SMPTE ST 2084）或 HLG → **HDR**；
   - BT.2020 色域 → **HDR**，但如果是 BT.709 / SMPTE 传输曲线（宽色域 SDR 母版）→ **SDR**；
   - 完全没有色彩标记时 → 8bit 或 1080p 及以下一律判 **SDR**（HDR 必然是 10bit 起步，现实中也没有 1080p 的 HDR 片源），只有「4K + 10bit + 无标记」才算未知。

SDR 片源（H.264 / BT.709、1080p 8bit、无标记的宽色域 SDR）实测**都不会**触发切换。

**第二条：文件来自「这台 Mac 自己的共享」（Infuse 挂载本机 SMB）→ 从服务端 `smbd` 反查**

Infuse 播放本机共享里的文件时，**它自己的进程里没有任何文件句柄** —— 数据是 SMB 协议流进来的。但真正 `open()` 这些文件的是这台机器的 SMB 服务端进程 `smbd`（root 运行），它会在整个播放期间持有被读文件的 fd。

工具于是反过来查服务端：列出 `smbd` 当前打开的视频文件，那就是「正在通过共享播放的这个文件」，再走第一条的码流解析做精确判定——HDR 切、SDR 不切，和本地文件完全一致。

读取 root 进程的 fd 在 macOS 上**只认 root**（「完全磁盘访问权限」也不行，`lsof` 同样要 `sudo`）。所以这里用了一个很小的只读特权小工具 `/usr/local/libexec/hdrswitch-smbdump`，它唯一做的事就是列出 `smbd` 当前打开的视频文件。安装方式：双击项目里的 `安装共享识别.command`，输入一次管理员密码；它会同时写一条只放行这一条命令的 `/etc/sudoers.d/hdrswitch`，之后 App 免密调用它。

没装小工具时这条线静默失效，自动回落到下面第三条的「只知道在播」。菜单里「共享片源识别」会显示当前状态（`经特权小工具读取 smbd 句柄`），`HDRSwitch smb` 也能看到细节。

卸载：`sudo rm -f /usr/local/libexec/hdrswitch-smbdump /etc/sudoers.d/hdrswitch`

> 之所以要绕这一圈：SMB 客户端拿不到文件名（数据流里只有字节），服务端才有。而 `smbd` 的句柄对普通用户不可见，这是 macOS 的保护。

**第三条：文件来自远程 NAS / 媒体服务器（Emby、Plex、WebDAV）→ 只看「是不是真的在播」，默认不切**

Infuse 这类应用从别的机器播放时既不产生本地文件句柄，也不上报系统「正在播放」。但它播放视频时会持有一条阻止显示器休眠的电源断言（`com.firecore.fuse.video_controller`），IINA 则是 `IINA is playing video`。工具通过 IOKit 读这条断言来判断「正在放视频」——这个信号跟片源在本地还是网络无关。

这种场景下拿不到画质信息，所以默认**不会**开 HDR（否则放 SDR 片源也会切）。如果这种片源其实是 HDR，可以打开菜单里的「播放器识别不到片源时也开 HDR」。

还有一个相关选项「识别不到片源时保持已有 HDR」：默认**关**——读不到画质就按 SDR 处理、到点回 SDR。把它打开的话，只要 HDR 还开着就不会被自动关掉。

### 支持的播放器

**任何第三方 App，只要它打开了媒体文件就能被识别**——不依赖白名单。白名单（`IINA`、`Infuse`、`QuickTime Player`、`TV`、`VLC`、`Movist`、`Plex`、`SodaPlayer`）只是额外保证「拿不到文件时」也能靠播放断言判断在播。

判断「真的在用」的条件：持有播放电源断言、系统「正在播放」指向它、或当前前台。

这一条很关键：**光开着文件不算在用**。播放器退出后文件句柄常常还会残留一会儿，以前会被当成「还在播 HDR」，于是切回 SDR 失效、或者一边放 SDR 一边挂着上一条 HDR 的句柄而迟迟不降下来。现在改成按活跃度排序，谁真的在播就以谁的判定为准。

另外有一类 App 必须整个排除：**下载器**。qBittorrent、Transmission、迅雷、Motrix、Folx 这类工具会整段整段时间地持有 `.mkv` 句柄——下载中、做种中——但它们从不播放。不排除的话，一下 HDR 片源屏幕就被切过去了。现在按 bundle id + 名称把它们剔出候选；认不出的客户端还有第二层网：**文件正在变大，或刚写完 4 秒以内，都不算播放**。`HDRSwitch why` 会多打一行「已忽略下载器」，方便确认它确实被拦住了。

### 浏览器 / 网页视频

浏览器（Safari / Chrome / Edge / Arc / Firefox / Brave / Vivaldi / Opera）和音乐类应用单独处理：

- **能拿到本地文件时**（比如把下载好的片子拖进浏览器打开）→ 走第一条精确判定，是 HDR 才切；
- **网页内嵌播放器（B 站 / YouTube 这类）→ 回页面里问一句**。视频的色彩标记确实不对外暴露，唯一的办法是让浏览器在当前标签页跑一小段 JS，读播放器的清晰度标签和画质码（B 站 `125` = HDR、`126` = 杜比视界）。读到 HDR 才切，读到 1080P 之类就判 SDR、不切，读不到就按「未知」处理、同样不切；
- 如果浏览器自己把系统切进了 HDR，工具**不会碰**（只关自己开的 HDR）。

#### YouTube 的死结与解法

YouTube 有个先有鸡还是先有蛋的问题：**显示器不是 HDR 时，它干脆不给你 HDR 选项**（菜单里只有 2160p，没有 2160p HDR）。所以「等检测到 HDR 再切」在这条路上永远等不到。

解法是绕过播放器，直接看播放响应：`adaptiveFormats[]` 里每个流都带 `colorInfo`，片源有没有 HDR 版本跟显示器状态无关。查到有（`SMPTEST2084` / `ARIB_STD_B67` / `BT2020`）就先切 HDR。注意真实字段值是 `COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084` 这种写法，必须用包含匹配。

⚠️ **必须读播放器自己的 `getPlayerResponse()`，不能只读 `window.ytInitialPlayerResponse`**。YouTube 是单页应用：从推荐位点进来、排行榜/电台自动播下一首时，页面上的 `ytInitialPlayerResponse` 还是上一次加载时的那份，照它判断会读到「这条片源没有 HDR」，于是判定 SDR、永远不切（`59Rn4F8bfY4` 就是这么漏的：同一页面上 01:55 读不到 HDR，01:56 刷新后又能读到）。现在的顺序是「播放器的响应优先，拿不到才退回页面变量」，日志详情里会写明「HDR 源信息取自播放器 / 页面」，并带上当前视频 id，换片换得快时也不会认错。

切过去还不够：播放器的可用格式列表是初始化时按当时能力建的，之后不会自己重算，实测会停在「4K SDR（bt709）」。所以再补一步——在显示器已 HDR、但当前流仍不是 HDR 时，带着当前进度调一次 `loadVideoByPlayerVars({videoId, start})` 重建播放器，它才会把 2160p HDR 拿出来。这一步按**视频 id** 记（YouTube 是单页应用，换视频不重载页面），每个视频只做一次，显示器回到 SDR 时清除标记。菜单里可以整体关掉（「YouTube 藏起 HDR 选项时先切 HDR 解锁」）。

重建之后还差最后一脚：YouTube 常常自己先停在 1080p 慢慢爬，实测切完 HDR 后 85 秒都不升。所以再从 `adaptiveFormats` 里读出**HDR 版本里最高的那一档**（2160 → `hd2160`、1440 → `hd1440`、1080 → `hd1080`），在页面里挂一个 2.5 秒一轮的小循环，等播放器的画质列表里出现这一档，就 `setPlaybackQualityRange` + `setPlaybackQuality` 一次性拉过去；确认已在播 HDR 且画质到位就收手（同一视频只调一次，40 秒还调不动就放弃，不和用户抢）。纯 SDR 片源不碰画质——没有 HDR 版本就完全不介入。

⚠️ **目标档位要按屏幕封顶**。YouTube 上有 8K（4320p）HDR 片源，实测 `KaUv1LjLa7k` 一开始被拉到 `highres`（7680×4320）：面板只有 5K，多出来的像素看不见，8K 解码 + 带宽却实打实压着，播放一卡就被判成「没在播」→ 收 HDR → 又重建 → 又卡，一分钟里翻了 5 次。现在的规则是**只选不超过屏幕像素高度的最高 HDR 档**（5K 屏 → 2160p；所有 HDR 档都比屏幕高就干脆不指定，交给 YouTube 自己按带宽选）。

⚠️ **锁画质要锁区间，不能锁单档**。`setPlaybackQualityRange(hd2160, hd2160)` 把档位钉死之后，YouTube 的 SABR 只会围绕这一档拉流；万一这一档的分片取不到数据，它**不会自己降档重试**，就停在缓冲区末尾干等——表现就是「切完 HDR 就断流」，而关掉 HDR 让播放器重新协商又立刻正常（`igqh1jLMe64` 那次）。现场读数很明确：`readyState=2`、`networkState=2`、`currentTime` 不前进、`buffer_health=0.00s`、`network_activity=0 KB`，但带宽估计 109 Mbps、0 丢帧、0 解码错误——数据根本没在下载，不是网速也不是解码问题。

所以现在改成锁一个区间（目标档 + 低一档做下限，如 `hd1440`~`hd2160`）：4K 取不到时 SABR 可以先降到 1440p 继续播，网络好了再爬回去，而不是卡死。到位之后也**不再解锁**——解锁会让 YouTube 直接掉到 720p 且长时间不肯回升（实测掉下去 3 分钟没动），区间锁本身已经留了降档余地。

另外页面里常驻一个 5 秒一轮的**断流看门狗**：连续 10 秒 `currentTime` 不前进且缓冲不足 1 秒，就先解锁档位让 SABR 重新自适应；20 秒还不动就轻推一下 `currentTime` 触发重新请求；40 秒仍不动就放弃这个视频的高画质目标。画质掉到目标以下时它也会在**播放健康**的前提下把区间锁回去（15 秒最多一次、共 8 次，且刚救过场的 60 秒内不动手），避免「锁上→断流→解锁→再锁上」的循环。脚本带版本号，改完重新部署会清掉页面里的旧定时器重建，不用手动刷新页面。

重建播放器还有两个配套保护，否则会自己把自己绕进去：

- **重建后的 15 秒内，看不到播放会话不算「播放结束」**。重建那几秒页面里没有 `<video>` 在播，3 秒宽限一到就会把 HDR 收回去，然后下一轮又重建，来回翻。
- **同一个视频最多重建 2 次**。防止上面那种循环真的发生时无限重试。
- **刚读到过画质（60 秒内）却突然读不到，只保持、不收 HDR**。换集/切歌那一下脚本会抓空，一抖就切回 SDR 再切回来是最难受的。

另外，探针现在**优先读当前正在看的那一页**（`current tab of front window`），开了好几个视频标签时判定的永远是眼前这个，而不是左边那个还在后台响的。

这条路要两条系统授权，缺一条都会静默失效（工具会在日志和 `HDRSwitch web` 里直说卡在哪一步）：

1. `Info.plist` 里要有 `NSAppleEventsUsageDescription`——**没有这一条，macOS 会静默拒绝所有 Apple 事件且不弹授权框**。这是之前折腾最久的一个坑：Safari 的 JS 开关明明勾上了，却仍然 `-10004 权限违例`，连 `count of windows` 都不通。
2. Safari：设置 → 高级 → 勾「显示网页开发者功能」→ 切到新出现的「开发者」标签 → 勾「允许Apple事件中的JavaScript」。（Safari 27 把它从「开发」菜单挪到了设置里，别再找菜单了。）

> 注意：命令行里跑 `HDRSwitch sessions/why` 时探测一定失败——系统按「谁发起的」判授权，终端进程没有这个授权。只有 App 自己（菜单栏那个进程）能探测。要查看它刚才判了什么，用 `defaults read com.wangjin.hdrswitch autoLastSession`，里面带着完整依据。

### 菜单里的选项

- **播放 HDR 内容时自动开启** — 总开关
- **播放器识别不到片源时也开 HDR** — 默认**关**。适用范围：Infuse 网络串流、没写色彩信息的 4K 10bit mkv 等。关掉后只对能精确判定为 HDR 的片源生效
- **识别不到片源时保持已有 HDR（不自动关）** — 默认**关**。关着时读不到画质就当 SDR 处理、到点回 SDR；打开后只要 HDR 还开着就不会被自动关掉（适合「网络流的 HDR 片源，宁可保持」的用法）
- **网页视频按实测画质切换** — 默认**开**。就是上面那条「回页面里问一句」
- **YouTube 藏起 HDR 选项时先切 HDR 解锁** — 默认**开**。YouTube 在 SDR 下不提供 HDR 画质，查到片源自带 HDR 就先切过去，并重建一次播放器（约 1 秒、保留进度）让它选到 2160p HDR
- **解锁后直接选 4K HDR 画质** — 默认**开**。解锁后再把画质直接拉到 HDR 版本里最高的那一档（有 4K HDR 就 2160p HDR），不用等 YouTube 自己慢慢爬、也不用去菜单里手点
- **网页视频一律按 HDR 切（读不到画质）** — 默认**关**。开了之后网页视频会无条件切 HDR，SDR 网页也会切，一般不建议
- **播放结束后切回 SDR** — 立即 / 10 秒 / 30 秒 / 1 分钟 / 5 分钟

### 手动操作不会被自动逻辑覆盖

你一旦手动点了开关（菜单或 `⌘⌥H`），**本场播放内**自动逻辑就让位，不会跟你抢方向盘。

三种情况会解除让位、恢复自动：

- 播放结束（检测不到会话）
- **换了片源或换了播放器**（以前这里会一直粘住，导致换集后不再自动切）
- 菜单 → 自动切换选项 → **恢复自动接管**

### 稳定性上做过的处理

- **禁用 App Nap**：菜单栏工具在后台会被系统限流，定时器可能被压到一分钟才触发一次，表现就是「看了半天才切 / 根本不切」。已用 `ProcessInfo.beginActivity` 保活，实测空闲 60 秒仍稳定 1 次/秒。
- **轮询看门狗**：单次检测卡住超过 6 秒会强制复位，自动逻辑不会永久停摆。
- **模式切换校验 + 重试**：切完分辨率会确认模式真的生效（系统偶尔会弹回原样），没生效就重切；开 HDR 首次不认也会再试一次。
- **失败退避**：连续切不动时按 8→16→32→60 秒退避，不会每秒重试导致画面反复黑屏；连败 3 次本场停止尝试。
- **重启续宽限**：如果 App 在播放中途被重启，会用持久化标记续上宽限期，避免「没在播放却一直停在 HDR」。


## 为什么开 HDR 会自动变成 60Hz

这不是偷懒，是硬件带宽决定的。

以当前这台 LG ULTRAGEAR+（5120×2880 面板，HDMI 连接）为例，实测结果：

| 显示模式 | 系统认为支持 HDR |
| --- | --- |
| 2560×1440 Retina @144Hz | ❌ |
| 2560×1440 Retina @120Hz | ❌ |
| 2560×1440 Retina @60Hz | ✅ |

144Hz 已经吃满了 HDMI 链路带宽，没有余量再给 HDR 需要的 10bit / 静态元数据，所以 macOS 会把 HDR 开关直接藏起来——这就是「系统设置里找不到 HDR」的真正原因。

所以本工具的做法是：

- **开 HDR** → 自动切到 5K@60Hz，打开 HDR（系统设置里「高动态范围」也会同步变成开启）
- **关 HDR** → 关掉 HDR，并自动切回你原来的 144Hz

第一次开启需要试几个模式，约 5～7 秒；之后会记住上次成功的模式，约 1.5 秒完成。

### 黑屏时间是怎么压下来的

这里其实有**两次**黑屏：一次是换显示模式（144Hz → 60Hz，硬件重新握手），一次是系统真正切 HDR 标志。以前是先换模式 → 等面板同步完 → 再切 HDR，等于黑两次、中间还夹一段 SDR 画面。

现在做三件事把它们压成一次：

1. **模式一提交就立刻发 HDR 请求**，不等系统报告「这个模式支持 HDR」。两者挤进同一次重新同步里，实测 HDR 请求到生效只差 0～6ms。
2. **关 HDR 时不单独关**，直接切回 144Hz 那一档——它本身带不动 HDR，系统会连带把 HDR 收掉。以前是「先关 HDR 等生效，再换模式」，同样黑两次。
3. 轮询粒度 100ms → 20ms，去掉无意义的固定等待。

实测（`切换耗时` 会写进日志，日志里能看到分段）：

```
开：656ms = 应用模式 655ms + HDR 生效 1ms     （原来 1650ms，两次黑屏）
关：669ms = 应用模式 615ms + 稳定 50ms        （原来 1705ms）
```

剩下的 ~620ms 全是 `CGCompleteDisplayConfiguration` 本身——面板重新握手，属于硬件下限，软件绕不过去。想再快只能不切模式，那就不可能在这块屏上开 HDR。

如果你的显示器在原生模式下就支持 HDR（比如 Studio Display、Pro Display XDR、或者带宽充裕的 4K 屏），工具不会碰分辨率，只做纯粹的开关。

## 实现原理

macOS 没有公开的 HDR 开关 API，本工具通过 `dlopen` 调用 SkyLight 私有接口：

- `CoreDisplay_Display_SupportsHDRMode(displayID)` — 当前模式是否允许 HDR
- `CoreDisplay_Display_IsHDRModeEnabled(displayID)` — 当前 HDR 状态
- `SLSDisplaySetHDRModeEnabled(displayID, enabled)` — 切换 HDR

跟系统设置里那个开关走的是同一条链路，所以状态完全同步。

注意：私有接口在系统大版本升级后有可能改名或改签名，到时候重编一次通常就能修好（用 `nm -gU` 或 `strings` 在 `SkyLight` 里重新找符号即可）。

## 图标

图标是代码画的，没有图片素材：`Tools/makeicon.swift` 用 CoreGraphics 在 2048 画布上绘制再缩到 1024，改配色/比例直接改脚本里的数值，重新生成即可。

```bash
swift Tools/makeicon.swift build/icon/AppIcon-1024.png
```

**设计**：深色背板上放一颗 45° 斜切的球——左下没入暗部，右上半被强光照亮，交界处一道高光线，外围一圈光晕。HDR 的本质就是「同一画面里既有极暗又有极亮」，一颗球就够表达；不用字母、不用文字，缩到 32px 仍认得出。

**两个踩过的坑**：

- ⚠️ **必须满幅输出**。macOS 26/27 的图标规范是图形铺满整张画布、圆角由系统裁。早先按旧规范留了 100px 透明边距，系统把透明区当空白、额外套了一层白色玻璃底板，图标变成「白框里塞一块深色」。改成满幅后正常。
- 外围光晕要用**叠加混合**（`plusLighter`）而不是普通透明——普通 alpha 会把深色背板染成脏褐色；叠加才是「光加在暗底上」，暗的地方仍然暗。另外溢光只加在亮面一侧，暗面沾到就糊成灰雾。

打包进 app 的流程已经写进 `build.sh`（`Resources/AppIcon.icns` → `Contents/Resources/`），Info.plist 里的 `CFBundleIconFile` 指向 `AppIcon`。整套尺寸用 `sips` 从 1024 缩出来、`iconutil` 打成 icns。

## 打包成 DMG

```bash
./package.sh
# → build/HDRSwitch-<版本>.dmg
```

脚本做四件事：`./build.sh` 编译 → 分别编 arm64 / x86_64 再 `lipo` 合成通用二进制 → 摆好内容 → `hdiutil` 压成 UDZO 并校验。

盘里放的是：

```
HDRSwitch.app
Applications -> /Applications        拖过去就装好
使用说明.html                         完整说明书（浏览器打开，⌘P 存 PDF）
安装说明.txt                          首次打开被拦、要授权什么、怎么卸
可选组件（共享识别）/
    hdrswitch-smbdump                 只读小工具
    install-helper.sh                 装它和 sudoers 规则
    安装共享识别.command                双击即可（要输一次管理员密码）
```

把辅助工具塞进盘里，是为了换台机器也能直接装，不必回到项目目录——它原本依赖 `build/` 和 `Tools/` 的相对路径，在 DMG 里不存在。

**两个限制**（都是环境造成的，不是脚本写错）：

- 没有做「图标位置 + 背景图」那种定制窗口。那需要 Finder 自动化授权，脚本进程被系统拒绝（`-10004`）。现在就是标准的 App + Applications 拖拽位。
- 卷图标（`.VolumeIcon.icns` + 自定义图标位）也做不了：设置它必须先把 DMG 可写挂载，而挂载在当前环境被拒。所以盘在桌面显示为普通磁盘图标，不影响使用。

体积 1.2 MB 左右；因为只依赖系统框架，没有第三方库要打进去。

## 卸载

```bash
# 先从菜单退出，然后
rm -rf /Applications/HDRSwitch.app
defaults delete com.wangjin.hdrswitch
```

## 已知限制

- 只在 Apple Silicon + macOS 26/27 上验证过
- 部分显示器（尤其是通过转接器 / 扩展坞连接的）可能压根不回报 HDR 能力，这种情况下没有任何软件能打开
- HDR 模式下如果手动改分辨率 / 刷新率，状态可能不同步，切一次 HDR 即可恢复
- 自动模式的判定依据是「谁真的在播」（持防休眠断言 / 系统在播 / 前台），所以暂停但没关闭时 HDR 会保持开启，退出播放器才会切回
- 切换 HDR 必然伴随一次显示模式切换，画面会黑一下（实测约 0.7 秒，见上文「黑屏时间是怎么压下来的」），全屏播放时窗口可能被系统挪到别的桌面——这是 macOS 的行为，无法避免
- Infuse 播**本机共享**的文件：已支持精确判定（靠特权小工具读 `smbd` 句柄）；播**远程 NAS / 媒体服务器**的文件：拿不到画质，默认不切
- 特权小工具装在 `/usr/local/libexec/hdrswitch-smbdump`，卸载用 `sudo rm -f` 那两条路径即可；重新编译 App 不影响它
- 网页视频靠浏览器执行 JS 读取画质：读不到就按「未知」处理、不切。所以**浏览器里的 SDR 网页永远不会被误切**，代价是画质标签显示「自动」或页面结构大改（B 站改版）时可能读不到、也就不切
- 网页探测只在**菜单栏那个 App 进程**里生效：终端里跑 `HDRSwitch sessions/why` 会因为「发送方没有自动化授权」而探测失败，这是系统的判定方式，不是故障。看它最近一次判了什么用 `defaults read com.wangjin.hdrswitch autoLastSession`
- Infuse 走网络串流（拿不到文件句柄）时判断不了画质，默认不切 HDR；要切可在菜单打开「播放器识别不到片源时也开 HDR」
- 排查问题：先跑 `HDRSwitch why`，一次列出显示器状态、现场识别结果、自动模式是否被手动接管、失败计数和最近日志
- 需要更细的每轮判定日志时：`defaults write com.wangjin.hdrswitch debugLog -bool true` 后重启 App（动作级事件本来就会写进 `~/Library/Logs/HDRSwitch.log`，文件超过 512KB 自动清空）

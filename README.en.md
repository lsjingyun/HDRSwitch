# HDRSwitch

[中文](README.md) · **English**

A tiny macOS menu bar utility: **one-click HDR for your external display**. It switches HDR on when an HDR title starts playing, switches it off when you stop, and gives you your refresh rate back.

| HDR off | HDR on |
| :--: | :--: |
| ![off](docs/menubar-off.png) | ![on](docs/menubar-on.png) |

**Why you need it**: on many displays the link bandwidth is already saturated at high refresh rates such as 144 Hz, so macOS simply hides the HDR switch altogether — you can't find it in System Settings at all ([why](#why-turning-hdr-on-drops-you-to-60-hz)). HDRSwitch automatically moves to a mode where the bandwidth allows HDR (e.g. 5K@60Hz) when turning HDR on, and back to your original 144 Hz when turning it off.

**Beyond the switch, it also inspects the source itself**

- Reads the container's colour tags: mp4 via AVFoundation, mkv with its own EBML parser, and when the container is silent it walks down into the bitstream parameter sets (SPS/VUI) — no guessing from filenames
- When Infuse plays from **this Mac's own SMB share**, it reverse-looks-up the handles held by `smbd`, giving the same precision as a local file
- For web video (Bilibili / YouTube) it runs a small piece of JS in the browser to read the actual playback quality; the YouTube deadlock where "SDR means no HDR option" is solved too
- Native streaming clients such as Tencent Video: reads the content-level HDR verdict its own playback core writes (`isHDRVideo=1`)
- Each toggle costs exactly one blackout, about 0.7 s

## Download

**[HDRSwitch-1.0.9.dmg](https://github.com/lsjingyun/HDRSwitch/releases/latest/download/HDRSwitch-1.0.9.dmg)** · 1.2 MB · universal binary (Apple Silicon + Intel) · [Release notes](https://github.com/lsjingyun/HDRSwitch/releases)

Open the dmg and drag `HDRSwitch.app` into Applications. It is signed locally with a self-signed certificate and notarised by nobody, so the first launch gets blocked once: **hold Control, click it, then Open**.

## Requirements

macOS 13 or later. Tested on macOS 26/27 with an M4 Pro and an LG 5K over HDMI.

## Build it yourself

Only the Xcode command line tools are needed:

```bash
./build.sh      # → build/HDRSwitch.app, double-click to run
./package.sh    # → build/HDRSwitch-1.0.9.dmg, distributable
```

The complete end-user guide: **<https://lsjingyun.github.io/HDRSwitch/>** (that is [`docs/index.html`](docs/index.html) — a single file with no external dependencies, also shipped inside the DMG, ⌘P saves it as PDF).
What follows reads more like implementation notes — internals, pitfalls, measurements.

## Usage

| Action | Effect |
| --- | --- |
| Click the `HDR` icon in the menu bar | Toggle HDR (a brighter icon with an underline means it is on) |
| Right-click the icon | Open the menu (toggle / pick display / launch at login / diagnostics / quit) |
| `⌘⌥H` | Global hotkey, works from any app |
| Double-click the app in Applications again | Shows a status toast (it no longer toggles by itself, to avoid accidents) |

Command line, handy for Shortcuts or automation:

```bash
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch status   # current state
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch on       # on
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch off      # off
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch toggle   # invert
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch list     # all displays
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch sessions # playback detected right now
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch detect <file>  # is this file HDR?
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch auto     # run the watcher in the foreground
/Applications/HDRSwitch.app/Contents/MacOS/HDRSwitch why      # when it refuses to switch, ask why (live signals + state + recent log)
```

## Automatic switching (on by default)

**HDR goes on when an HDR source starts playing, and back to SDR plus your original 144 Hz after playback ends.**

Measured timeline (IINA, a HEVC 10-bit PQ source):

| Moment | What happens |
| --- | --- |
| File opened | Within 1–2 s it identifies `hvc1 · PQ · BT.2020` |
| +3–4 s | Switches to 5K@60Hz and enables HDR; headroom goes from 1.0 to 2.18 (confirming real HDR output) |
| Video closed | Handle disappears → 4 s grace → falls back, about 5 s in practice (pausing keeps HDR) |
| Player quits | A 30 s grace period starts (so pausing or skipping an episode doesn't bounce the display) |
| +30 s | HDR off, 144 Hz restored |

### How it decides "this is HDR"

No guessing, and no filename matching (filenames are only a last resort). There are two paths:

**Path one: the source file is reachable (local file / mounted volume) → exact verdict**

1. It reads the player process's file descriptors directly (`proc_pidfdinfo`) to get the currently loaded media file. No permissions required, no child processes spawned.
2. It reads the container's colour tags:
   - `.mp4 / .mov` → AVFoundation, the video track's `ColorPrimaries` / `TransferFunction`;
   - `.mkv / .webm` → its own EBML parser, the video track's `Colour` element (`TransferCharacteristics` / `Primaries` / `MasteringMetadata`);
   - **mkv files with no Colour element at all** (common in WEB-DL releases) → it keeps going into the bitstream parameter sets: pulls the SPS out of `hvcC`/`avcC` and bit-reads all the way to the VUI following the HEVC/H.264 syntax, taking `colour_primaries` / `transfer_characteristics`. That is how it can report `HEVC · 3840×1608 · 10bit · PQ · BT.2020` instead of guessing from a name;
3. Decision rules (deliberately conservative — a miss is better than a false positive):
   - transfer characteristic is PQ (SMPTE ST 2084) or HLG → **HDR**;
   - BT.2020 primaries → **HDR**, unless the transfer is BT.709 / SMPTE (a wide-gamut SDR master) → **SDR**;
   - no colour tags whatsoever → 8-bit or 1080p-and-below is always **SDR** (HDR starts at 10-bit, and there is no such thing as a 1080p HDR source); only "4K + 10-bit + untagged" counts as unknown.

SDR sources (H.264 / BT.709, 1080p 8-bit, untagged wide-gamut SDR) were all measured to **not** trigger a switch.

**Path two: the file comes from this Mac's own share (Infuse mounting the local SMB server) → reverse lookup in `smbd`**

When Infuse plays a file from the local share, **its own process holds no file handle at all** — the data arrives over SMB. The process that actually `open()`s those files is this machine's SMB server, `smbd` (running as root), and it holds the fd of every file being read for the whole duration of playback.

So the tool asks the server instead: list the video files `smbd` currently has open. Those are "the file being played over the share". Then it runs the path-one bitstream analysis on it — HDR switches, SDR doesn't, exactly like a local file.

Reading a root process's fds on macOS **requires root** (Full Disk Access does not help; `lsof` needs `sudo` too). So there is a very small read-only privileged helper, `/usr/local/libexec/hdrswitch-smbdump`, whose only job is to list the video files `smbd` has open. To install it, double-click `安装共享识别.command` in the project and enter your admin password once; it also writes an `/etc/sudoers.d/hdrswitch` rule that allows only that one command, so the app can call it without a password afterwards.

Without the helper this path silently degrades to path three ("it is playing, but that's all we know"). The menu item "Share source detection" shows the current state (`reading smbd handles via privileged helper`), and `HDRSwitch smb` prints the details.

Uninstall: `sudo rm -f /usr/local/libexec/hdrswitch-smbdump /etc/sudoers.d/hdrswitch`

> Why the detour: an SMB client never sees a filename (the stream is just bytes), only the server does. And `smbd`'s handles are invisible to normal users — that is macOS protecting them.

**Path three: the file comes from a remote NAS / media server (Emby, Plex, WebDAV) → only "is it actually playing", no switch by default**

When Infuse streams from another machine it produces neither a local file handle nor a system "now playing" entry. But while playing video it does hold a power assertion that prevents display sleep (`com.firecore.fuse.video_controller`); IINA's is `IINA is playing video`. The tool reads that assertion through IOKit to know "video is playing" — a signal that is independent of where the file lives.

Quality information is unavailable in this case, so by default it does **not** turn HDR on (otherwise SDR playback would switch too). If such a source really is HDR, enable "Turn on HDR when the source can't be identified" in the menu.

There is a related option, "Keep existing HDR when the source can't be identified": **off** by default — an unreadable source is treated as SDR and drops back on schedule. If you turn it on, HDR will not be switched off automatically while it is still on.

### Supported players

**Any third-party app that has a media file open is recognised** — no whitelist needed. The whitelist (`IINA`, `Infuse`, `QuickTime Player`, `TV`, `VLC`, `Movist`, `Plex`, `SodaPlayer`) only adds a guarantee that "is it playing" can still be answered from the power assertion when no file is available.

"It is really in use" means: holding a playback power assertion, being the system's "now playing" app, or being frontmost.

That last point matters: **having a file open is not the same as playing it**. After a player quits, its file handles often linger for a while, which used to be read as "still playing HDR" — so switching back to SDR failed, or an SDR video played while an old HDR handle kept the display from dropping. Now sessions are ranked by activity and whoever is genuinely playing gets the final say.

**The one exception is "paused"**: IINA and VLC drop their "playing video" power assertion the moment you hit pause, and if you then switch to another app the old logic read that as "playback finished" — the grace period expired and the picture lost HDR mid-movie. Now a player that **still has the source file open** counts as present, no matter how long you stay paused; HDR only falls back once the file is unloaded or the player quits. To avoid mistaking encoders and transcoders for players, this only applies to whitelisted players and to apps that were genuinely playing that same file moments ago. It can be turned off in the menu (on by default).

**"Paused" and "stopped" are told apart by handles, not by window size.** While paused the file stays open and only the timeline stops; when you stop the video the player hands the file back and the handle disappears. So the rule is: this session has seen a handle, and now all of them are gone → note the moment, wait a **4-second grace** (absorbing buffering, episode changes and `smbd` teardown) and treat it as finished if nothing came back. Measured: HDR falls back about 5 seconds after you close the video. Conversely, if the handle has switched to a **different file**, playback is continuing (next episode, manual source change) — it is re-registered immediately, no grace needed.

This used to key off window area, which fails on Infuse: after you close a video it still leaves a `500×500` window behind, **identical in shape** to the mini-player it collapses into when paused. Geometry cannot tell them apart — hence several releases that either dropped out of HDR at random or never dropped at all. Window size is now only a hint.

There is one hard rule on top: **once a session has been judged finished, its old verdict can never be revived**. HDR may only switch on again after playback genuinely resumes (a live handle is registered again). Previously a flickering window size made the verdict oscillate between "changed" and "unchanged"; every "changed" ended the session and dropped HDR, and the next tick brought the same old verdict back as "paused" and switched it on again — the display visibly flip-flopped on its own. Also, **a paused session may only keep HDR, never turn it on**: switching while paused costs a blackout and gains nothing.

 One class of app must be excluded entirely: **downloaders**. qBittorrent, Transmission, Thunder, Motrix and Folx hold `.mkv` handles for hours on end — while downloading, while seeding — but they never play anything. Without the exclusion, the moment an HDR torrent starts downloading the display jumps to HDR. They are now removed from the candidate list by bundle id plus name matching, and there is a second net for clients that aren't recognised: **a file that is growing, or was modified within the last 4 seconds, does not count as playback**. `HDRSwitch why` prints an extra "ignored downloaders" line so you can confirm the filter fired.

### Native streaming clients (Tencent Video)

The Mac version of Tencent Video is a native player built on its own TVKPlayer engine — no local file handles, no web page, so neither of the two paths above applies. Its playback core does, however, log its own verdicts:

```text
updateSubtitleRenderMode. isHDRVideo=1 fileid=322108
frame hdr info changed, ... ==> hdr type=HDRVivid, hdr mapping type=HardwareHDR10StaticMapping
```

SDR content shows `isHDRVideo=0` / `hdr type=None`. The tool reads that log and reports the evidence as the player log.

The two records are not the same thing, and mixing them up breaks things:

- `isHDRVideo` is a **content-level** verdict — whether this title has an HDR version at all, regardless of whether the display currently has HDR on. This is the primary signal;
- `hdr type` is **render output** — it says `None` whenever nothing is rendered in HDR. But macOS emits `HDRVivid` even in SDR mode (it does its own tone mapping), so this one latches itself on: judged by it, HDR would turn on and never turn off. It is only used as corroboration.

Watch out for the block of `HDR Cap Query: HDRVivid ... -> Supported` lines near the top of the log: that is a **device capability query** (does this machine support HDR) and has nothing to do with what is playing. Judged by that line, simply opening Tencent Video would look like HDR. Those lines are ignored entirely.

Two more traps:

- **one log file carries a dozen playback instances.** Every recommendation tile on the home page runs its own muted preview, plus the detail-page preview and the real playback — each writing thousands of lines while active. Their verdicts share one file: the feature film reports HDRVivid, then a home-page preview writes `None` fifteen seconds later. Taking "the last verdict" would let the preview overwrite the film and it would read SDR forever. So each instance (`tpplayerN_tpcoreM`) is tracked separately, and the one still alive wins;
- its power assertion is **never released** on pause — not even after closing the video and returning to the home page — so the assertion cannot tell "still playing" from "already closed". This class therefore ignores assertions and watches **log activity**: an instance counts as playing only if it wrote something within the last 8 seconds. On close it often doesn't even emit a stop event (it just switches to other content), so this is the only signal — and the reason HDR falls back within a few seconds.

Tencent Video's HDR standard is HDR Vivid ("臻彩视听"), written `HDRVivid` in the log; it is treated as HDR just like HDR10.

**This path needs Full Disk Access.** The logs sit inside Tencent Video's own sandbox container (`~/Library/Containers/com.tencent.tenvideo/…`), and any other app must hold that grant to read them — otherwise the system simply returns `permission denied` and HDRSwitch quietly decides "quality unreadable". The menu has an item for it ("腾讯视频识别：点击授权") which opens the settings pane with HDRSwitch highlighted; tick it and restart once. Not having it isn't a failure: the Tencent Video section of `HDRSwitch why` says so explicitly.

`HDRSwitch why` has a Tencent Video section listing what was read and the log path, so there is nothing to guess at.

### Browsers / web video

Browsers (Safari / Chrome / Edge / Arc / Firefox / Brave / Vivaldi / Opera) and music apps are handled separately:

- **When a local file is available** (e.g. you dragged a downloaded video into the browser) → path one applies, and only HDR switches;
- **Embedded web players (Bilibili / YouTube and friends) → go back into the page and ask**. The video's colour tags are genuinely not exposed, so the only way is to run a small piece of JS in the current tab and read the player's quality label and quality code (on Bilibili `125` = HDR, `126` = Dolby Vision). HDR means switch; 1080P and such means SDR, no switch; unreadable means "unknown", also no switch;
- If the browser itself switched the system into HDR, the tool **leaves it alone** (it only ever turns off what it turned on).

#### YouTube's chicken-and-egg problem, and the way out

YouTube has a chicken-and-egg problem: **when the display is not in HDR it simply does not offer HDR** (the menu shows 2160p, not 2160p HDR). So "wait until HDR is detected, then switch" can never fire on this path.

The way out is to bypass the player and read the playback response: every stream in `adaptiveFormats[]` carries `colorInfo`, and whether a source has an HDR rendition has nothing to do with the current display state. If it finds one (`SMPTEST2084` / `ARIB_STD_B67` / `BT2020`), it switches HDR first. Note that the real field values look like `COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084`, so the match has to be a containment check.

⚠️ **It must read the player's own `getPlayerResponse()`, not just `window.ytInitialPlayerResponse`**. YouTube is a single-page app: when you arrive from a recommendation, or when a playlist/radio auto-advances, the page-level `ytInitialPlayerResponse` is still the one from the previous navigation. Judging by it reads "this source has no HDR", so the verdict is SDR and it never switches (that is exactly how `59Rn4F8bfY4` was missed: no HDR at 01:55 on that page, HDR again after a reload at 01:56). The order is now "player response first, page variable only as fallback"; the log detail says whether the HDR info came from the player or the page link, and includes the current video id, so fast skipping can't misidentify.

Switching alone isn't enough: the player builds its available-format list from the capabilities present at initialisation and never recomputes it, so in practice it sits at "4K SDR (bt709)". One more step is needed — while the display is in HDR but the current stream still isn't, it calls `loadVideoByPlayerVars({videoId, start})` with the current position to rebuild the player, and only then does the 2160p HDR option appear. This is keyed by **video id** (YouTube is a SPA, so switching videos doesn't reload the page), done at most once per video, and the flag is cleared when the display returns to SDR. The whole behaviour can be turned off in the menu ("Switch to HDR first when YouTube hides the HDR option").

After the rebuild there is one last kick: YouTube often stays at 1080p and climbs slowly — measured 85 seconds without an upgrade after HDR came on. So it reads **the highest HDR rendition** out of `adaptiveFormats` (2160 → `hd2160`, 1440 → `hd1440`, 1080 → `hd1080`) and runs a 2.5 s loop in the page; as soon as that level shows up in the player's quality list it fires `setPlaybackQualityRange` + `setPlaybackQuality` in one go. It stops once HDR is playing at the right level (once per video; gives up after 40 s rather than fighting the user). Pure SDR sources are never touched — no HDR rendition means no intervention at all.

⚠️ **The target level must be capped by the screen.** YouTube has 8K (4320p) HDR sources; `KaUv1LjLa7k` was initially pushed to `highres` (7680×4320). The panel is only 5K, the extra pixels are invisible, but 8K decoding plus bandwidth is very real — a single stutter got read as "not playing" → HDR off → rebuild → stutter again, five flips in one minute. The rule now is **pick the highest HDR level that does not exceed the screen's pixel height** (5K screen → 2160p; if every HDR level is taller than the screen, don't pin anything and let YouTube decide by bandwidth).

⚠️ **Lock a range, not a single level.** Once `setPlaybackQualityRange(hd2160, hd2160)` pins the level, YouTube's SABR only fetches around that level; if a segment at that level can't be fetched it **will not step down and retry**, it just sits at the end of the buffer — the symptom is "HDR switches on and playback stalls", while turning HDR off lets the player renegotiate and everything is fine again (that was the `igqh1jLMe64` report). The live readings were unambiguous: `readyState=2`, `networkState=2`, `currentTime` not advancing, `buffer_health=0.00s`, `network_activity=0 KB` — yet bandwidth estimate 109 Mbps, 0 dropped frames, 0 decode errors. Data simply was not being downloaded; it was neither the network nor the decoder.

So it now locks a range (target level plus one level lower as the floor, e.g. `hd1440`~`hd2160`): if 4K can't be fetched, SABR can drop to 1440p and keep playing, then climb back when the network recovers, instead of stalling. It also **no longer unlocks** afterwards — unlocking makes YouTube fall straight to 720p and stay there for a long time (3 minutes without recovery in testing); the range lock already leaves room to step down.

On top of that, a **stall watchdog** runs in the page every 5 seconds: if `currentTime` hasn't advanced for 10 s and the buffer is under 1 s, it unlocks the level so SABR can re-adapt; at 20 s it nudges `currentTime` to trigger a fresh request; at 40 s it gives up on the high-quality goal for that video. When quality falls below target while playback is **healthy**, it also re-applies the range lock (at most once every 15 s, 8 times total, and not within 60 s of a rescue), which avoids the "lock → stall → unlock → lock again" loop. The script is versioned: redeploying after a code change tears down the old timers and rebuilds them, so no manual reload is needed.

Rebuilding the player needs two guards, otherwise it trips over itself:

- **For 15 s after a rebuild, not seeing a playback session does not count as "playback ended".** During those few seconds there is no `<video>` playing, so a 3 s grace period would turn HDR off, and the next round would rebuild again — flip, flip, flip.
- **At most 2 rebuilds per video.** So that the loop above can never become endless retries.
- **A source that was readable within the last 60 s but suddenly isn't only holds, never drops HDR.** Skipping an episode or a track makes the script come up empty for a moment; bouncing to SDR and back is the worst possible experience.

The probe also now **targets the tab you are actually looking at** (`current tab of front window`), so with several video tabs open it always judges the one in front instead of the one still singing in the background.

This path needs two system grants, and missing either one fails silently (the tool says which step failed in the log and in `HDRSwitch web`):

1. `NSAppleEventsUsageDescription` in `Info.plist` — **without it macOS silently denies every Apple Event and never shows a prompt**. This was the longest-running trap: Safari's JS switch was clearly ticked, yet everything still returned `-10004 privilege violation`, down to `count of windows`.
2. Safari: Settings → Advanced → tick "Show features for web developers" → switch to the new "Developer" tab → tick "Allow JavaScript from Apple Events". (Safari 27 moved this out of the Developer menu into Settings; stop looking in the menu.)

> Note: running `HDRSwitch sessions/why` from a terminal always fails to probe — the system authorises by "who is asking", and the terminal process doesn't hold that grant. Only the app itself (the menu bar process) can probe. To see what it last decided, use `defaults read com.wangjin.hdrswitch autoLastSession`, which contains the full reasoning.

### Menu options

- **Turn on HDR when playing HDR content** — master switch
- **Turn on HDR when the source can't be identified** — **off** by default. Covers Infuse network streaming, 4K 10-bit mkv with no colour tags, etc. When off, only sources that can be positively identified as HDR trigger a switch
- **Keep existing HDR when the source can't be identified (don't turn off automatically)** — **off** by default. When off, an unreadable source is treated as SDR and drops back on schedule; when on, HDR is never switched off automatically while it is still on (for "streamed HDR sources, better to keep it" use cases)
- **Keep HDR while paused** — **on** by default. Pausing makes the player drop its "playing video" power assertion, which the old logic took as "playback finished" — the grace period expired and HDR fell back. With this on, HDR is kept for as long as the source file stays open; it only falls back when the file is unloaded or the player quits
- **Switch web video by measured quality** — **on** by default. That is the "go back into the page and ask" path above
- **Switch to HDR first when YouTube hides the HDR option** — **on** by default. YouTube doesn't offer HDR while the display is SDR; if the source has HDR it switches first and rebuilds the player once (about 1 s, position preserved) so 2160p HDR becomes selectable
- **Pick 4K HDR quality right after unlocking** — **on** by default. After unlocking it pushes quality straight to the highest HDR rendition (2160p HDR when available), instead of waiting for YouTube to climb or clicking the menu by hand
- **Always switch web video to HDR (even when unreadable)** — **off** by default. When on, every web video switches unconditionally, SDR pages included; generally not recommended
- **Switch back to SDR after playback ends** — immediately / 10 s / 30 s / 1 min / 5 min

### A manual toggle is never overridden

Once you toggle by hand (menu or `⌘⌥H`), the automatic logic steps aside **for the rest of that playback session** and won't grab the wheel from you.

Three things release the override and restore automation:

- playback ends (no session detected)
- **the source or the player changes** (this used to stick forever, so switching episodes stopped switching automatically)
- menu → automatic switching options → **Resume automatic control**

### What was done for reliability

- **App Nap disabled**: a background menu bar utility gets throttled, timers can stretch to once a minute, and the symptom is "it switched after ages / never switched". `ProcessInfo.beginActivity` keeps it alive; measured still a steady 1 Hz after 60 s idle.
- **Polling watchdog**: a single detection stuck for more than 6 s is force-reset, so the automatic logic never halts permanently.
- **Mode verification and retry**: after switching resolution it confirms the mode actually took effect (the system occasionally snaps back), and retries if it didn't; HDR that isn't accepted the first time is re-requested once.
- **Failure backoff**: consecutive failures back off at 8 → 16 → 32 → 60 s, so it doesn't retry every second and strobe the screen; 3 consecutive failures stop attempts for that session.
- **Grace period survives a restart**: if the app is restarted mid-playback, a persisted marker resumes the grace period, so you never end up "not playing but stuck in HDR".


## Why turning HDR on drops you to 60 Hz

This is not laziness, it is hardware bandwidth.

Take this LG ULTRAGEAR+ (5120×2880 panel, HDMI). Measured:

| Display mode | System reports HDR support |
| --- | --- |
| 2560×1440 Retina @144Hz | ❌ |
| 2560×1440 Retina @120Hz | ❌ |
| 2560×1440 Retina @60Hz | ✅ |

144 Hz already saturates the HDMI link, leaving no headroom for the 10-bit / static metadata that HDR needs, so macOS simply hides the HDR switch — that is the real reason "there is no HDR in System Settings".

So the tool does this:

- **Turn HDR on** → switch to 5K@60Hz, enable HDR (the "High Dynamic Range" switch in System Settings follows)
- **Turn HDR off** → disable HDR and switch back to your original 144 Hz

The first time it has to try a few modes, about 5–7 s; afterwards it remembers the last successful mode and takes about 1.5 s.

### How the blackout was cut down

There are actually **two** blackouts: one for the display mode change (144 Hz → 60 Hz, the panel re-handshakes) and one for the system flipping the HDR flag. The old sequence was mode change → wait for the panel → then flip HDR, i.e. two blackouts with an SDR picture in between.

Three things now merge them into one:

1. **Fire the HDR request the moment the mode is submitted**, instead of waiting for the system to report "this mode supports HDR". Both land in the same re-sync; measured gap between request and effect is 0–6 ms.
2. **Don't turn HDR off separately** when switching off — just switch back to 144 Hz, which cannot carry HDR anyway, and the system drops HDR as a side effect. The old way was "HDR off, wait, then change mode", also two blackouts.
3. Polling interval from 100 ms to 20 ms, removing meaningless fixed waits.

Measured (`切换耗时` is written to the log, broken down by phase):

```
on : 656ms = apply mode 655ms + HDR takes effect 1ms   (was 1650ms, two blackouts)
off: 669ms = apply mode 615ms + settle 50ms            (was 1705ms)
```

The remaining ~620 ms is all `CGCompleteDisplayConfiguration` — the panel re-handshaking, a hardware floor that software cannot get around. The only way to be faster is not to change modes at all, and then HDR is impossible on this display.

If your display supports HDR in its native mode (Studio Display, Pro Display XDR, or a 4K panel with bandwidth to spare), the tool never touches resolution and just toggles HDR.

## How it works

macOS has no public HDR switch API, so the tool calls SkyLight private interfaces through `dlopen`:

- `CoreDisplay_Display_SupportsHDRMode(displayID)` — whether the current mode allows HDR
- `CoreDisplay_Display_IsHDRModeEnabled(displayID)` — current HDR state
- `SLSDisplaySetHDRModeEnabled(displayID, enabled)` — toggle HDR

This is the same code path the System Settings switch uses, so the state stays perfectly in sync.

Caveat: private interfaces may be renamed or re-signatured in a major OS release; recompiling usually fixes it (find the symbols again with `nm -gU` or `strings` on `SkyLight`).

## Icon

The icon is drawn in code, there is no image asset: `Tools/makeicon.swift` renders on a 2048 canvas with CoreGraphics and downsamples to 1024. Change colours or proportions by editing the numbers in the script and regenerating.

```bash
swift Tools/makeicon.swift build/icon/AppIcon-1024.png
```

**Design**: a sphere cut at 45° on a dark plate — the lower left sinks into shadow, the upper right is hit by hard light, a highlight line sits on the boundary, a halo surrounds it. HDR is precisely "deep black and blinding highlight in the same frame", and one sphere says it; no letters, no text, still readable at 32 px.

**Two pitfalls**:

- ⚠️ **It must be full-bleed.** The macOS 26/27 icon spec is a shape filling the whole canvas, with the system applying the rounded mask. The first version kept a 100 px transparent margin per the old spec, and the system treated the transparent area as empty and put a white glass plate behind it — the icon became "a dark blob inside a white frame". Full-bleed fixed it.
- The outer halo needs **additive blending** (`plusLighter`), not ordinary alpha — plain alpha stains the dark plate an ugly brown; additive is "light added on top of dark", and dark stays dark. The spill is also clipped to the lit side only; on the dark side it smears into grey fog.

The bundling flow is in `build.sh` (`Resources/AppIcon.icns` → `Contents/Resources/`), with `CFBundleIconFile` in Info.plist pointing at `AppIcon`. All sizes are produced from 1024 with `sips` and packed into an icns with `iconutil`.

## Packaging a DMG

```bash
./package.sh
# → build/HDRSwitch-<version>.dmg
```

The script does four things: `./build.sh` → build arm64 and x86_64 separately and `lipo` them into a universal binary → lay out the contents → compress to UDZO with `hdiutil` and verify.

What is on the disk image:

```
HDRSwitch.app
Applications -> /Applications        drag across to install
使用说明.html                         full manual (open in a browser, ⌘P to save as PDF)
安装说明.txt                          first-launch block, required grants, how to uninstall
可选组件（共享识别）/                  optional component (share detection)
    hdrswitch-smbdump                 read-only helper
    install-helper.sh                 installs it plus the sudoers rule
    安装共享识别.command                double-click (asks for the admin password once)
```

The helper is shipped inside the image so another machine can install it without going back to the source tree — it originally relied on relative paths into `build/` and `Tools/`, which don't exist inside a DMG.

**Two limitations** (both environmental, not script bugs):

- No custom window with icon positions and a background image. That needs Finder automation permission, which the script process is denied (`-10004`). What you get is the standard app + Applications drop target.
- No volume icon either (`.VolumeIcon.icns` plus a custom icon bit): setting it requires mounting the DMG writable, and mounting is refused in this environment. The volume shows up with a generic disk icon on the desktop, which doesn't affect use.

Roughly 1.2 MB; it only depends on system frameworks, so there is no third-party library to bundle.

## Uninstall

```bash
# quit from the menu first, then
rm -rf /Applications/HDRSwitch.app
defaults delete com.wangjin.hdrswitch
```

## Known limitations

- Only verified on Apple Silicon + macOS 26/27
- Some displays (especially behind adapters or docks) never report HDR capability at all, and no software can turn it on for them
- In HDR mode, changing resolution or refresh rate by hand can desynchronise the state; a single HDR toggle restores it
- Automatic mode judges by "who is really playing" (holding the anti-sleep assertion / being the now-playing app / being frontmost / **still having the source open**), so a paused-but-not-closed player keeps HDR on; it drops back only when the player quits or unloads the file
- Toggling HDR always involves a display mode change and therefore a brief blackout (about 0.7 s measured, see above), and in full-screen playback the window may be moved to another desktop by the system — macOS behaviour, unavoidable
- Infuse playing from the **local share**: precise detection supported (via the privileged helper reading `smbd` handles); playing from a **remote NAS / media server**: no quality information, doesn't switch by default
- The privileged helper lives at `/usr/local/libexec/hdrswitch-smbdump`; remove it with the two `sudo rm -f` paths above. Rebuilding the app doesn't affect it
- Web video relies on the browser executing JS to read quality: unreadable means "unknown", no switch. So **an SDR web page is never switched by mistake**, at the cost of not switching when the quality label reads "Auto" or the page structure changes a lot (a Bilibili redesign)
- Tencent Video's verdict depends on its playback core's log format (`hdr type=` / `isHDRVideo=` in the current 2.188 build): should that format change or logging be turned off, it falls back to "quality unreadable, no switch" — never a wrong switch, just no automatic switching. The logs live in `~/Library/Containers/com.tencent.tenvideo/Data/Library/Logs`, and `HDRSwitch why` prints that path
- Web probing only works **in the menu bar app process**: running `HDRSwitch sessions/why` in a terminal fails because "the sender has no automation grant" — that is how the system decides, not a bug. To see the last decision, use `defaults read com.wangjin.hdrswitch autoLastSession`
- Infuse over network streaming (no file handle) can't be judged for quality and won't switch HDR by default; enable "Turn on HDR when the source can't be identified" in the menu if you want it to
- Troubleshooting: run `HDRSwitch why` first — it lists display state, live detection results, whether automation was overridden manually, failure counts and the recent log in one go
- For per-round decision logs: `defaults write com.wangjin.hdrswitch debugLog -bool true` and restart the app (action-level events are always written to `~/Library/Logs/HDRSwitch.log`, which is truncated past 512 KB)

## License

[MIT](LICENSE) © 2026 lsjingyun

Use it, change it, sell it — just keep the copyright notice and the licence text in any copy. The software is provided "as is", with no warranty of any kind.

Two things worth spelling out:

- The interfaces this tool calls (SkyLight's `CoreDisplay_*` / `SLSDisplaySetHDRModeEnabled`) are Apple private APIs and are **not covered by this licence**. Whether you want to rely on them in something you ship is your call.
- You can relicense the project later (GPL, Apache-2.0, or a commercial licence) whenever you like — there are no outside contributors whose consent would be needed today.

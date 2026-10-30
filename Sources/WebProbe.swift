// WebProbe.swift — 网页视频画质探测
//
// 为什么需要这个：浏览器里的网页视频，解码数据和色彩标记全在浏览器进程内存里，
// macOS 不对外暴露「当前网页视频是不是 HDR」。唯一的办法是回到页面里问一句。
//
// 做法：通过 AppleScript 让浏览器在当前标签页执行一小段 JS，读三样东西：
//   1. 有没有 <video> 真的在播（不是暂停、有画面尺寸）；
//   2. 播放器控件上显示的清晰度标签（B 站的「HDR 真彩 / 杜比视界 / 1080P」就在这里）；
//   3. 播放器自己的内部状态（B 站 player.getQuality()、YouTube 的 getStatsForNerds()）。
//
// 权限前提（一次性）：
//   Safari：设置 → 高级 → 勾「显示网页开发者功能」，再在菜单「开发」里勾
//           「允许来自 Apple 事件的 JavaScript」
//   Chrome/Edge：菜单 查看 → 开发者 → 允许来自 Apple 事件的 JavaScript
//   另外系统会弹一次「HDRSwitch 想要控制 Safari」的自动化授权。
//
// 拿不到权限时一律返回 nil（= 画质未知），自动模式就退回「网页不切」，不会乱切。

import Foundation

struct WebProbeResult {
    let verdict: HDRVerdict
    let detail: String
    /// 片源本身带 HDR 流，但当前画质不是 HDR（YouTube 在 SDR 下会把 HDR 选项藏起来）
    var hdrAvailable = false
    /// 页面里的视频是「暂停」状态（画面停在那一帧上）
    var paused = false
}

enum WebProbe {
    static let helperQueue = DispatchQueue(label: "com.wangjin.hdrswitch.webprobe")

    private static var cache: [String: (at: Date, result: WebProbeResult?)] = [:]
    private static var statusCache: (at: Date, text: String)?
    private static var lastLoggedError = ""
    /// 权限没开这类「问了也白问」的错误，30 秒内不再重试，避免每秒去 spawn 一次 osascript
    private static var errorBackoff: Date?
    /// 进程内第一次调用——可能要等系统授权框，超时放宽
    private static var firstCall = true
    /// 显示器当前是否已经 HDR（由 AutoHDR 每轮写入），页面脚本据此决定要不要重建播放器
    static var displayHDR = false
    /// 显示器当前模式的像素高度（HDR 下是 2880）。用来给「直接选 4K HDR」封顶：
    /// 8K 片源（YouTube 上确实有）不该被拉到 4320p —— 面板只有 5K，
    /// 8K 解码 + 带宽双重压力会把播放拖到卡顿，卡顿又会被判成「没在播」，来回抖
    static var displayPixelHeight = 0
    /// 上一次由我们发起播放器重建的时间。重建那几秒会看不到播放会话，
    /// 自动逻辑不能当成「播放结束」立刻把 HDR 收回去，否则会来回翻
    private static var lastReinitAt: Date?
    static var reinitGraceActive: Bool {
        guard let t = lastReinitAt else { return false }
        return Date().timeIntervalSince(t) < 15
    }
    /// 上一次「成功读到画质」的时间。网页换集/切歌的一两秒里脚本会抓空，
    /// 这时候不该立刻按 SDR 收 HDR，先看这个时间点还新不新
    private static var lastJudgedAt: Date?
    static func recentlyJudged(_ within: TimeInterval = 60) -> Bool {
        guard let t = lastJudgedAt else { return false }
        return Date().timeIntervalSince(t) < within
    }

    /// 每个浏览器最近一次「确实在播网页视频」的时间（暂停保持要用）
    private static let playLock = NSLock()
    private static var lastPlayingAt: [String: Date] = [:]

    private static func markPlaying(_ bundleID: String) {
        playLock.lock(); lastPlayingAt[bundleID] = Date(); playLock.unlock()
    }

    private static func playingAt(_ bundleID: String) -> Date? {
        playLock.lock(); defer { playLock.unlock() }
        return lastPlayingAt[bundleID]
    }

    /// 最近一次读到的播放健康度（readyState / 缓冲 / 帧计数 / 前进量）。
    /// 断流时页面里 video 还在、但画面不再推进，全靠这组数字分辨。
    private(set) static var lastHealth = ""
    /// 最近一次「卡住」（video 存在但播不动）的时间点
    private static var lastStallAt: Date?
    /// 卡住之后又恢复正常播放，就把标记清掉，免得一次意外卡顿被当成持续故障
    static func stalledRecently(_ within: TimeInterval = 20) -> Bool {
        guard let t = lastStallAt else { return false }
        return Date().timeIntervalSince(t) < within
    }
    static func healthLine() -> String { lastHealth }

    /// 网页实测画质总开关
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoWebProbe") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoWebProbe") }
    }

    /// YouTube 在 SDR 显示器上会隐藏 HDR 选项（先有鸡还是先有蛋）。
    /// 打开后：查到片源带 HDR 流就先切 HDR，让选项出来 —— 默认开
    static var unlockHiddenHDR: Bool {
        get { UserDefaults.standard.object(forKey: "webUnlockHiddenHDR") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "webUnlockHiddenHDR") }
    }

    /// 解锁之后直接替用户把画质拉到「HDR 版本里最高的那一档」（有 4K HDR 就 4K HDR）。
    /// 默认开：不然 YouTube 会自己退回 1080p，还得手动点菜单
    static var forceTopHDR: Bool {
        get { UserDefaults.standard.object(forKey: "webForceTopHDR") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "webForceTopHDR") }
    }

    // MARK: - 页面里跑的 JS

    private static let js = """
    (function(){
      try{
        var out={play:0};
        /* 脚本版本号：每次改动脚本就把版本提一下，页面里那些常驻定时器
           （画质拉档、断流看门狗）会被清掉重建，免得用户还得手动刷新页面
           才能用上新逻辑。 */
        var __hdrsVer='v4';
        if(window.__hdrsVer!==__hdrsVer){
          window.__hdrsVer=__hdrsVer;
          try{ if(window.__hdrsQualTimer){ clearInterval(window.__hdrsQualTimer); window.__hdrsQualTimer=null; } }catch(eV1){}
          try{ if(window.__hdrsWatch){ clearInterval(window.__hdrsWatch); window.__hdrsWatch=null; } }catch(eV2){}
          window.__hdrsFixed=null; window.__hdrsStuck=0;
          window.__hdrsPullN=0; window.__hdrsPullAt=0; window.__hdrsWatchT=null;
        }
        /* 目标档 → 允许的下限档。锁区间而不是锁单档：单一档位一旦取不到数据，
           SABR 不会自己降档重试，就停在缓冲区末尾干等（断流）；
           留一档余量它就能先降下来继续播，网络好了再爬回去。 */
        var lowerOf=function(q){
          return q==='highres'?'hd1440' : q==='hd2160'?'hd1440' : q==='hd1440'?'hd1080'
               : q==='hd1080'?'hd720' : 'default';
        };
        /* 显示器回到 SDR 后，下次再开 HDR 应该允许重新重建一次播放器 */
        if(!(typeof __hdrsHDR!=='undefined' && __hdrsHDR)){ window.__hdrsReinit=null; }
        /* 断流看门狗：5 秒一轮盯着 currentTime 有没有前进、缓冲还剩多少。
           YouTube 偶尔会停在缓冲区末尾、网络活动归零（"L" 标记 + 0 KB），
           这时页面不会自己恢复，只能从外面推它一把。三级救援，逐级加力，
           全都不成就放弃这个视频的高画质目标，让 YouTube 自己按带宽选。 */
        try{
          if(!window.__hdrsWatch){
            window.__hdrsWatch=setInterval(function(){
              try{
                if(!(typeof __hdrsHDR!=='undefined' && __hdrsHDR)){ window.__hdrsStuck=0; return; }
                var vs2=document.querySelectorAll('video'), vv=null;
                for(var i2=0;i2<vs2.length;i2++){
                  if(!vs2[i2].paused && !vs2[i2].ended && vs2[i2].videoWidth>0){ vv=vs2[i2]; break; }
                }
                if(!vv){ window.__hdrsStuck=0; return; }
                var now=vv.currentTime, prev=window.__hdrsWatchT;
                var adv=(typeof prev==='number')?(now-prev):1;
                window.__hdrsWatchT=now;
                var buf=0; try{ if(vv.buffered.length){ buf=vv.buffered.end(vv.buffered.length-1)-now; } }catch(eW){}
                if(adv<=0.05 && buf<1){ window.__hdrsStuck=(window.__hdrsStuck||0)+1; }
                else{
                  window.__hdrsStuck=0;
                  /* 画面健康就把目标档拉回来。解锁档位之后 YouTube 会因为「刚才断过」
                     自己降得很难看（实测直接掉到 720p 就不肯回升），而带宽明明是够的。
                     节制地拉：15 秒最多一次、总共 8 次，只在健康时动手，不和播放器抢。 */
                  var w3=window.__hdrsWant||'';
                  var mp3=document.getElementById('movie_player');
                  if(w3 && mp3){
                    var rank=function(x){
                      return x==='highres'?5 : x==='hd2160'?4 : x==='hd1440'?3
                           : x==='hd1080'?2 : x==='hd720'?1 : 0;
                    };
                    var cur3=(typeof mp3.getPlaybackQuality==='function')?mp3.getPlaybackQuality():'';
                    if(w3!==window.__hdrsPullFor){ window.__hdrsPullFor=w3; window.__hdrsPullN=0; window.__hdrsPullAt=0; }
                    var since=Date.now()-(window.__hdrsPullAt||0);
                    /* 刚救过场就先别急着锁档，让 SABR 自己稳 60 秒再说，
                       否则会变成「锁上→断流→解锁→再锁上」的循环 */
                    var calm=Date.now()-(window.__hdrsRescueAt||0);
                    if(cur3 && rank(cur3)<rank(w3) && since>15000 && calm>60000 && (window.__hdrsPullN||0)<8){
                      window.__hdrsPullAt=Date.now();
                      window.__hdrsPullN=(window.__hdrsPullN||0)+1;
                      try{ if(mp3.setPlaybackQualityRange) mp3.setPlaybackQualityRange(lowerOf(w3), w3); }catch(eP1){}
                      try{ if(mp3.setPlaybackQuality) mp3.setPlaybackQuality(w3); }catch(eP2){}
                    }
                  }
                }
                var n=window.__hdrsStuck||0;
                var mp2=document.getElementById('movie_player');
                /* 第 2 轮（约 10 秒）：先解锁档位，让 SABR 重新自适应 */
                if(n===2){
                  window.__hdrsRescueAt=Date.now();
                  try{ if(mp2&&mp2.setPlaybackQualityRange) mp2.setPlaybackQualityRange('default','default'); }catch(e1){}
                  window.__hdrsFixed=null; window.__hdrsFixTries=0;
                }
                /* 第 4 轮（约 20 秒）：轻轻 seek 一下，触发重新请求分片 */
                if(n===4){
                  try{ vv.currentTime=Math.max(0, now+0.4); }catch(e2){}
                  try{ vv.play(); }catch(e3){}
                }
                /* 第 8 轮（约 40 秒）：放弃高画质，退回自适应 */
                if(n>=8){ window.__hdrsWant=''; window.__hdrsStuck=0; window.__hdrsFixed=null; }
              }catch(e){}
            }, 5000);
          }
        }catch(eW0){}
        var vs=document.querySelectorAll('video'), v=null, fb=null, pv=null;
        for(var i=0;i<vs.length;i++){
          var e=vs[i];
          if(!e.paused && !e.ended && e.readyState>=2 && e.videoWidth>0){ v=e; break; }
          if(!fb && !e.paused && !e.ended) fb=e;
          /* 暂停中的那个 video 也记下来：暂停时它既不在播、也不算卡住，
             但它停的那一帧还是 HDR，画质码也还挂在播放器上 —— 拿它判断
             「这一场还没结束」，别一按暂停就把 HDR 收回去。 */
          if(!pv && e.paused && !e.ended && e.videoWidth>0 && (e.currentTime>0 || e.duration>1)) pv=e;
        }
        /* 播放健康度。断流时（解码卡死、缓冲耗尽）播放器会自己暂停，或者 readyState
           掉到 2 以下、画面不再推进 —— 这时上面那条严格条件选不到 video，外面只能
           看到「没在播，色彩未知」，分不清是「用户暂停了」还是「HDR 下卡死了」。
           所以这里把卡住的那个 video 也捞出来，报出它的真实状态。 */
        var health=function(el){
          if(!el) return '';
          var t=Number(el.currentTime||0), adv=-1;
          if(typeof window.__hdrsPrevT==='number'){ adv=Math.round((t-window.__hdrsPrevT)*10)/10; }
          window.__hdrsPrevT=t;
          var buf=0;
          try{ if(el.buffered.length){ buf=Math.round((el.buffered.end(el.buffered.length-1)-t)*10)/10; } }catch(eH){}
          var fr=-1, dp=-1;
          try{ var q2=el.getVideoPlaybackQuality?el.getVideoPlaybackQuality():null;
               if(q2){ fr=q2.totalVideoFrames; dp=q2.droppedVideoFrames; } }catch(eQ){}
          var line=' rs='+el.readyState+' ns='+el.networkState+' adv='+adv
               + ' buf='+buf+' fr='+fr+' dp='+dp+' er='+((el.error&&el.error.code)||0);
          /* 卡住时把播放器的网络读数一起带出来：bufferHealth 是「还能播多少秒」，
             networkActivity 是「当前下载速度」。两者都接近 0 说明请求根本没回来
             （被掐断/限流），有速度但缓冲不涨才是带宽不够。 */
          if(adv<=0 || el.readyState<3){
            try{ var mz=document.getElementById('movie_player');
                 if(mz&&typeof mz.getStatsForNerds==='function'){
                   line+=' nerd='+JSON.stringify(mz.getStatsForNerds()).slice(0,700);
                 } }catch(eN){}
          }
          return line;
        };
        if(!v){
          if(fb){
            out.play=0; out.stall=1; out.host=location.hostname;
            out.w=fb.videoWidth; out.h=fb.videoHeight;
            out.txt='stall';
            out.health=health(fb).trim();
            return JSON.stringify(out);
          }
          if(!pv) return JSON.stringify(out);
          /* 暂停：按「还在播」的路子把画质读出来，只是 play=0 + paused=1。
             外面据此保持 HDR，而不是当成播放结束。 */
          v=pv; out.paused=1; out.play=0;
        }
        if(!out.paused){ out.play=1; }
        out.w=v.videoWidth; out.h=v.videoHeight;
        out.host=location.hostname;
        var t='';
        var q=document.querySelector('.bpx-player-ctrl-quality-result');
        if(q && q.textContent) t+=' q='+q.textContent.trim().replace(/\\s+/g,'_');
        try{ if(window.player && typeof window.player.getQuality==='function'){
              var g=window.player.getQuality();
              // B 站新版返回的是对象，真正的画质码在 qn / quality 里
              var code=(g && typeof g==='object') ? (g.qn||g.quality||g.code||'') : g;
              if(code!=='') t+=' api='+String(code);
        } }catch(e1){}
        try{ var mp=document.getElementById('movie_player');
             if(mp && typeof mp.getStatsForNerds==='function'){
               var st=mp.getStatsForNerds();
               t+=' yt='+(st.color||'')+'/'+(st.resolution||'');
             } }catch(e2){}
        /* YouTube 的 HDR 死结：显示器不是 HDR 时，它干脆不给你 HDR 选项。
           但片源有没有 HDR 版本，跟显示器无关 —— 这些信息在页面的播放响应里，
           每个流的 colorInfo 都写着传输特性。查一遍就能提前知道。
           注意字段值的真实写法是 COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084 /
           COLOR_PRIMARIES_BT2020，所以必须用包含匹配，不能全等。
           顺手把「HDR 版本里最高的分辨率」记下来：切过去以后直接拉满这一档。 */
        var srcMax=0, want='', hdrHeights=[], hdrSrc='';
        try{
          /* 两个来源：播放器自己的 getPlayerResponse()，和页面上的
             window.ytInitialPlayerResponse。前者才是「当前这条视频」的权威数据 ——
             YouTube 是单页应用，从列表点进来、排行榜自动播下一首时，
             ytInitialPlayerResponse 根本不会跟着换，照它判断就会一直读到
             「片源没有 HDR」，于是永远不切（这就是 59Rn4F8bfY4 那次的原因）。 */
          var scanHDR=function(o){
            var r={has:false,max:0,hs:[]};
            var sd=o&&o.streamingData; if(!sd) return r;
            var arr=sd.adaptiveFormats||[];
            for(var i2=0;i2<arr.length;i2++){
              var ci=arr[i2].colorInfo;
              var sg=ci?(String(ci.transferCharacteristics||'')+' '+String(ci.primaries||'')):'';
              if(sg.indexOf('2084')>=0||sg.indexOf('B67')>=0||sg.indexOf('HLG')>=0||sg.indexOf('BT2020')>=0){
                r.has=true;
                var hv=Number(arr[i2].height||0);
                if(!hv){ hv=parseInt(String(arr[i2].qualityLabel||''),10)||0; }
                if(hv>0){ r.hs.push(hv); if(hv>r.max) r.max=hv; }
              }
            }
            return r;
          };
          var pr=null, usePr=false;
          try{ var mp0=document.getElementById('movie_player');
               if(mp0&&typeof mp0.getPlayerResponse==='function'){
                 pr=mp0.getPlayerResponse();
                 usePr=!!(pr&&pr.streamingData);
               } }catch(e0){}
          var sPr=usePr?scanHDR(pr):null;
          var sPage=scanHDR(window.ytInitialPlayerResponse);
          var best=usePr?sPr:sPage;
          hdrSrc = usePr ? 'player' : (sPage.has?'page':'');
          hdrHeights=best.hs; srcMax=best.max;
          if(best.has) t+=' avail=hdr';
          if(srcMax>0) t+=' srcmax='+srcMax;
          if(best.has && hdrSrc) t+=' avsrc='+hdrSrc;
          /* 记下判的是哪条视频：排行榜/自动连播时换片很勤，
             日志里没有 id 就分不清「判错了」还是「已经换片了」 */
          try{ var vdd=(mp0&&typeof mp0.getVideoData==='function')?mp0.getVideoData():null;
               if(vdd&&vdd.video_id) t+=' vid='+vdd.video_id; }catch(e0b){}
          /* 目标档位：HDR 版本里「不超过屏幕像素高度」的最高一档。
             8K 片源在 5K 面板上就退到 2160p —— 多出来的像素看不见，只会拖卡。
             所有 HDR 档都比屏幕高的话干脆不指定，让 YouTube 自己按带宽选。 */
          if(typeof __hdrsForce!=='undefined' && __hdrsForce && hdrHeights.length>0){
            var cap=(typeof __hdrsCapH!=='undefined')?Number(__hdrsCapH||0):0;
            var pick=0;
            for(var k=0;k<hdrHeights.length;k++){
              var hk=hdrHeights[k];
              if((cap<=0||hk<=cap)&&hk>pick) pick=hk;
            }
            if(pick>=720){
              want = pick>=4320?'highres' : pick>=2160?'hd2160' : pick>=1440?'hd1440'
                   : pick>=1080?'hd1080' : 'hd720';
            }
          }
          window.__hdrsWant = want || '';
          if(want) t+=' want='+want;
          var mq=document.getElementById('movie_player');
          if(mq&&typeof mq.getPlaybackQuality==='function'){
            var qq=mq.getPlaybackQuality();
            if(qq) t+=' yq='+String(qq);
            /* 能不能由外部改画质——不能的话「直接选 4K HDR」这步会白等，
               日志里一眼就能看出来 */
            t+=' canfix='+((typeof mq.setPlaybackQualityRange==='function')?1:0);
          }
        }catch(e3){}
        /* 显示器已经是 HDR 了，但播放器还在放 SDR 那条流 —— 因为它的可用格式列表
           是初始化时按当时的能力建的，之后不会自己重算。带着当前进度重建一次播放器，
           它才会把 2160p HDR 拿出来。每个页面只做一次，避免反复打断。 */
        try{
          if(typeof __hdrsHDR!=='undefined' && __hdrsHDR && !out.paused
             && t.indexOf('avail=hdr')>=0 && t.indexOf('yt=bt2020')<0 && t.indexOf('yt=smpte2084')<0){
            var mpr=document.getElementById('movie_player');
            if(mpr && typeof mpr.loadVideoByPlayerVars==='function' && typeof mpr.getVideoData==='function'){
              var vd=mpr.getVideoData();
              /* 按视频 id 记，而不是记一个「已经做过」的布尔值：
                 YouTube 是单页应用，换视频不重载页面，布尔值会一直粘住。 */
              if(vd && vd.video_id && window.__hdrsReinitFor!==vd.video_id){
                window.__hdrsReinitFor=vd.video_id;
                window.__hdrsReinitCount=0;
              }
              /* 同一个视频最多重建两次。万一重建后画面卡住、检测看不到播放，
                 HDR 会被收回去，下一轮又会重建 —— 有次数上限就不会无限循环。 */
              if(vd && vd.video_id && window.__hdrsReinit!==vd.video_id
                 && (window.__hdrsReinitCount||0)<2){
                window.__hdrsReinit=vd.video_id;
                window.__hdrsReinitCount=(window.__hdrsReinitCount||0)+1;
                var ct=typeof mpr.getCurrentTime==='function'?mpr.getCurrentTime():0;
                mpr.loadVideoByPlayerVars({videoId:vd.video_id, start:Math.floor(ct||0)});
                /* 播放器重建了，画质也要重新拉一次 */
                window.__hdrsFixed=null;
                window.__hdrsFixTries=0;
                window.__hdrsFixFor=null;
                t+=' reinit=1';
              }
            }
          }
        }catch(e4){}
        /* 页面内的小循环：等播放器把「4K HDR」这一档列出来，然后一次性把画质拉过去。
           为什么不靠 AppleScript 定时探测来干：那个几秒才跑一次，等它反应过来
           YouTube 早就自己退回 1080p 了。页面自己盯，2.5 秒一轮，及时得多。 */
        try{
          if(!out.paused && want && !window.__hdrsQualTimer){
            window.__hdrsQualTimer=setInterval(function(){
              try{
                if(!(typeof __hdrsHDR!=='undefined' && __hdrsHDR)){
                  window.__hdrsFixed=null; window.__hdrsFixTries=0; return;
                }
                var m=document.getElementById('movie_player');
                if(!m) return;
                var w2=window.__hdrsWant||'';
                if(!w2) return;
                var vd2=(typeof m.getVideoData==='function')?m.getVideoData():null;
                var vid2=(vd2&&vd2.video_id)?vd2.video_id:'';
                if(!vid2) return;
                if(window.__hdrsFixed===vid2) return;              /* 这条已经调好了 */
                if(window.__hdrsFixFor!==vid2){ window.__hdrsFixFor=vid2; window.__hdrsFixTries=0; }
                if((window.__hdrsFixTries||0)>16) return;          /* 40 秒还不行就收手，别打架 */
                var st2={}; try{ st2=(m.getStatsForNerds?m.getStatsForNerds():{})||{}; }catch(e){}
                var col=String(st2.color||'').toLowerCase();
                var isH=(col.indexOf('bt2020')>=0||col.indexOf('2084')>=0||col.indexOf('hlg')>=0);
                var cur=(m.getPlaybackQuality?m.getPlaybackQuality():'');
                if(cur===w2 && isH){
                  /* 到位就收手，但**不解锁档位**：区间锁已经留了降档余地，
                     解锁反而会让 YouTube 掉到 720p 且不肯回升。 */
                  window.__hdrsFixed=vid2;
                  return;
                }
                var lv=[]; try{ lv=(m.getAvailableQualityLevels?m.getAvailableQualityLevels():[])||[]; }catch(e){}
                window.__hdrsFixTries=(window.__hdrsFixTries||0)+1;
                /* 这一档还没在列表里（刚重建，格式表还在算）—— 等下一轮 */
                if(lv.length && lv.indexOf(w2)<0) return;
                try{ if(m.setPlaybackQualityRange) m.setPlaybackQualityRange(lowerOf(w2), w2); }catch(e){}
                try{ if(m.setPlaybackQuality) m.setPlaybackQuality(w2); }catch(e){}
              }catch(e){}
            }, 2500);
          }
        }catch(e5){}
        out.txt=t.trim();
        try{ out.health=health(v).trim(); }catch(e6){}
        return JSON.stringify(out);
      }catch(err){ return JSON.stringify({play:0,err:String(err)}); }
    })()
    """

    // MARK: - AppleScript

    private static func script(for appName: String, safariStyle: Bool) -> String {
        // 两轮扫描：
        //   1. 先找「正在播」的那一页 —— 有在播的当然以它为准；
        //   2. 没有在播的，就找「暂停着但还开着」的那一页。
        // 第二条是关键：用户暂停后去看别的标签，那个页面还在后台开着，
        // 以前脚本只认 play:1，切走之后这里就抓空，上层判成「播放结束」，
        // 屏幕立刻掉回 SDR。现在把暂停页的结果也带回来，只要它还没被关掉，
        // HDR 就一直挂着。
        let body: String
        if safariStyle {
            // 先问「当前正在看的那一页」：开了好几个视频标签时，
            // 要判定的显然是眼前这个，而不是最左边那个还在后台响的
            body = """
            tell application "\(appName)"
                set fb to ""
                try
                    set r0 to (do JavaScript js in current tab of front window)
                    if r0 contains "\\"play\\":1" then return r0
                    if r0 contains "\\"paused\\":1" then set fb to r0
                end try
                set n to count of documents
                if n = 0 then return fb
                repeat with i from 1 to n
                    try
                        set r to (do JavaScript js in document i)
                        if r contains "\\"play\\":1" then return r
                        if fb is "" and r contains "\\"paused\\":1" then set fb to r
                    end try
                end repeat
                return fb
            end tell
            """
        } else {
            body = """
            tell application "\(appName)"
                set fb to ""
                try
                    set r0 to (execute (active tab of front window) javascript js)
                    if r0 contains "\\"play\\":1" then return r0
                    if r0 contains "\\"paused\\":1" then set fb to r0
                end try
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set r to (execute t javascript js)
                            if r contains "\\"play\\":1" then return r
                            if fb is "" and r contains "\\"paused\\":1" then set fb to r
                        end try
                    end repeat
                end repeat
                return fb
            end tell
            """
        }
        return "on run argv\nset js to item 1 of argv\n\(body)\nreturn \"\"\nend run"
    }

    /// 浏览器 bundle id → (AppleScript 里的应用名, 是否 Safari 语法)
    private static func browserInfo(_ bundleID: String) -> (name: String, safari: Bool)? {
        let table: [(String, String, Bool)] = [
            ("com.apple.SafariTechnologyPreview", "Safari Technology Preview", true),
            ("com.apple.Safari", "Safari", true),
            ("com.google.Chrome.canary", "Google Chrome Canary", false),
            ("com.google.Chrome", "Google Chrome", false),
            ("com.microsoft.edgemac", "Microsoft Edge", false),
            ("company.thebrowser.Browser", "Arc", false),
            ("com.brave.Browser", "Brave Browser", false),
            ("com.vivaldi.Vivaldi", "Vivaldi", false),
            ("org.chromium.Chromium", "Chromium", false),
            ("com.operasoftware.Opera", "Opera", false)
        ]
        for (id, name, safari) in table where bundleID.hasPrefix(id) { return (name, safari) }
        return nil
    }

    // MARK: - 对外

    /// 探测某个浏览器此刻在播的网页视频画质。拿不到信息时返回 nil（= 未知，不切）
    static func probe(bundleID: String) -> WebProbeResult? {
        guard enabled, let info = browserInfo(bundleID) else { return nil }

        var cached: (at: Date, result: WebProbeResult?)?
        var backingOff = false
        helperQueue.sync {
            if let c = cache[bundleID], Date().timeIntervalSince(c.at) < 3 { cached = c }
            if let t = errorBackoff, Date().timeIntervalSince(t) < 30 { backingOff = true }
        }
        if let c = cached { return c.result }
        if backingOff { return nil }

        let started = Date()
        let (json, error) = run(script(for: info.name, safariStyle: info.safari),
                                js: "var __hdrsHDR=\(displayHDR && unlockHiddenHDR);\n"
                                  + "var __hdrsForce=\(forceTopHDR);\n"
                                  + "var __hdrsCapH=\(displayPixelHeight);\n" + js)

        var result: WebProbeResult?
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let playing = (obj["play"] as? Int) == 1
            let stalled = (obj["stall"] as? Int) == 1
            if let h = obj["health"] as? String, !h.isEmpty {
                lastHealth = h
                if stalled { lastStallAt = Date() }
            }
            if playing {
                result = judge(obj)
                if result != nil {
                    lastJudgedAt = Date()
                    markPlaying(bundleID)
                }
                // 记下「刚刚重建过播放器」的时间点：随后几秒看不到播放会话是正常的
                if (obj["txt"] as? String ?? "").contains("reinit=1") { lastReinitAt = Date() }
            } else if (obj["paused"] as? Int) == 1 {
                // 暂停：画面停在那一帧上，画质（B 站画质码 / 控件标签）还留着。
                // 交给上层判断「这一场还没结束」，别一暂停就把 HDR 收回去。
                // 读不到画质也别急着否定 —— 页面还在就还有可能是 HDR，
                // 上层会拿「上次判过的结果」接上。
                if var r = judge(obj) {
                    r.paused = true
                    result = r
                } else {
                    result = WebProbeResult(verdict: .unknown,
                                            detail: "网页暂停 · 画质未读到",
                                            paused: true)
                }
            }
        }

        if !error.isEmpty {
            // 权限没开之类的问题，只记一次，免得日志被刷满
            if error != lastLoggedError {
                lastLoggedError = error
                Log.write("网页探测失败：\(error)", force: true)
            }
        }

        helperQueue.sync {
            cache[bundleID] = (Date(), result)
            statusCache = (Date(), error.isEmpty ? "可用" : error)
            errorBackoff = error.isEmpty ? nil : Date()
            if Date().timeIntervalSince(started) > 1.5 {
                Log.write("网页探测耗时较长（\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒）", force: true)
            }
        }
        return result
    }

    /// 网页视频暂停时还能不能算「这一场还在」。
    ///
    /// 判据：那个浏览器里还开着这一页（页面里的 `<video>` 还停在那一帧），
    /// 并且它今天确实播过。切换标签、切到别的 App、最小化浏览器都不影响 ——
    /// 只要你没把那个网页关掉，HDR 就一直留着（用户明确要这个行为）。
    static func pausedProbe(bundleID: String) -> WebProbeResult? {
        guard enabled else { return nil }
        guard let r = probe(bundleID: bundleID), r.paused else { return nil }
        guard let t = playingAt(bundleID),
              Date().timeIntervalSince(t) < 6 * 3600 else { return nil }
        return r
    }

    /// 状态文案（菜单 / why 用）
    static func statusText() -> String {
        var cached: (at: Date, text: String)?
        helperQueue.sync { cached = statusCache }
        if let c = cached, Date().timeIntervalSince(c.at) < 120 { return c.text }
        return "尚未使用（播网页视频时才会探测）"
    }

    /// 主动自检：分两步问，分清卡在「控制 Safari 的授权」还是「Safari 的 JS 开关」
    static func selfTest() -> String {
        guard let info = browserInfo("com.apple.Safari") else { return "不支持 Safari" }

        // 第一步：只数窗口——不需要 JS 权限，但确实要发一条 Apple 事件。
        // （不能用「取名字」来判断：那一步是本地解析，不发事件，永远成功）
        let (_, connErr) = run("tell application \"\(info.name)\" to count of windows", js: nil)
        if !connErr.isEmpty {
            return "拿不到 Safari 的响应：\(connErr)"
        }

        // 第二步：执行一句最简 JS——这一步才受 Safari 的 JS 开关限制
        let (out, jsErr) = run(script(for: info.name, safariStyle: info.safari),
                               js: "JSON.stringify({play:1,selftest:1})")
        if !jsErr.isEmpty { return jsErr }
        if out.contains("selftest") { return "可以读取页面（JS 执行正常）" }
        return "JS 能执行，但 Safari 里没有打开的标签页"
    }

    // MARK: - 判定

    private static func judge(_ obj: [String: Any]) -> WebProbeResult? {
        let txt = (obj["txt"] as? String ?? "").lowercased()
        let host = (obj["host"] as? String ?? "").lowercased()
        let size = "\(obj["w"] as? Int ?? 0)×\(obj["h"] as? Int ?? 0)"

        guard !txt.isEmpty else { return nil }

        // YouTube 的「片源自带 HDR 流」标记单独摘出来，免得它干扰后面的标签匹配
        let canPlayHDR = txt.contains("avail=hdr")
        let label = txt.replacingOccurrences(of: "avail=hdr", with: "")

        // 1) B 站画质码最可信 —— 它说的是「此刻真的在解哪条流」，
        //    而不是控件上可能还显示着「自动」的标签。
        //    B 站：80/112/116/120 = SDR 各档，125 = HDR，126 = 杜比视界
        if let code = apiCode(label) {
            let isHDR = code == 125 || code == 126
            let tag = isHDR ? "（HDR/杜比）" : ""
            return WebProbeResult(verdict: isHDR ? .hdr : .sdr,
                                  detail: "网页实测 \(size) · 画质码 \(code)\(tag)")
        }

        // 2) YouTube 正在播的这条流本身就是 HDR（getStatsForNerds 的 color 字段）
        if label.contains("yt=bt2020") || label.contains("yt=smpte2084") {
            return WebProbeResult(verdict: .hdr,
                                  detail: "网页实测 \(size) · 正在播 HDR · \(pretty(label, host: host))")
        }

        // 3) 控件标签：显示「自动」时说明没锁画质，也读不到画质码 → 不强行判断
        if label.contains("q=自动") || label.contains("q=auto") {
            if canPlayHDR && unlockHiddenHDR {
                return WebProbeResult(verdict: .hdr,
                                      detail: "网页可播 HDR · 当前为自动画质（先切以解锁）",
                                      hdrAvailable: true)
            }
            return nil
        }

        let hdrWords = ["hdr", "杜比", "dolby", "vision", "pq", "hlg", "2020", "2084"]
        if hdrWords.contains(where: { label.contains($0) }) {
            return WebProbeResult(verdict: .hdr,
                                  detail: "网页实测 \(size) · \(pretty(label, host: host))")
        }

        // 4) 画质明确是 SDR，但片源本身带 HDR 流。
        //    YouTube 就是卡在这里：显示器不是 HDR → 菜单里干脆没有 HDR 选项。
        //    先切过去让选项出现，用户（或播放器的自动画质）才可能选到 HDR。
        if canPlayHDR && unlockHiddenHDR {
            return WebProbeResult(verdict: .hdr,
                                  detail: "网页可播 HDR · 当前画质 \(pretty(label, host: host))（先切以解锁）",
                                  hdrAvailable: true)
        }

        return WebProbeResult(verdict: .sdr,
                              detail: "网页实测 \(size) · \(pretty(label, host: host))")
    }

    /// 从 `api=125` 这种 token 里取出画质码
    private static func apiCode(_ txt: String) -> Int? {
        for token in txt.split(separator: " ") where token.hasPrefix("api=") {
            return Int(token.dropFirst(4))
        }
        return nil
    }

    private static func pretty(_ txt: String, host: String) -> String {
        var parts: [String] = []
        for token in txt.split(separator: " ") {
            if token.hasPrefix("q=") { parts.append("清晰度 " + token.dropFirst(2)) }
            else if token.hasPrefix("api=") { parts.append("player " + token.dropFirst(4)) }
            else if token.hasPrefix("yt=") { parts.append("color " + token.dropFirst(3)) }
            else if token.hasPrefix("yq=") { parts.append("quality " + token.dropFirst(3)) }
            else if token.hasPrefix("srcmax=") { parts.append("HDR 源最高 " + token.dropFirst(7) + "p") }
            else if token.hasPrefix("want=") { parts.append("目标 " + qualityName(String(token.dropFirst(5)))) }
            else if token.hasPrefix("canfix=") { parts.append(token.hasSuffix("1") ? "可调画质" : "画质不可调") }
            else if token.hasPrefix("avsrc=") { parts.append("HDR 源信息取自" + (token.hasSuffix("player") ? "播放器" : "页面")) }
            else if token.hasPrefix("vid=") { parts.append("视频 " + token.dropFirst(4)) }
        }
        if parts.isEmpty { parts.append(txt) }
        return parts.joined(separator: " · ")
    }

    /// hd2160 → 2160p，方便日志里一眼看懂
    private static func qualityName(_ q: String) -> String {
        switch q {
        case "highres": return "4320p"
        case "hd2160": return "2160p"
        case "hd1440": return "1440p"
        case "hd1080": return "1080p"
        case "hd720": return "720p"
        default: return q
        }
    }

    // MARK: - 执行

    /// 返回 (stdout, 错误说明)。错误说明为空表示跑通了。js 为 nil 时不传脚本参数
    private static func run(_ script: String, js: String?) -> (String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        if let js = js {
            p.arguments = ["-e", script, "--", js]
        } else {
            p.arguments = ["-e", script]
        }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do { try p.run() } catch { return ("", "无法启动 osascript：\(error.localizedDescription)") }

        // 卡住的保护：正常 3 秒；但首次调用可能正在弹「HDRSwitch 想要控制 Safari」的系统框，
        // 那个框要等用户点，给足时间，否则会被我们自己杀掉。
        let limit: TimeInterval = firstCall ? 25 : 3
        firstCall = false
        let deadline = Date().addingTimeInterval(limit)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline { p.terminate(); timedOut = true; break }
            usleep(30_000)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let out = (String(data: outData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var err = (String(data: errData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if timedOut { return (out, "浏览器响应超时（3 秒）") }
        if err.contains("-1743") {
            return (out, "未允许控制浏览器（系统设置 → 隐私与安全性 → 自动化 → 勾选 HDRSwitch）")
        }
        if err.contains("-10004") || err.contains("权限违例") {
            return (out, "Safari 未开启：设置 → 高级 → 显示网页开发者功能，再到「开发者」标签勾「允许Apple事件中的JavaScript」")
        }
        if !err.isEmpty { err = err.split(separator: "\n").last.map(String.init) ?? err }
        return (out, err)
    }
}

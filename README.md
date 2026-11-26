# 书影 ani

自用聚合 App(HarmonyOS / ArkTS):漫画(copymanga)、影视(苹果 CMS)、直播(IPTV)、动漫资源雷达(AnimeGarden)。

## 功能

| Tab | 功能 | 数据源 |
|---|---|---|
| 漫画 | 主题筛选、最新或人气、搜索;详情(章节正倒序,离线可开);竖向滚动阅读(点击呼出菜单、自动预载下一话、离线可看已缓存话);多选批量下载,全局队列(暂停/继续/重试/重启恢复/后台下载);「我的 → 离线与下载」离线库,支持整部删除 | copymanga。域名池自动回退漂移(api/www/mangacopy.com 等镜像,命中记忆),设置页可自定义域名;必须携带 platform/region/version/webp 请求头;章节图片按 `words[]` 还原乱序;章节顺序按 API 的 `index` 升序 |
| 影视 | 源切换、分类、多源流式聚合搜索(快的源先出结果);播放(双击快进 10 秒、长按 3 倍速、死链自动换线、控制条 3 秒自动收起);观看历史续播;剧集多选下载(仅 Wi-Fi 默认开、断点续传),离线本地播放 | 苹果 CMS 采集站。内置 360资源、金鹰;源健康分(连续失败自动停用、每日启动探测复活);「影视源管理」支持增删启停与一键探测内置候选池(API+播放双验证) |
| 直播 | 频道聚合、分组、搜索;播放前实测选线,失败自动换线或换台 | iptv-org(`languages/zho.m3u`、`countries/cn.m3u`) |
| 雷达 | 动漫 BT 资源搜索与最新,点击复制磁力 | AnimeGarden 公开 API(`api.animes.garden`) |
| 我的 | 离线与下载、影视源管理、观看历史 | — |

尚未实现:

- **视频离线的整链路验收**。路线 A(HLS 解密合并 → fdSrc 本地播放)已真机验证通过,下载/队列/本地播放代码已落地(见 `dev/项目开发现状总结.md` §0.5/§0.6);剩「选择下载 → 队列可见 → 下载完 → 飞行模式本地播放」这条验收链。
- **端上 BT 内核**。只有协议基础层(bencode、magnet、SHA1)和探测脚本,没有接入页面。可行性和设计见同一份文档的第四节。

## 构建

```bash
export DEVECO_SDK_HOME="<DevEco>/sdk"
node "<DevEco>/tools/hvigor/bin/hvigorw.js" --mode module -p module=entry@default -p product=default assembleHap --no-daemon
# 产物: entry/build/default/outputs/default/entry-default-signed.hap(约 1MB)
hdc file send .../entry-default-signed.hap /data/local/tmp/ani.hap   # 注意 Windows 下 hdc 需要 MSYS_NO_PATHCONV=1
hdc shell bm install -p /data/local/tmp/ani.hap
```

SDK 配置:`targetSdkVersion 26.0.0` + `compatibleSdkVersion "6.1.1(24)"`(Pura 90 Pro / HarmonyOS 6.1.0 可装)。
**不要**把 target 也降到 6.1.1(24):SDK 26 打出来的 target=24 包,商用机会静默拒绝安装。

## 数据源现状(2026-11-25 第二轮探测)

- copymanga:主域 `api.mangacopy.com` 及 www/mangacopy.com 在部分网络 ECONNRESET(域名又漂了),App 已做域名池自动回退 + 设置页自定义域名兜底。
- 影视:两轮共测 34 个候选,可用的只有 360资源 ✓(CDN 单流实测 2.6MB/s)与金鹰 ✓(间歇抖动)。老鸭/非凡 API 活但 CDN 不可达(深探测可识别,别加)。其余(量子/暴风/天空/卧龙/红牛/豆瓣等)域名已死。源池生死无常 → App 内置 22 个候选,「影视源管理 → 探测内置候选源」随时按当时网络重筛;死源连续失败自动停用、每日启动探测复活。探测脚本:`node scripts/cmsprobe/batch.mjs`(加 `--speed` 实测吞吐)。
- iptv-org 可用,1080p 线路多数已失效。fanmingming/Guovin 等社区列表在部分网络不可达,待真机验证后再考虑内置。

## 历史遗留(可选)

`rust/` 目录是番茄小说(fqapp)Rust 核心的完整交叉编译方案(含手写最小 NAPI 绑定),
当前未接入 App(用户不需要小说)。如果要恢复:
1. `powershell -File scripts\build-native.ps1` 编 .so 到 entry/libs
2. 恢复 entry/oh-package.json5 的 `libfqapi_ohos.so` 依赖与 cpp/types 声明
3. 恢复番茄相关页面(没有 git 历史,需要参考 fqapp 原实现)

注意:商用机(6.1.0)的 NAPI 运行时缺 `napi_reject_deferred` 等 promise 符号,napi-rs 不可用,
绑定必须走手写路径(`rust/fqapi_ohos/src/lib.rs`,鸿蒙注册链 napi_module_register + .init_array)。

## 许可

自用不分发。所有内容资源来自第三方公开接口,本工程不存储、不分发任何内容。

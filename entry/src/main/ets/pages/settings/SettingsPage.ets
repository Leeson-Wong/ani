import { bundleManager } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Nav } from '../../common/Nav';
import { Prefs } from '../../db/Prefs';
import { MangaClient } from '../../datasources/manga/MangaClient';

/** 我的:版本信息 + 影视源管理 + 漫画域名 + 声明 */
@ComponentV2
export struct SettingsPage {
  @Local versionName: string = '';
  @Local mangaCustom: string = '';
  @Local mangaEffective: string = '';
  @Local mangaTesting: boolean = false;

  aboutToAppear(): void {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    this.versionName = `${info.versionName}(${info.versionCode})`;
    if (Prefs.isReady) {
      this.mangaCustom = Prefs.getMangaApiCustom();
    }
    this.refreshEffective();
  }

  private refreshEffective(): void {
    const good = Prefs.isReady ? Prefs.getMangaApiBase() : '';
    if (this.mangaCustom.trim().length > 0) {
      this.mangaEffective = this.mangaCustom.trim();
      return;
    }
    if (good.length > 0) {
      this.mangaEffective = `自动(命中 ${good})`;
      return;
    }
    this.mangaEffective = '自动(api.mangacopy.com 起,失败逐个换镜像)';
  }

  /** 保存自定义域名并实测;留空保存 = 恢复自动回退 */
  async saveMangaBase(): Promise<void> {
    if (this.mangaTesting) {
      return;
    }
    const v = this.mangaCustom.trim();
    if (v.length > 0 && !/^https?:\/\//.test(v)) {
      promptAction.showToast({ message: '域名需以 http(s):// 开头' });
      return;
    }
    this.mangaTesting = true;
    try {
      Prefs.setMangaApiCustom(v);
      await MangaClient.home(); // 走域名池:自定义优先,失败自动换镜像
      const good = Prefs.getMangaApiBase();
      this.refreshEffective();
      promptAction.showToast({ message: `连接成功,命中 ${good}` });
    } catch (e) {
      this.refreshEffective();
      promptAction.showToast({ message: `测试失败:${e}。已保存,仍会自动尝试镜像` });
    } finally {
      this.mangaTesting = false;
    }
  }

  clearMangaBase(): void {
    Prefs.setMangaApiCustom('');
    this.mangaCustom = '';
    this.refreshEffective();
    promptAction.showToast({ message: '已恢复自动选择' });
  }

  @Builder
  item(label: string, sub: string, onTap: () => void) {
    Row() {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(16)
        Text(sub)
          .fontSize(12)
          .fontColor('#999999')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(20)
        .fontColor('#BBBBBB')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .onClick(onTap)
  }

  @Builder
  mangaSourceCard() {
    Column({ space: 10 }) {
      Text('漫画数据源')
        .fontSize(16)
      Text(`当前生效:${this.mangaEffective}`)
        .fontSize(12)
        .fontColor('#999999')
      Text('以下域名设置只作用于「拷贝漫画」源;漫画源切换在漫画 Tab 顶部')
        .fontSize(11)
        .fontColor('#BBBBBB')
      TextInput({ placeholder: '自定义 API 域名,留空 = 自动回退镜像', text: this.mangaCustom })
        .onChange((v: string) => {
          this.mangaCustom = v;
        })
      Row({ space: 10 }) {
        Button(this.mangaTesting ? '测试中…' : '保存并测试')
          .layoutWeight(1)
          .enabled(!this.mangaTesting)
          .onClick(() => {
            this.saveMangaBase();
          })
        Button('恢复自动')
          .layoutWeight(1)
          .backgroundColor('#EEEEEE')
          .fontColor('#333333')
          .onClick(() => {
            this.clearMangaBase();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(10)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('设置')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .padding({ left: 4 })

        Column({ space: 10 }) {
          this.item('离线与下载', '已缓存漫画 / 下载队列进度 / 整部删除', () => {
            Nav.stack.pushPathByName('Offline', null);
          })
          this.item('影视源管理', '添加 / 探测 / 启停苹果CMS 采集站;死源自动停用与复活', () => {
            Nav.stack.pushPathByName('CmsSourceManage', null);
          })
          this.item('观看历史', '续播 / 管理观看记录', () => {
            Nav.stack.pushPathByName('History', null);
          })
          this.item('雷达说明', '动漫资源来自 AnimeGarden,点击条目复制磁力后用外部下载器下载', () => {
          })
        }
        .width('100%')

        this.mangaSourceCard()

        Column({ space: 6 }) {
          Text(`书影 ani ${this.versionName}`)
            .fontSize(13)
            .fontColor('#999999')
          Text('自用工具,不分发。影视/漫画源为第三方公开接口,本应用不存储、不分发任何内容。')
            .fontSize(12)
            .fontColor('#AAAAAA')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 20 })
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
    .align(Alignment.Top)
  }
}

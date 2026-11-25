import { bundleManager } from '@kit.AbilityKit';
import { Nav } from '../../common/Nav';

/** 我的:版本信息 + 影视源管理 + 声明 */
@ComponentV2
export struct SettingsPage {
  @Local versionName: string = '';

  aboutToAppear(): void {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    this.versionName = `${info.versionName}(${info.versionCode})`;
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
          this.item('影视源管理', '添加 / 探测 / 启停苹果CMS 采集站', () => {
            Nav.stack.pushPathByName('CmsSourceManage', null);
          })
          this.item('观看历史', '续播 / 管理观看记录', () => {
            Nav.stack.pushPathByName('History', null);
          })
          this.item('雷达说明', '动漫资源来自 AnimeGarden,点击条目复制磁力后用外部下载器下载', () => {
          })
        }
        .width('100%')

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

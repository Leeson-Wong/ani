import { NetWatch } from './NetWatch';
import { Nav } from './Nav';

/** Tab 顶部离线提示条:断网时出现,点击进离线库看已缓存内容 */
@ComponentV2
export struct OfflineBanner {
  build() {
    if (!NetWatch.get().online) {
      Row({ space: 8 }) {
        Text('当前离线 · 已缓存的内容可以离线看')
          .fontSize(12)
          .fontColor('#8A5A00')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('查看已下载')
          .fontSize(12)
          .fontColor('#8A5CF6')
          .onClick(() => {
            Nav.stack.pushPathByName('Offline', null);
          })
      }
      .width('100%')
      .padding({ top: 6, bottom: 6, left: 14, right: 14 })
      .backgroundColor('#FFF3D6')
    }
  }
}

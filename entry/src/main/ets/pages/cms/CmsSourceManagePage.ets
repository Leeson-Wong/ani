import { promptAction } from '@kit.ArkUI';
import { CmsSourceManager } from '../../datasources/cms/CmsSourceManager';
import { ProbeResult } from '../../models/cms/MaccmsModels';
import { DatabaseHelper, CmsSourceRow } from '../../db/DatabaseHelper';

interface SourceItem extends CmsSourceRow {
  probing: boolean;
  probeMsg: string;
}

/** 影视源管理:添加(粘贴 API 地址后自动探测)/ 启停 / 删除 */
@ComponentV2
export struct CmsSourceManagePage {
  @Local sources: SourceItem[] = [];
  @Local showAddSheet: boolean = false;
  @Local newName: string = '';
  @Local newApi: string = '';

  async aboutToAppear(): Promise<void> {
    await this.refresh();
  }

  async refresh(): Promise<void> {
    await DatabaseHelper.init(getContext(this));
    const rows = await CmsSourceManager.list();
    const merged: SourceItem[] = [];
    for (const row of rows) {
      const existing = this.sources.find((s: SourceItem) => s.id === row.id);
      merged.push({
        id: row.id,
        name: row.name,
        apiBase: row.apiBase,
        format: row.format,
        enabled: row.enabled,
        sort: row.sort,
        probing: false,
        probeMsg: existing !== undefined ? existing.probeMsg : ''
      });
    }
    this.sources = merged;
  }

  async probeOne(item: SourceItem): Promise<void> {
    item.probing = true;
    this.sources = [...this.sources];
    const result: ProbeResult = await CmsSourceManager.probe(item.apiBase);
    item.probing = false;
    item.probeMsg = result.ok ? `${result.message}(${result.categories} 个分类)` : result.message;
    this.sources = [...this.sources];
  }

  async addSource(): Promise<void> {
    const api = this.newApi.trim();
    if (api.length === 0) {
      promptAction.showToast({ message: '请输入 API 地址' });
      return;
    }
    if (!/^https?:\/\//.test(api)) {
      promptAction.showToast({ message: '地址需以 http(s):// 开头' });
      return;
    }
    await CmsSourceManager.add(this.newName, api);
    this.newName = '';
    this.newApi = '';
    this.showAddSheet = false;
    await this.refresh();
    promptAction.showToast({ message: '已添加,正在探测…' });
    const added = this.sources[this.sources.length - 1];
    if (added !== undefined) {
      await this.probeOne(added);
    }
  }

  async toggle(item: SourceItem, on: boolean): Promise<void> {
    await CmsSourceManager.setEnabled(item.id, on);
    await this.refresh();
  }

  async remove(item: SourceItem): Promise<void> {
    await CmsSourceManager.remove(item.id);
    promptAction.showToast({ message: `已删除「${item.name}」` });
    await this.refresh();
  }

  @Builder
  sourceRow(item: SourceItem) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Column({ space: 3 }) {
          Text(item.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          Text(item.apiBase)
            .fontSize(11)
            .fontColor('#999999')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.probeMsg.length > 0) {
            Text(`探测:${item.probeMsg}`)
              .fontSize(11)
              .fontColor(item.probeMsg.startsWith('探测:可用') || item.probeMsg.startsWith('可用') ? '#2E8B57' : '#CC3333')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: item.enabled })
          .onChange((on: boolean) => {
            this.toggle(item, on);
          })

        Column({ space: 6 }) {
          Text('探测')
            .fontSize(12)
            .fontColor('#3471D5')
          Text('删除')
            .fontSize(12)
            .fontColor('#CC3333')
            .onClick(() => {
              this.remove(item);
            })
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .onClick(() => {
      if (!item.probing) {
        this.probeOne(item);
      }
    })
  }

  @Builder
  addSheet() {
    Column({ space: 14 }) {
      Text('添加影视源')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
      TextInput({ placeholder: '名称(留空自动命名)', text: this.newName })
        .onChange((v: string) => {
          this.newName = v;
        })
      TextInput({ placeholder: 'API 地址,如 https://xxx/api.php/provide/vod', text: this.newApi })
        .onChange((v: string) => {
          this.newApi = v;
        })
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor('#EEEEEE')
          .fontColor('#333333')
          .onClick(() => {
            this.showAddSheet = false;
          })
        Button('添加并探测')
          .layoutWeight(1)
          .onClick(() => {
            this.addSource();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .borderRadius({ topLeft: 16, topRight: 16 })
    .backgroundColor(Color.White)
  }

  build() {
    NavDestination() {
      Column({ space: 12 }) {
        List({ space: 10 }) {
          ForEach(this.sources, (item: SourceItem) => {
            ListItem() {
              this.sourceRow(item)
            }
          }, (item: SourceItem) => `src-${item.id}-${item.probeMsg}`)
        }
        .width('100%')
        .layoutWeight(1)

        Button('＋ 添加源')
          .width('90%')
          .margin({ bottom: 16 })
          .onClick(() => {
            this.showAddSheet = true;
          })
      }
      .width('100%')
      .height('100%')
      .padding(12)
      .backgroundColor('#F1F3F5')
    }
    .title('影视源管理')
    .bindSheet($$this.showAddSheet, this.addSheet(), {
      height: SheetSize.FIT_CONTENT,
      showClose: true
    })
    // NavDestination 灰底:返回键区域/loading 态不露系统白底(与内容区一致)
    .backgroundColor('#F1F3F5')
  }
}

@Builder
export function cmsSourceManageBuilder() {
  CmsSourceManagePage()
}

import { promptAction } from '@kit.ArkUI';
import { CmsSourceManager } from '../../datasources/cms/CmsSourceManager';
import { ProbeResult } from '../../models/cms/MaccmsModels';
import { DatabaseHelper, CmsSourceRow } from '../../db/DatabaseHelper';

interface SourceItem extends CmsSourceRow {
  probing: boolean;
  probeMsg: string;
}

/** 候选源探测结果行(added 随点击变化) */
interface CandRow {
  name: string;
  apiBase: string;
  ok: boolean;
  message: string;
  added: boolean;
}

/** 影视源管理:添加(粘贴 API 地址后自动探测)/ 启停 / 删除 / 健康徽标 / 内置候选批量探测 */
@ComponentV2
export struct CmsSourceManagePage {
  @Local sources: SourceItem[] = [];
  @Local showAddSheet: boolean = false;
  @Local newName: string = '';
  @Local newApi: string = '';
  @Local probingCand: boolean = false;
  @Local showCandSheet: boolean = false;
  @Local candRows: CandRow[] = [];

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
        failCount: row.failCount,
        autoOff: row.autoOff,
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
    // 探测通过的自动停用源,顺手恢复启用
    if (result.ok && item.autoOff) {
      await CmsSourceManager.setEnabled(item.id, true);
      await this.refresh();
      return;
    }
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

  /** 批量深探测内置候选池(API + 播放链路),结果进底部面板 */
  async probeCandidates(): Promise<void> {
    if (this.probingCand) {
      return;
    }
    this.probingCand = true;
    try {
      const results = await CmsSourceManager.probeCandidates();
      const rows: CandRow[] = [];
      for (const r of results) {
        const row: CandRow = { name: r.name, apiBase: r.apiBase, ok: r.ok, message: r.message, added: false };
        rows.push(row);
      }
      this.candRows = rows;
      if (rows.length === 0) {
        promptAction.showToast({ message: '内置候选都已在你的源列表里' });
      } else {
        this.showCandSheet = true;
      }
    } catch (e) {
      promptAction.showToast({ message: `探测失败:${e}` });
    } finally {
      this.probingCand = false;
    }
  }

  async addCand(row: CandRow): Promise<void> {
    const added = await CmsSourceManager.addCandidate(row.name, row.apiBase);
    row.added = true;
    this.candRows = [...this.candRows];
    if (added) {
      promptAction.showToast({ message: `已添加「${row.name}」` });
    }
  }

  async addAllLive(): Promise<void> {
    let n = 0;
    for (const row of this.candRows) {
      if (row.ok && !row.added) {
        if (await CmsSourceManager.addCandidate(row.name, row.apiBase)) {
          row.added = true;
          n++;
        }
      }
    }
    this.candRows = [...this.candRows];
    await this.refresh();
    promptAction.showToast({ message: n > 0 ? `已添加 ${n} 个可用源` : '没有新的可用源' });
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
          if (item.autoOff) {
            Text('连续失败已自动停用;每天启动会自动探测,或点「探测」后恢复')
              .fontSize(11)
              .fontColor('#E06C00')
          } else if (item.failCount > 0) {
            Text(`近期连续失败 ${item.failCount} 次(满 3 次自动停用)`)
              .fontSize(11)
              .fontColor('#E06C00')
          }
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
  candRowView(row: CandRow) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(row.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
        Text(row.message)
          .fontSize(11)
          .fontColor(row.ok ? '#2E8B57' : '#999999')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (row.added) {
        Text('已添加')
          .fontSize(12)
          .fontColor('#999999')
      } else if (row.ok) {
        Text('＋添加')
          .fontSize(13)
          .fontColor('#3471D5')
          .padding(6)
          .onClick(() => {
            this.addCand(row);
          })
      } else {
        Text('不可用')
          .fontSize(12)
          .fontColor('#BBBBBB')
      }
    }
    .width('100%')
    .padding(10)
    .borderRadius(8)
    .backgroundColor('#F6F7F9')
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

  @Builder
  candSheet() {
    Column({ space: 12 }) {
      Text('内置候选源探测结果')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
      Text('只列不在你列表里的候选;绿字 = API 与播放链路双验证通过')
        .fontSize(11)
        .fontColor('#999999')
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.candRows, (row: CandRow) => {
            this.candRowView(row)
          }, (row: CandRow) => `cand-${row.apiBase}-${row.added}`)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 420 })
      .scrollBar(BarState.Auto)
      .width('100%')
      Row({ space: 10 }) {
        Button('添加全部可用')
          .layoutWeight(1)
          .onClick(() => {
            this.addAllLive();
          })
        Button('关闭')
          .layoutWeight(1)
          .backgroundColor('#EEEEEE')
          .fontColor('#333333')
          .onClick(() => {
            this.showCandSheet = false;
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
          }, (item: SourceItem) => `src-${item.id}-${item.enabled}-${item.autoOff}-${item.failCount}-${item.probeMsg}`)
        }
        .width('100%')
        .layoutWeight(1)

        Column({ space: 10 }) {
          Button('＋ 添加源')
            .width('90%')
            .onClick(() => {
              this.showAddSheet = true;
            })
          Button(this.probingCand ? '探测候选中…' : '探测内置候选源')
            .width('90%')
            .backgroundColor('#EEEEEE')
            .fontColor('#333333')
            .enabled(!this.probingCand)
            .onClick(() => {
              this.probeCandidates();
            })
        }
        .width('100%')
        .margin({ bottom: 16 })
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
    .bindSheet($$this.showCandSheet, this.candSheet(), {
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

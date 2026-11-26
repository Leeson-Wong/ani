import { promptAction } from '@kit.ArkUI';
import { CmsSourceManager } from '../../datasources/cms/CmsSourceManager';
import { MaccmsClient } from '../../datasources/cms/MaccmsClient';
import { DatabaseHelper, CmsSourceRow } from '../../db/DatabaseHelper';
import { CmsCategory, CmsVideoBrief } from '../../models/cms/MaccmsModels';
import { Nav } from '../../common/Nav';
import { OfflineBanner } from '../../common/OfflineBanner';
import { VideoDetailNavParam } from '../../common/NavParams';

interface SearchGroup {
  sourceName: string;
  items: CmsVideoBrief[];
  error: string;
}

/** 卡片基准宽(vp):列数按容器宽自适应,行内所有空隙(含两侧)相等 */
const CARD_W = 110;

function chunkRows<T>(items: T[], size: number): T[][] {
  const rows: T[][] = [];
  if (size <= 0) {
    return rows;
  }
  for (let i = 0; i < items.length; i += size) {
    const end = Math.min(i + size, items.length);
    const row: T[] = [];
    for (let j = i; j < end; j++) {
      row.push(items[j]);
    }
    rows.push(row);
  }
  return rows;
}

/** 影视 tab:搜索 + 分类发现(分类 chips + 封面网格 + 分页) */
@ComponentV2
export struct VideoTabPage {
  @Local keyword: string = '';
  @Local loading: boolean = false;
  @Local searched: boolean = false;
  @Local groups: SearchGroup[] = [];
  // 发现页状态
  @Local sources: CmsSourceRow[] = [];
  @Local currentSourceId: number = -1;
  @Local categories: CmsCategory[] = [];
  @Local currentType: number = -1; // -1 = 最近更新
  @Local videos: CmsVideoBrief[] = [];
  @Local page: number = 1;
  @Local pagecount: number = 1;
  @Local discoverLoading: boolean = false;
  @Local discoverError: string = '';
  @Local gridCols: number = 3;
  private client: MaccmsClient | null = null;
  private sourceName: string = '';

  /** 列数 = 容器宽 / (卡片基准宽 + 最小间隙),限 3~8;折叠屏展开自动加列 */
  updateCols(w: number): void {
    const n = Math.floor(w / (CARD_W + 6));
    this.gridCols = Math.max(3, Math.min(8, n));
  }

  async aboutToAppear(): Promise<void> {
    await DatabaseHelper.init(getContext(this));
    await this.initDiscover();
  }

  async initDiscover(): Promise<void> {
    const sources = await CmsSourceManager.listEnabled();
    if (sources.length === 0) {
      this.discoverError = '没有可用的影视源,请在「我的 → 影视源管理」添加';
      return;
    }
    this.sources = sources;
    const keep = sources.find((s: CmsSourceRow) => s.id === this.currentSourceId);
    const src: CmsSourceRow = keep !== undefined ? keep : sources[0];
    this.currentSourceId = src.id;
    this.client = new MaccmsClient(src.id, src.apiBase);
    this.sourceName = src.name;
    this.currentType = -1;
    await this.loadDiscover(1, true);
  }

  async switchSource(id: number): Promise<void> {
    if (id === this.currentSourceId) {
      return;
    }
    this.currentSourceId = id;
    await this.initDiscover();
  }

  async loadDiscover(page: number, reload: boolean): Promise<void> {
    if (this.client === null || this.discoverLoading) {
      return;
    }
    this.discoverLoading = true;
    this.discoverError = '';
    try {
      if (reload) {
        const home = await this.client.recent(1);
        this.categories = home.categories;
        this.videos = home.items;
        this.pagecount = home.pagecount;
        this.page = 1;
      } else {
        const query = this.currentType >= 0
          ? await this.client.byCategory(this.currentType, page)
          : await this.client.recent(page);
        this.videos = this.videos.concat(query.items);
        this.pagecount = query.pagecount;
        this.page = page;
      }
    } catch (e) {
      this.discoverError = `${e}`;
    } finally {
      this.discoverLoading = false;
    }
  }

  async selectCategory(typeId: number): Promise<void> {
    this.currentType = typeId;
    this.videos = [];
    if (this.client === null) {
      return;
    }
    this.discoverLoading = true;
    try {
      const query = this.currentType >= 0
        ? await this.client.byCategory(this.currentType, 1)
        : await this.client.recent(1);
      this.videos = query.items;
      this.pagecount = query.pagecount;
      this.page = 1;
    } catch (e) {
      this.discoverError = `${e}`;
    } finally {
      this.discoverLoading = false;
    }
  }

  async doSearch(): Promise<void> {
    const kw = this.keyword.trim();
    if (kw.length === 0 || this.loading) {
      return;
    }
    this.loading = true;
    this.groups = [];
    this.searched = true;
    try {
      // 流式搜索:每个源完成即渲染,快的源先出结果,死源不再拖住首屏
      await CmsSourceManager.searchAllStream(kw, (r) => {
        const group: SearchGroup = { sourceName: r.source.name, items: r.items, error: r.error };
        this.groups = this.groups.concat([group]);
      });
    } catch (e) {
      promptAction.showToast({ message: `搜索失败:${e}` });
    } finally {
      this.loading = false;
    }
  }

  backToDiscover(): void {
    this.searched = false;
    this.groups = [];
    this.keyword = '';
  }

  @Builder
  videoCard(item: CmsVideoBrief) {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(item.cover.length > 0 ? item.cover : 'https://placeholder.invalid/x.png')
          .width('100%')
          .aspectRatio(0.7) // 统一 7:10 海报比例,保证网格等高
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.startIcon'))
        if (item.remarks.length > 0) {
          Text(item.remarks)
            .fontSize(10)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#AA000000')
            .borderRadius({ topLeft: 6, topRight: 6 })
            .maxLines(1)
        }
      }
      .width('100%')
      Text(item.title)
        .fontSize(13)
        .height(18)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(item.year.length > 0 ? item.year : item.category)
        .fontSize(11)
        .height(14)
        .fontColor('#999999')
        .maxLines(1)
        .width('100%')
    }
    .width('100%')
    .onClick(() => {
      const params: VideoDetailNavParam = {
        sourceId: item.sourceId,
        vodId: item.vodId,
        title: item.title,
        cover: item.cover,
        remarks: item.remarks
      };
      Nav.stack.pushPathByName('VideoDetail', params);
    })
  }

  @Builder
  groupHeader(group: SearchGroup) {
    Text(`${group.sourceName}(${group.items.length})`)
      .fontSize(13)
      .fontColor('#666666')
      .padding({ left: 4, top: 8, bottom: 4 })
  }

  @Builder
  sourceMenu() {
    Menu() {
      ForEach(this.sources, (s: CmsSourceRow) => {
        MenuItem({
          content: this.currentSourceId === s.id ? `✓ ${s.name}` : s.name
        })
          .onClick(() => {
            this.switchSource(s.id);
          })
      }, (s: CmsSourceRow) => `${s.id}-${s.name}`)
    }
  }

  build() {
    Column() {
      // 断网提示:点击进离线库
      OfflineBanner()
      // 搜索条
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索剧名 / 动漫 / 电影…', text: this.keyword })
          .onChange((v: string) => {
            this.keyword = v;
          })
          .onSubmit(() => {
            this.doSearch();
          })
          .layoutWeight(1)
          .backgroundColor(Color.White)
          .borderRadius(20)
        Button(this.loading ? '搜索中' : '搜索')
          .enabled(!this.loading && this.keyword.trim().length > 0)
          .borderRadius(20)
          .onClick(() => {
            this.doSearch();
          })
        Text('历史')
          .fontSize(14)
          .fontColor('#3471D5')
          .padding(8)
          .onClick(() => {
            Nav.stack.pushPathByName('History', null);
          })
      }
      .width('100%')
      .padding(12)

      if (this.searched) {
        // 搜索结果
        Column() {
          Row() {
            Text('搜索结果')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
            Text('返回分类')
              .fontSize(13)
              .fontColor('#3471D5')
              .padding(6)
              .onClick(() => {
                this.backToDiscover();
              })
          }
          .width('100%')
          .padding({ left: 16, bottom: 4 })

          List({ space: 8 }) {
            ForEach(this.groups, (group: SearchGroup) => {
              ListItemGroup({ header: this.groupHeader(group) }) {
                if (group.error.length > 0 && group.items.length === 0) {
                  ListItem() {
                    Text(`该源不可用:${group.error}`)
                      .fontSize(13)
                      .fontColor('#CC3333')
                      .padding(12)
                  }
                }
                ForEach(group.items, (item: CmsVideoBrief) => {
                  ListItem() {
                    Row({ space: 10 }) {
                      Image(item.cover.length > 0 ? item.cover : 'https://placeholder.invalid/x.png')
                        .width(64)
                        .height(88)
                        .borderRadius(6)
                        .objectFit(ImageFit.Cover)
                        .alt($r('app.media.startIcon'))
                      Column({ space: 4 }) {
                        Text(item.title)
                          .fontSize(16)
                          .fontWeight(FontWeight.Medium)
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(`${item.year.length > 0 ? item.year + ' · ' : ''}${item.category}`)
                          .fontSize(12)
                          .fontColor('#999999')
                        Text(item.remarks)
                          .fontSize(12)
                          .fontColor('#E06C00')
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                    }
                    .width('100%')
                    .padding(12)
                    .borderRadius(10)
                    .backgroundColor(Color.White)
                    .onClick(() => {
                      const params: VideoDetailNavParam = {
                        sourceId: item.sourceId,
                        vodId: item.vodId,
                        title: item.title,
                        cover: item.cover,
                        remarks: item.remarks
                      };
                      Nav.stack.pushPathByName('VideoDetail', params);
                    })
                  }
                }, (item: CmsVideoBrief) => `${item.sourceId}-${item.vodId}`)
              }
            }, (group: SearchGroup) => group.sourceName)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 12, right: 12, bottom: 12 })
          .sticky(StickyStyle.Header)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        // 分类发现页
        Column() {
          // 源切换 + 分类 chips
          Scroll() {
            Row({ space: 8 }) {
              if (this.sources.length > 1) {
                Text(`源:${this.sourceName} ▾`)
                  .fontSize(13)
                  .fontColor('#E06C00')
                  .backgroundColor('#FDF0E7')
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .bindMenu(this.sourceMenu())
              }
              Text('最近更新')
                .fontSize(13)
                .fontColor(this.currentType < 0 ? Color.White : '#444444')
                .backgroundColor(this.currentType < 0 ? '#3471D5' : Color.White)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .borderRadius(14)
                .onClick(() => {
                  this.selectCategory(-1);
                })
              ForEach(this.categories, (cat: CmsCategory) => {
                Text(cat.type_name)
                  .fontSize(13)
                  .fontColor(this.currentType === cat.type_id ? Color.White : '#444444')
                  .backgroundColor(this.currentType === cat.type_id ? '#3471D5' : Color.White)
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .onClick(() => {
                    this.selectCategory(cat.type_id);
                  })
              }, (cat: CmsCategory) => `${cat.type_id}-${cat.type_name}`)
            }
            .padding({ left: 12, right: 12 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')

          if (this.discoverError.length > 0) {
            Column({ space: 10 }) {
              Text(this.discoverError)
                .fontSize(13)
                .fontColor('#CC3333')
                .padding(16)
              Button('重试')
                .onClick(() => {
                  this.initDiscover();
                })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            // 定宽卡片网格:列数按宽度自适应,行内所有空隙(含两侧)相等
            Scroll() {
              Column({ space: 12 }) {
                ForEach(chunkRows<CmsVideoBrief>(this.videos, this.gridCols), (row: CmsVideoBrief[]) => {
                  Row() {
                    ForEach(row, (item: CmsVideoBrief) => {
                      Column() {
                        this.videoCard(item)
                      }
                      .width(CARD_W)
                    }, (item: CmsVideoBrief) => `${item.vodId}`)
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.SpaceEvenly)
                }, (row: CmsVideoBrief[], idx: number) => `row-${idx}-${row.length > 0 ? row[0].vodId : 0}`)
              }
              .width('100%')
              .padding({ top: 8, bottom: 12 })
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .onAreaChange((_o: Area, n: Area) => {
              this.updateCols(Number(n.width));
            })
            .onReachEnd(() => {
              if (!this.discoverLoading && this.page < this.pagecount) {
                this.loadDiscover(this.page + 1, false);
              }
            })
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}

import { promptAction } from '@kit.ArkUI';
import { MangaSource, MangaSources } from '../../datasources/manga/MangaSource';
import { DatabaseHelper } from '../../db/DatabaseHelper';
import { Prefs } from '../../db/Prefs';
import { Nav } from '../../common/Nav';
import { OfflineBanner } from '../../common/OfflineBanner';
import { MangaDetailNavParam } from '../../common/NavParams';
import { MangaBrief, MangaTheme } from '../../models/manga/MangaModels';

const PAGE_SIZE = 24;

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

/** 漫画 tab:搜索 + 主题/排序筛选 + 无限滚动网格 */
@ComponentV2
export struct MangaTabPage {
  @Local keyword: string = '';
  @Local searching: boolean = false;
  @Local searched: boolean = false;
  @Local searchResults: MangaBrief[] = [];
  @Local sourceId: string = 'copymanga'; // 当前源(菜单勾选与展示)
  @Local themes: MangaTheme[] = []; // 当前源的分类 chips
  @Local themeIndex: number = 0;
  @Local orderByPopular: boolean = false; // false = 最新
  @Local comics: MangaBrief[] = [];
  @Local listOffset: number = 0;
  @Local loading: boolean = false;
  @Local error: string = '';
  @Local gridCols: number = 3;
  @Local gridW: number = 0;

  async aboutToAppear(): Promise<void> {
    await DatabaseHelper.init(getContext(this));
    this.sourceId = MangaSources.current().id;
    this.themes = MangaSources.current().themes();
    this.reload();
  }

  get ordering(): string {
    return this.orderByPopular ? '-popular' : '-datetime_updated';
  }

  get sourceName(): string {
    const s = MangaSources.byId(this.sourceId);
    return s !== undefined ? s.name : '';
  }

  /** 切换漫画源:搜索结果/主题筛选都属于旧源,全部重置后重载 */
  async switchSource(id: string): Promise<void> {
    if (id === this.sourceId) {
      return;
    }
    this.sourceId = id;
    Prefs.setMangaSourceId(id);
    this.searched = false;
    this.searchResults = [];
    this.keyword = '';
    this.themeIndex = 0;
    this.themes = MangaSources.current().themes();
    await this.reload();
  }

  async reload(): Promise<void> {
    this.comics = [];
    this.listOffset = 0;
    await this.loadMore();
  }

  async loadMore(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const theme = this.themes[this.themeIndex].value;
      const fresh = await MangaSources.current().comicsList(theme, this.ordering, this.listOffset, PAGE_SIZE);
      this.comics = this.comics.concat(fresh);
      this.listOffset += fresh.length;
    } catch (e) {
      this.error = `${e}`;
    } finally {
      this.loading = false;
    }
  }

  async doSearch(): Promise<void> {
    const kw = this.keyword.trim();
    if (kw.length === 0 || this.searching) {
      return;
    }
    this.searching = true;
    try {
      this.searchResults = await MangaSources.current().search(kw, 0, 30);
      this.searched = true;
      Prefs.pushSearchHistory(kw);
      if (this.searchResults.length === 0) {
        promptAction.showToast({ message: '没有找到相关漫画' });
      }
    } catch (e) {
      promptAction.showToast({ message: `搜索失败:${e}` });
    } finally {
      this.searching = false;
    }
  }

  backToList(): void {
    this.searched = false;
    this.searchResults = [];
    this.keyword = '';
  }

  pushDetail(b: MangaBrief): void {
    const params: MangaDetailNavParam = { pathWord: b.pathWord, name: b.name, cover: b.cover };
    Nav.stack.pushPathByName('MangaDetail', params);
  }

  /** 列数 = 容器宽 / (卡片基准宽 + 最小间隙),限 3~8;折叠屏展开自动加列 */
  updateCols(w: number): void {
    this.gridW = w;
    const n = Math.floor(w / (CARD_W + 6));
    this.gridCols = Math.max(3, Math.min(8, n));
  }

  @Builder
  sourceMenu() {
    Menu() {
      ForEach(MangaSources.list(), (s: MangaSource) => {
        MenuItem({
          content: this.sourceId === s.id ? `✓ ${s.name}` : s.name
        })
          .onClick(() => {
            this.switchSource(s.id);
          })
      }, (s: MangaSource) => s.id)
    }
  }

  @Builder
  comicCard(b: MangaBrief) {
    Column({ space: 6 }) {
      Image(b.cover)
        .width('100%')
        .aspectRatio(0.72)
        .borderRadius(8)
        .objectFit(ImageFit.Cover)
        .alt($r('app.media.startIcon'))
      Text(b.name)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textAlign(TextAlign.Start)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(b.author)
        .fontSize(11)
        .fontColor('#999999')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .onClick(() => {
      this.pushDetail(b);
    })
  }

  build() {
    Column() {
      // 断网提示:点击进离线库
      OfflineBanner()
      // 搜索条
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索漫画名 / 作者', text: this.keyword })
          .onChange((v: string) => {
            this.keyword = v;
          })
          .onSubmit(() => {
            this.doSearch();
          })
          .layoutWeight(1)
          .backgroundColor(Color.White)
          .borderRadius(20)
        Button(this.searching ? '搜索中' : '搜索')
          .enabled(!this.searching && this.keyword.trim().length > 0)
          .borderRadius(20)
          .onClick(() => {
            this.doSearch();
          })
      }
      .width('100%')
      .padding(12)

      if (this.searched) {
        Row() {
          Text(`搜索结果(${this.searchResults.length})`)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
          Text('返回列表')
            .fontSize(13)
            .fontColor('#3471D5')
            .padding(6)
            .onClick(() => {
              this.backToList();
            })
        }
        .width('100%')
        .padding({ left: 16, bottom: 4 })

        List({ space: 8 }) {
          ForEach(this.searchResults, (b: MangaBrief) => {
            ListItem() {
              Row({ space: 10 }) {
                Image(b.cover)
                  .width(52)
                  .height(70)
                  .borderRadius(6)
                  .objectFit(ImageFit.Cover)
                  .alt($r('app.media.startIcon'))
                Column({ space: 4 }) {
                  Text(b.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(b.author)
                    .fontSize(12)
                    .fontColor('#999999')
                  Text(`人气 ${b.popular}`)
                    .fontSize(11)
                    .fontColor('#BBBBBB')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(Color.White)
              .borderRadius(10)
              .onClick(() => {
                this.pushDetail(b);
              })
            }
          }, (b: MangaBrief) => b.pathWord)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12, bottom: 12 })
        .scrollBar(BarState.Off)
      } else {
        // 主题筛选 chips(随当前源变化)
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.themes, (t: MangaTheme, index: number) => {
              Text(t.label)
                .fontSize(13)
                .fontColor(this.themeIndex === index ? Color.White : '#444444')
                .backgroundColor(this.themeIndex === index ? '#8A5CF6' : Color.White)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .borderRadius(14)
                .onClick(() => {
                  if (this.themeIndex !== index) {
                    this.themeIndex = index;
                    this.reload();
                  }
                })
            }, (t: MangaTheme) => t.label)
          }
          .padding({ left: 12, right: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')

        // 源切换 + 排序
        Row({ space: 8 }) {
          Text(`源:${this.sourceName} ▾`)
            .fontSize(13)
            .fontColor('#E06C00')
            .backgroundColor('#FDF0E7')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(14)
            .margin({ left: 12, top: 6 })
            .bindMenu(this.sourceMenu())
          Text(this.orderByPopular ? '按人气' : '按最新')
            .fontSize(13)
            .fontColor('#8A5CF6')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor('#F1EAFE')
            .borderRadius(12)
            .margin({ top: 6 })
            .onClick(() => {
              this.orderByPopular = !this.orderByPopular;
              this.reload();
            })
          if (this.loading) {
            LoadingProgress()
              .width(18)
              .height(18)
              .margin({ top: 6 })
          }
        }
        .width('100%')

        if (this.error.length > 0 && this.comics.length === 0) {
          Column({ space: 10 }) {
            Text(this.error)
              .fontSize(13)
              .fontColor('#CC3333')
              .padding(16)
            Button('重试')
              .onClick(() => {
                this.reload();
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          // 定宽卡片网格:列数按宽度自适应,行内所有空隙(含两侧)相等
          Scroll() {
            Column({ space: 12 }) {
              ForEach(chunkRows<MangaBrief>(this.comics, this.gridCols), (row: MangaBrief[]) => {
                Row() {
                  ForEach(row, (b: MangaBrief) => {
                    Column() {
                      this.comicCard(b)
                    }
                    .width(CARD_W)
                  }, (b: MangaBrief) => b.pathWord)
                }
                .width('100%')
                .justifyContent(FlexAlign.SpaceEvenly)
              }, (row: MangaBrief[], idx: number) => `row-${idx}-${row.length > 0 ? row[0].pathWord : ''}`)
            }
            .width('100%')
            .padding({ top: 8, bottom: 16 })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onAreaChange((_o: Area, n: Area) => {
            this.updateCols(Number(n.width));
          })
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F3F5')
  }
}

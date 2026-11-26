import { Nav } from '../../common/Nav';
import { BtDiagNavParam } from '../../common/NavParams';
import { BtDiag, DiagLine, DiagOptions } from '../../datasources/bt/BtDiag';

/**
 * BT 诊断:对一条磁力跑全链路实测(元数据 → tracker → peer 握手 → 吞吐),
 * 是端上 BT 内核的真机技术验证入口(§4.5 步骤 1+2 并作一步)。
 * 输入留空 = 自动取 AnimeGarden 最新 v1 资源。
 */
@ComponentV2
export struct BtDiagPage {
  @Local input: string = '';
  @Local running: boolean = false;
  @Local lines: DiagLine[] = [];
  @Local wantData: boolean = true;

  aboutToAppear(): void {
    const params = Nav.stack.getParamByName('BtDiag') as BtDiagNavParam[];
    const p = params !== undefined && params.length > 0 ? params[params.length - 1] : undefined;
    if (p !== undefined && p.magnet.length > 0) {
      this.input = p.magnet;
    }
  }

  stateColor(s: string): string {
    if (s === 'ok') {
      return '#2E9E5B';
    }
    if (s === 'fail') {
      return '#CC3333';
    }
    if (s === 'warn') {
      return '#D48806';
    }
    if (s === 'run') {
      return '#3471D5';
    }
    return '#999999';
  }

  stateText(s: string): string {
    if (s === 'ok') {
      return '✓';
    }
    if (s === 'fail') {
      return '✗';
    }
    if (s === 'warn') {
      return '⚠';
    }
    if (s === 'run') {
      return '…';
    }
    return '·';
  }

  run(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.lines = [];
    const opts: DiagOptions = { wantData: this.wantData, maxPeers: 12 };
    BtDiag.run(this.input, opts, (line: DiagLine) => {
      const idx = this.lines.findIndex((l: DiagLine) => l.id === line.id);
      if (idx < 0) {
        this.lines = this.lines.concat([line]);
      } else {
        const arr = this.lines.slice();
        arr[idx] = line;
        this.lines = arr;
      }
    }).then(() => {
      this.running = false;
    }).catch((e: Object) => {
      this.running = false;
      const line: DiagLine = {
        id: BtDiag.L_SUM, label: '结论', state: 'fail', detail: `诊断异常中断:${e}`
      };
      this.lines = this.lines.concat([line]);
    });
  }

  @Builder
  lineRow(line: DiagLine) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.stateText(line.state))
          .fontSize(14)
          .fontColor(this.stateColor(line.state))
        Text(line.label)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        if (line.state === 'run') {
          LoadingProgress()
            .width(14)
            .height(14)
        }
      }
      .width('100%')

      if (line.detail.length > 0) {
        Text(line.detail)
          .fontSize(12)
          .fontColor('#666666')
          .width('100%')
          .lineHeight(18)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 8 }) {
          TextInput({ placeholder: 'magnet: 或 40 位 infohash(留空自动取最新)', text: this.input })
            .onChange((v: string) => {
              this.input = v;
            })
            .layoutWeight(1)
            .backgroundColor(Color.White)
            .borderRadius(20)
          Button(this.running ? '诊断中' : '运行')
            .borderRadius(20)
            .enabled(!this.running)
            .onClick(() => {
              this.run();
            })
        }
        .width('100%')
        .padding(12)

        Row({ space: 6 }) {
          Checkbox()
            .select(this.wantData)
            .selectedColor('#3471D5')
            .onChange((v: boolean) => {
              this.wantData = v;
            })
            .width(18)
            .height(18)
          Text('吞吐实测(向最多 3 个 peer 各请求 ≤1MiB,消耗少量流量)')
            .fontSize(12)
            .fontColor('#666666')
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 12, bottom: 4 })

        List({ space: 8 }) {
          ForEach(this.lines, (line: DiagLine) => {
            ListItem() {
              this.lineRow(line)
            }
          }, (line: DiagLine) => `${line.id}-${line.state}-${line.detail.length}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12, bottom: 12 })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F1F3F5')
    }
    .title('BT 诊断')
    .backgroundColor('#F1F3F5')
  }
}

@Builder
export function btDiagPageBuilder() {
  BtDiagPage()
}

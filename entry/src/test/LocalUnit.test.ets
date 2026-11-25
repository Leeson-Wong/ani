import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { MaccmsParser } from '../main/ets/datasources/cms/MaccmsParser';

export default function localUnitTest() {
  describe('MaccmsParserTest', () => {
    it('parseBasicRoutes', 0, () => {
      const routes = MaccmsParser.parsePlayRoutes(
        'ffm3u8$$$kkm3u8',
        '第01集$https://a.com/v/1.m3u8#第02集$https://a.com/v/2.m3u8'
          + '$$$第1集$https://b.com/e/1.mp4#第2集$https://b.com/e/2.mp4'
      );
      expect(routes.length).assertEqual(2);
      expect(routes[0].name).assertEqual('ffm3u8');
      expect(routes[0].episodes.length).assertEqual(2);
      expect(routes[0].episodes[0].name).assertEqual('第01集');
      expect(routes[0].episodes[1].url).assertEqual('https://a.com/v/2.m3u8');
      expect(routes[1].episodes[1].name).assertEqual('第2集');
    });

    it('filterNonPlayableRoute', 0, () => {
      // 首集不是 mp4/m3u8 的线路(json 解析器源)整条被过滤
      const routes = MaccmsParser.parsePlayRoutes(
        'cloud$$$ffm3u8',
        '第1集$https://x.com/play/1.html'
          + '$$$第1集$https://y.com/1.m3u8'
      );
      expect(routes.length).assertEqual(1);
      expect(routes[0].name).assertEqual('ffm3u8');
    });

    it('dedupeByPrefix', 0, () => {
      // 同一 URL 前缀的集数被去重
      const routes = MaccmsParser.parsePlayRoutes(
        'single',
        '第1集$https://a.com/1.m3u8#第1集$https://a.com/1.m3u8?token=abc#第2集$https://a.com/2.m3u8'
      );
      expect(routes[0].episodes.length).assertEqual(2);
    });

    it('noDollarSeparator', 0, () => {
      // 无 $ 分隔:整段当 URL,名为序号
      const routes = MaccmsParser.parsePlayRoutes('r', 'https://a.com/1.m3u8#https://a.com/2.m3u8');
      expect(routes[0].episodes[0].name).assertEqual('1');
      expect(routes[0].episodes[0].url).assertEqual('https://a.com/1.m3u8');
    });

    it('cleanDescription', 0, () => {
      const text = MaccmsParser.cleanDescription('<p>简介&nbsp;A&lt;B&gt;</p><span>第二段</span>');
      expect(text).assertEqual('简介 A<B>第二段');
    });

    it('emptyInput', 0, () => {
      expect(MaccmsParser.parsePlayRoutes(undefined, undefined).length).assertEqual(0);
      expect(MaccmsParser.parsePlayRoutes('', '').length).assertEqual(0);
    });
  });
}

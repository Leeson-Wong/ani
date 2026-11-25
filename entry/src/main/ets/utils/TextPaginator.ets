import measure from '@ohos.measure';

/**
 * 章节文本分页:逐字符按 measureText 宽度折行,按可容行数装页。
 * 输出:每页一个已 join 的字符串(段落间空一行,段首两个全角空格缩进)。
 */
export class TextPaginator {
  private static widthCache: Map<string, number> = new Map();

  static charWidth(ch: string, fontSize: number): number {
    const key = `${fontSize}:${ch}`;
    const cached = TextPaginator.widthCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const w: number = measure.measureText({
      textContent: ch,
      fontSize: fontSize
    });
    TextPaginator.widthCache.set(key, w);
    return w;
  }

  static paginate(paragraphs: string[], fontSize: number, lineHeightRatio: number,
    pageWidth: number, pageHeight: number): string[] {
    const usableWidth = Math.floor(pageWidth);
    const lineHeight = Math.floor(fontSize * lineHeightRatio);
    const maxLines = Math.max(1, Math.floor(pageHeight / lineHeight));
    const pages: string[] = [];
    let currentLines: string[] = [];

    const flushPage = () => {
      if (currentLines.length > 0) {
        pages.push(currentLines.join('\n'));
        currentLines = [];
      }
    };

    for (let p = 0; p < paragraphs.length; p++) {
      const text = paragraphs[p].trim();
      if (text.length === 0) {
        continue;
      }
      // 段间空行(段首除外)
      if (currentLines.length > 0) {
        if (currentLines.length + 1 >= maxLines) {
          flushPage();
        } else {
          currentLines.push('');
        }
      }
      // 段首缩进两个全角空格
      let line = '　　';
      for (let i = 0; i < text.length; i++) {
        const ch = text.charAt(i);
        const w = TextPaginator.charWidth(ch, fontSize);
        if (line.length > 2 && TextPaginator.strWidth(line, fontSize) + w > usableWidth) {
          currentLines.push(line);
          line = ch;
          if (currentLines.length >= maxLines) {
            flushPage();
          }
        } else {
          line += ch;
        }
      }
      if (line.length > 0) {
        currentLines.push(line);
        if (currentLines.length >= maxLines) {
          flushPage();
        }
      }
    }
    flushPage();
    return pages.length > 0 ? pages : ['　　(空章节)'];
  }

  private static strWidth(s: string, fontSize: number): number {
    let w = 0;
    for (let i = 0; i < s.length; i++) {
      w += TextPaginator.charWidth(s.charAt(i), fontSize);
    }
    return w;
  }
}

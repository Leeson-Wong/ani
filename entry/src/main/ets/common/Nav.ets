/** 全局导航栈单例:@ComponentV2 普通成员禁止外部初始化,跨页共享用单例最稳 */
export class Nav {
  static readonly stack: NavPathStack = new NavPathStack();
}

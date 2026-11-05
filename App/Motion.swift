import SwiftUI

// 动效统一在这里：只用来说明变化，时长 120–350ms；
// 系统打开“减弱动态效果”时，页面切换只淡入淡出，其余直接切换
enum Motion {
  // 添加窗口两步之间左右切换
  static func page(reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.32)
  }

  // 提示条、表单行、卡片的出现、消失和状态变化；减弱动态效果时直接切换
  static func change(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.22)
  }

  // 悬停变色，和按钮一致
  static func hover(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.16)
  }

  // 页面推入：前进时新页从右边进来、旧页往左退，返回时反过来
  static func push(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
  }

  // 局部出现：从上方轻轻落下并淡入
  static func appear(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .offset(y: -Space.sm).combined(with: .opacity) // grid: ok 出现时的短暂位移
  }
}

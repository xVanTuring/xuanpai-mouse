import Foundation

/// 本地化文案入口：key 为英文原文，各语言在 Localizable.strings 中提供翻译
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

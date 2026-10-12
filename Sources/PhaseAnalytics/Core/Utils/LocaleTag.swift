import Foundation

/// Converts a Foundation locale identifier (`en_US`, `zh-Hans_CN`, `en_US@rg=gbzzzz`) into a
/// BCP 47 language tag (`en-US`, `zh-Hans-CN`) that fits the server's locale length limit,
/// dropping the script and then the region when needed.
internal func languageTag(fromLocaleIdentifier identifier: String) -> String? {
    let base = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
    let parts = base.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)

    guard let language = parts.first, (2...3).contains(language.count), language.allSatisfy(isASCIILetter) else {
        return nil
    }

    var script: String?
    var region: String?
    for part in parts.dropFirst() {
        if script == nil, region == nil, part.count == 4, part.allSatisfy(isASCIILetter) {
            script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
        } else if region == nil, part.count == 2, part.allSatisfy(isASCIILetter) {
            region = part.uppercased()
        } else if region == nil, part.count == 3, part.allSatisfy(\.isASCIIDigit) {
            region = part
        }
    }

    let candidates = [
        [language.lowercased(), script, region],
        [language.lowercased(), region],
        [language.lowercased()],
    ]
    let maxLength = ValidationConstants.Locale.maxLength
    for candidate in candidates {
        let tag = candidate.compactMap { $0 }.joined(separator: "-")
        if tag.count <= maxLength {
            return tag
        }
    }
    return nil
}

private func isASCIILetter(_ character: Character) -> Bool {
    character.isASCII && character.isLetter
}

extension Character {
    fileprivate var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}

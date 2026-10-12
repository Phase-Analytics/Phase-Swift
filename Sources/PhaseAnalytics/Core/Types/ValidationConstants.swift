import Foundation

public struct ValidationConstants {
    public struct DeviceID {
        public static let minLength = 8
        public static let maxLength = 128
        public static let pattern = #"^[A-Za-z0-9_-]+$"#
    }

    public struct SessionID {
        public static let minLength = 8
        public static let maxLength = 128
        public static let pattern = #"^[A-Za-z0-9_-]+$"#
    }

    public struct EventName {
        public static let minLength = 1
        public static let maxLength = 256
        // ASCII-only on purpose: the server's `\w` (JavaScript) does not match non-ASCII letters.
        public static let pattern = #"^[A-Za-z0-9_./ -]+$"#
    }

    public struct EventParams {
        public static let maxSize = 8192
        public static let maxDepth = 6
        public static let maxKeys = 32
        public static let maxKeyLength = 32
        public static let maxStringValueLength = 256
    }

    public struct DeviceProperties {
        public static let maxSize = 50_000
        public static let maxKeyLength = 128
    }

    public struct Batch {
        public static let maxSize = 1000
    }

    public struct Version {
        public static let osVersionMaxLength = 64
    }

    public struct Model {
        public static let maxLength = 128
    }

    public struct Locale {
        public static let maxLength = 10
    }
}

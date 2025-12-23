import Foundation

#if canImport(UIKit)
    import UIKit

    public func getIOSDeviceInfo() async -> DeviceInfo {
        let model = await getModel()
        let fallbackModel = !model.isEmpty ? model : await getDeviceType()?.rawValue

        return DeviceInfo(
            osVersion: await getOSVersion(),
            platform: .ios,
            locale: getLocale(),
            model: fallbackModel
        )
    }

    @MainActor
    private func getDeviceType() -> DeviceType? {
        let idiom = UIDevice.current.userInterfaceIdiom

        switch idiom {
        case .phone:
            return .phone
        case .pad:
            return .tablet
        case .mac:
            return .desktop
        default:
            return nil
        }
    }

    @MainActor
    private func getOSVersion() -> String {
        return UIDevice.current.systemVersion
    }

    private func getLocale() -> String {
        return Locale.current.identifier
    }

    @MainActor
    private func getModel() -> String {
        return UIDevice.current.model
    }
#endif

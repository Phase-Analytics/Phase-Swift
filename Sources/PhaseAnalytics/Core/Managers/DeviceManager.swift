import Foundation
import ULID

internal actor DeviceManager {
    private var deviceID: String?
    private let sender: BatchSender
    private let storage: StorageAdapter
    private let getDeviceInfo: @Sendable () async -> DeviceInfo
    private let collectDeviceInfo: Bool
    private let collectLocale: Bool
    private let apiKey: String

    private var initPromise: Task<String, Never>?

    init(
        sender: BatchSender,
        storage: StorageAdapter,
        getDeviceInfo: @escaping @Sendable () async -> DeviceInfo,
        config: PhaseConfig
    ) {
        self.sender = sender
        self.storage = storage
        self.getDeviceInfo = getDeviceInfo
        self.collectDeviceInfo = config.deviceInfo
        self.collectLocale = config.userLocale
        self.apiKey = config.apiKey
    }

    func initialize() async -> String {
        if let promise = initPromise {
            return await promise.value
        }

        if let existingID = deviceID {
            return existingID
        }

        let promise = Task<String, Never> {
            await doInitialize()
        }
        initPromise = promise

        let result = await promise.value
        initPromise = nil
        return result
    }

    private func doInitialize() async -> String {
        let storedApiKeyResult = await storage.getItem(key: StorageKeys.apiKey) as Result<String?, Error>
        var shouldResetDevice = false

        if case .success(let storedApiKey) = storedApiKeyResult {
            if let storedApiKey = storedApiKey, storedApiKey != apiKey {
                logger.info("API key changed. Resetting device ID.")
                shouldResetDevice = true

                _ = await storage.removeItem(key: StorageKeys.deviceID)
                _ = await storage.removeItem(key: StorageKeys.deviceInfo)
                // Items queued for the previous app's device would make the server reject every
                // batch they share with the new device ("multiple devices").
                await sender.clearQueue()
            }
        }

        _ = await storage.setItem(key: StorageKeys.apiKey, value: apiKey)

        let result = await storage.getItem(key: StorageKeys.deviceID) as Result<String?, Error>

        if !shouldResetDevice,
            case .success(let stored) = result,
            let stored = stored,
            case .success = Validator.validateDeviceID(stored),
            ULID(ulidString: stored) != nil  // the server decodes the device ID's ULID timestamp
        {
            deviceID = stored
        } else {
            deviceID = IDGenerator.generateDeviceID()

            let saveResult = await storage.setItem(key: StorageKeys.deviceID, value: deviceID!)
            if case .failure(let error) = saveResult {
                logger.error("Failed to persist device ID. Storage unavailable.", error)
            }
        }

        return deviceID!
    }

    func identify(properties: DeviceProperties? = nil) async {
        guard let payload = await buildDevicePayload(properties: properties) else {
            logger.error("Device ID not set. Call initialize() first.")
            return
        }

        await sender.enqueue(.device(payload: payload, clientOrder: 0, retryCount: nil))
        await cacheDeviceInfo(payload)
    }

    /// Forgets the stored identity and returns a newly generated device ID.
    func resetIdentity() async -> String {
        _ = await storage.removeItem(key: StorageKeys.deviceInfo)

        let newID = IDGenerator.generateDeviceID()
        deviceID = newID
        if case .failure(let error) = await storage.setItem(key: StorageKeys.deviceID, value: newID) {
            logger.error("Failed to persist device ID. Storage unavailable.", error)
        }
        return newID
    }

    private func cacheDeviceInfo(_ payload: CreateDeviceRequest) async {
        let result = await storage.setItem(key: StorageKeys.deviceInfo, value: payload)
        if case .success = result {
            logger.info("Device info cached successfully")
        } else if case .failure(let error) = result {
            logger.error("Failed to cache device info", error)
        }
    }

    private func buildDevicePayload(properties: DeviceProperties? = nil) async -> CreateDeviceRequest? {
        guard let deviceID = deviceID else { return nil }

        let info = await getDeviceInfo()
        let mergedProperties = buildProperties(properties: validated(properties)?.dictionary, info: info)
        let propsDict: [String: AnyCodable]? = mergedProperties?.mapValues { AnyCodable($0) }

        // Every field must satisfy the server schema: one invalid item fails the whole batch.
        return CreateDeviceRequest(
            deviceId: deviceID,
            osVersion: collectDeviceInfo ? clamp(info.osVersion, to: ValidationConstants.Version.osVersionMaxLength) : nil,
            platform: collectDeviceInfo ? info.platform : nil,
            locale: collectLocale ? info.locale.flatMap(languageTag(fromLocaleIdentifier:)) : nil,
            model: collectDeviceInfo ? clamp(info.model, to: ValidationConstants.Model.maxLength) : nil,
            properties: propsDict,
            disableGeolocation: !collectLocale
        )
    }

    private func validated(_ properties: DeviceProperties?) -> DeviceProperties? {
        guard let properties else { return nil }
        if case .failure(let error) = Validator.validateDeviceProperties(properties.dictionary) {
            logger.error("Invalid device properties. Identifying without them.", error)
            return nil
        }
        return properties
    }

    private func clamp(_ value: String?, to maxLength: Int) -> String? {
        guard let value, !value.isEmpty else { return nil }
        // Server limits count UTF-16 code units; trim whole characters until it fits.
        var result = value
        while result.utf16.count > maxLength {
            result.removeLast()
        }
        return result
    }

    private func buildProperties(
        properties: [String: Any]?,
        info: DeviceInfo
    ) -> [String: Any]? {
        guard collectDeviceInfo else {
            return properties
        }

        let trimmedVersion = info.appVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appVersion = trimmedVersion, !appVersion.isEmpty else {
            return properties
        }

        var merged: [String: Any] = ["app_version": appVersion]
        if let properties {
            merged.merge(properties) { _, new in new }
        }
        return merged
    }
}

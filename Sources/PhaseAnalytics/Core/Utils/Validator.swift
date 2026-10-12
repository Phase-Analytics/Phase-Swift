import Foundation

internal struct Validator {

    static func validateDeviceID(_ deviceID: String) -> Result<Void, PhaseError> {
        guard deviceID.count >= ValidationConstants.DeviceID.minLength else {
            return .failure(
                .validationFailed(
                    "Device ID must be at least \(ValidationConstants.DeviceID.minLength) characters"
                ))
        }

        guard deviceID.count <= ValidationConstants.DeviceID.maxLength else {
            return .failure(
                .validationFailed(
                    "Device ID must not exceed \(ValidationConstants.DeviceID.maxLength) characters"
                ))
        }

        guard deviceID.range(of: ValidationConstants.DeviceID.pattern, options: .regularExpression) != nil else {
            return .failure(
                .validationFailed(
                    "Device ID must match pattern: \(ValidationConstants.DeviceID.pattern)"
                ))
        }

        return .success(())
    }

    static func validateSessionID(_ sessionID: String) -> Result<Void, PhaseError> {
        guard sessionID.count >= ValidationConstants.SessionID.minLength else {
            return .failure(
                .validationFailed(
                    "Session ID must be at least \(ValidationConstants.SessionID.minLength) characters"
                ))
        }

        guard sessionID.count <= ValidationConstants.SessionID.maxLength else {
            return .failure(
                .validationFailed(
                    "Session ID must not exceed \(ValidationConstants.SessionID.maxLength) characters"
                ))
        }

        guard sessionID.range(of: ValidationConstants.SessionID.pattern, options: .regularExpression) != nil else {
            return .failure(
                .validationFailed(
                    "Session ID must match pattern: \(ValidationConstants.SessionID.pattern)"
                ))
        }

        return .success(())
    }

    static func validateEventName(_ name: String) -> Result<Void, PhaseError> {
        guard name.count >= ValidationConstants.EventName.minLength else {
            return .failure(
                .validationFailed(
                    "Event name must be at least \(ValidationConstants.EventName.minLength) character(s)"
                ))
        }

        guard name.count <= ValidationConstants.EventName.maxLength else {
            return .failure(
                .validationFailed(
                    "Event name must not exceed \(ValidationConstants.EventName.maxLength) characters"
                ))
        }

        guard name.range(of: ValidationConstants.EventName.pattern, options: .regularExpression) != nil else {
            return .failure(
                .validationFailed(
                    "Event name must match pattern: \(ValidationConstants.EventName.pattern)"
                ))
        }

        return .success(())
    }

    static func validateEventParams(_ params: EventParams?) -> Result<Void, PhaseError> {
        guard let params = params else {
            return .success(())
        }

        let dict = params.dictionary
        let limits = ValidationConstants.EventParams.self

        guard dict.count <= limits.maxKeys else {
            return .failure(.validationFailed("Event params exceed maximum key count of \(limits.maxKeys)"))
        }

        // Lengths are UTF-16 code units to match the server's JavaScript `string.length`.
        for (key, value) in dict {
            guard key.utf16.count <= limits.maxKeyLength else {
                return .failure(
                    .validationFailed("Param key '\(key)' exceeds maximum length of \(limits.maxKeyLength)"))
            }

            if let failure = flatValueFailure(key: key, value: value) {
                return .failure(failure)
            }

            if let string = value as? String, string.utf16.count > limits.maxStringValueLength {
                return .failure(
                    .validationFailed(
                        "Param '\(key)' exceeds maximum string length of \(limits.maxStringValueLength)"))
            }
        }

        return validateJSONSize(dict, maxSize: limits.maxSize, label: "Event params")
    }

    /// Device properties share a batch with other items; an invalid one makes the server reject
    /// the whole request, so they must be checked before they are queued.
    static func validateDeviceProperties(_ properties: [String: Any]) -> Result<Void, PhaseError> {
        let limits = ValidationConstants.DeviceProperties.self

        for (key, value) in properties {
            guard key.utf16.count <= limits.maxKeyLength else {
                return .failure(
                    .validationFailed("Property key '\(key)' exceeds maximum length of \(limits.maxKeyLength)"))
            }

            if let failure = flatValueFailure(key: key, value: value) {
                return .failure(failure)
            }
        }

        return validateJSONSize(properties, maxSize: limits.maxSize, label: "Device properties")
    }

    private static func flatValueFailure(key: String, value: Any) -> PhaseError? {
        guard isFlatValue(value) else {
            return .validationFailed(
                "'\(key)' must be a String, Int, Double, Bool, or nil. Nested objects/arrays are not allowed.")
        }

        // Non-finite numbers are not representable in JSON; JSONSerialization raises an
        // Objective-C exception (a crash) on them, so they must be rejected before serializing.
        guard isFinite(value) else {
            return .validationFailed("'\(key)' must be a finite number")
        }

        return nil
    }

    private static func validateJSONSize(_ dict: [String: Any], maxSize: Int, label: String) -> Result<
        Void, PhaseError
    > {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            guard data.count <= maxSize else {
                return .failure(.validationFailed("\(label) exceed maximum size of \(maxSize) bytes"))
            }
        } catch {
            return .failure(.validationFailed("\(label) must be JSON serializable"))
        }

        return .success(())
    }

    private static func isFinite(_ value: Any) -> Bool {
        if let double = value as? Double {
            return double.isFinite
        }
        if let float = value as? Float {
            return float.isFinite
        }
        return true
    }

    private static func isFlatValue(_ value: Any) -> Bool {
        if value is NSNull {
            return true
        }

        return value is String || value is Int || value is Double || value is Float || value is Bool || value is Int64
            || value is Int32
    }
}

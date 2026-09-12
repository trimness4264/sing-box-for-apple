#if JAILBREAK
    import Darwin
    import Foundation

    /// Grants Wi-Fi and cellular access to jailbreak-installed bundles on
    /// mainland China devices, where /Applications installs are not enrolled
    /// in the normal first-launch permission flow.
    public enum JailbreakNetworkPolicy {
        private static let coreTelephonyHandle: UnsafeMutableRawPointer? = dlopen(
            "/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
            RTLD_LAZY | RTLD_LOCAL
        )

        public static func allowWiFiAndCellular(for bundleIdentifiers: [String]) -> Bool {
            let bundleIdentifiers = Array(Set(bundleIdentifiers.filter { !$0.isEmpty })).sorted()
            guard !bundleIdentifiers.isEmpty else {
                NSLog("wireless data policy has no bundle identifiers")
                return false
            }
            guard let handle = coreTelephonyHandle,
                  let createSymbol = dlsym(handle, "_CTServerConnectionCreate"),
                  let setPolicySymbol = dlsym(handle, "_CTServerConnectionSetCellularUsagePolicy")
            else {
                NSLog("CoreTelephony wireless policy API is unavailable")
                return false
            }

            typealias CreateConnection = @convention(c) (
                CFAllocator?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
            ) -> UnsafeMutableRawPointer?
            typealias SetPolicy = @convention(c) (
                UnsafeMutableRawPointer?, CFString, CFDictionary
            ) -> Int64

            let createConnection = unsafeBitCast(createSymbol, to: CreateConnection.self)
            let setPolicy = unsafeBitCast(setPolicySymbol, to: SetPolicy.self)
            guard let connection = createConnection(kCFAllocatorDefault, nil, nil) else {
                NSLog("CoreTelephony wireless policy connection creation failed")
                return false
            }

            let policies = [
                "kCTCellularDataUsagePolicy": "kCTCellularDataUsagePolicyAlwaysAllow",
                "kCTWiFiDataUsagePolicy": "kCTCellularDataUsagePolicyAlwaysAllow",
            ] as CFDictionary
            var succeeded = true
            for bundleIdentifier in bundleIdentifiers {
                let result = setPolicy(connection, bundleIdentifier as CFString, policies)
                succeeded = succeeded && result == 0
                NSLog("CoreTelephony wireless policy for %@ returned %lld", bundleIdentifier, result)
            }
            return succeeded
        }
    }
#endif

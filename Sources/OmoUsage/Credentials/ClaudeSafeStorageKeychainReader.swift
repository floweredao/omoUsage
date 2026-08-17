struct ClaudeSafeStorageKeychainReader: KeychainReading {
    private let reader = SecurityKeychainReader()

    func value(service: String, account: String) throws -> String? {
        try reader.value(service: service, account: account)
    }
}

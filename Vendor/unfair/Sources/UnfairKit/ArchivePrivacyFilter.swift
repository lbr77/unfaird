enum ArchivePrivacyFilter {
    static func shouldRemoveEntry(path: String) -> Bool {
        shouldRemoveEntry(path: path, isDirectory: path.hasSuffix("/"))
    }

    static func shouldRemoveEntry(path: String, isDirectory: Bool) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3 else {
            return false
        }
        guard components[0] == "Payload" else {
            return false
        }

        for index in 1..<components.count where components[index] == "SC_Info" {
            if index < components.count - 1 {
                return true
            }
            if isDirectory {
                return true
            }
            return components[index - 1].hasSuffix(".framework") == false
        }
        return false
    }
}

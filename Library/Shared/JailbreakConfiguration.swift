#if JAILBREAK
    import Foundation

    public enum JailbreakConfiguration {
        /// RootHide (and relocated rootless bootstraps) expose `.jbroot` beside
        /// installed Mach-O files. Conventional rootless jailbreaks use `/var/jb`.
        public static let bootstrapRoot: String = {
            guard let executableURL = Bundle.main.executableURL else {
                return "/var/jb"
            }
            let jbrootPath = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(".jbroot", isDirectory: true)
                .path
            if FileManager.default.fileExists(atPath: jbrootPath) {
                return jbrootPath
            }
            return "/var/jb"
        }()

        public static func bootstrapPath(_ absolutePath: String) -> String {
            precondition(absolutePath.hasPrefix("/"))
            if absolutePath == bootstrapRoot || absolutePath.hasPrefix(bootstrapRoot + "/") {
                return absolutePath
            }
            return bootstrapRoot + absolutePath
        }

        public static let shellCandidates = [
            bootstrapPath("/bin/bash"),
            bootstrapPath("/bin/zsh"),
            bootstrapPath("/bin/fish"),
            bootstrapPath("/bin/sh"),
        ]

        public static let sftpServerPath = bootstrapPath("/usr/libexec/sftp-server")

        public static let systemSSHHostKeyPath = bootstrapPath("/etc/ssh/ssh_host_ed25519_key")
    }
#endif

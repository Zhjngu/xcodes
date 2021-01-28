import Foundation
import PromiseKit
import Path
import Version

public func selectXcode(shouldPrint: Bool, pathOrVersion: String, directory: Path) -> Promise<Void> {
    firstly { () -> Promise<ProcessOutput> in
        Current.shell.xcodeSelectPrintPath()
    }
    .then { output -> Promise<Void> in
        if shouldPrint {
            if output.out.isEmpty == false {
                Current.logging.log(output.out)
                Current.shell.exit(0)
                return Promise.value(())
            }
            else {
                Current.logging.log("No selected Xcode")
                Current.shell.exit(0)
                return Promise.value(())
            }
        }

        if let version = Version(xcodeVersion: pathOrVersion),
           let installedXcode = Current.files.installedXcodes(directory).first(withVersion: version) {
            return selectXcodeAtPath(installedXcode.path.string)
                .done { output in
                    Current.logging.log("Selected \(output.out)")
                    Current.shell.exit(0)
                }
        }
        else {
            return selectXcodeAtPath(pathOrVersion)
                .done { output in
                    Current.logging.log("Selected \(output.out)")
                    Current.shell.exit(0)
                }
                .recover { _ in
                    selectXcodeInteractively(currentPath: output.out, directory: directory)
                        .done { output in
                            Current.logging.log("Selected \(output.out)")
                            Current.shell.exit(0)
                        }
                }
        }
    }
}

public func selectXcodeInteractively(currentPath: String, directory: Path, shouldRetry: Bool) -> Promise<ProcessOutput> {
    if shouldRetry {
        func selectWithRetry(currentPath: String) -> Promise<ProcessOutput> {
            return firstly {
                selectXcodeInteractively(currentPath: currentPath, directory: directory)
            }
            .recover { error throws -> Promise<ProcessOutput> in
                guard case XcodeSelectError.invalidIndex = error else { throw error }
                Current.logging.log("\(error.legibleLocalizedDescription)\n")
                return selectWithRetry(currentPath: currentPath)
            }
        }

        return selectWithRetry(currentPath: currentPath)
    }
    else {
        return firstly {
            selectXcodeInteractively(currentPath: currentPath, directory: directory)
        }
    }
}

public func chooseFromInstalledXcodesInteractively(currentPath: String, directory: Path) -> Promise<InstalledXcode> {
    let sortedInstalledXcodes = Current.files.installedXcodes(directory).sorted { $0.version < $1.version }

    Current.logging.log("Available Xcode versions:")

    sortedInstalledXcodes
        .enumerated()
        .forEach { index, installedXcode in
            var output = "\(index + 1)) \(installedXcode.version.xcodeDescription)"
            if currentPath.hasPrefix(installedXcode.path.string) {
                output += " (Selected)"
            }
            Current.logging.log(output)
        }

    let possibleSelectionNumberString = Current.shell.readLine(prompt: "Enter the number of the Xcode to select: ")
    guard
        let selectionNumberString = possibleSelectionNumberString,
        let selectionNumber = Int(selectionNumberString),
        sortedInstalledXcodes.indices.contains(selectionNumber - 1)
    else {
        let error = XcodeSelectError.invalidIndex(min: 1, max: sortedInstalledXcodes.count, given: possibleSelectionNumberString)
        return Promise(error: error)
    }

    return Promise.value(sortedInstalledXcodes[selectionNumber - 1]) 
}

public func selectXcodeInteractively(currentPath: String, directory: Path) -> Promise<ProcessOutput> {
    return chooseFromInstalledXcodesInteractively(currentPath: currentPath, directory: directory)
        .map(\.path.string)
        .then(selectXcodeAtPath)
}

public func selectXcodeAtPath(_ pathString: String) -> Promise<ProcessOutput> {
    firstly { () -> Promise<String?> in
        guard Current.files.fileExists(atPath: pathString) else {
            throw XcodeSelectError.invalidPath(pathString)
        }

        let passwordInput = {
            Promise<String> { seal in
                Current.logging.log("xcodes requires superuser privileges to select an Xcode")
                guard let password = Current.shell.readSecureLine(prompt: "macOS User Password: ") else { seal.reject(XcodeInstaller.Error.missingSudoerPassword); return }
                seal.fulfill(password + "\n")
            }
        }

        return Current.shell.authenticateSudoerIfNecessary(passwordInput: passwordInput)
    }
    .then { possiblePassword in
        Current.shell.xcodeSelectSwitch(password: possiblePassword, path: pathString)
    }
    .then { _ in
        Current.shell.xcodeSelectPrintPath()
    }
}

public enum XcodeSelectError: LocalizedError {
    case invalidPath(String)
    case invalidIndex(min: Int, max: Int, given: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let pathString):
            return "Not a valid Xcode path: \(pathString)"
        case .invalidIndex(let min, let max, let given):
            return "Not a valid number. Expecting a whole number between \(min)-\(max), but given \(given ?? "nothing")."
        }
    }
}

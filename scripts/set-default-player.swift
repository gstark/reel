// Makes Reel the default app for every video type it declares.
// Usage: xcrun swift scripts/set-default-player.swift /path/to/Reel.app
//
// It reads the extensions of the "Video files" document type in the app's Info.plist.
// For each extension, it sets Reel as the default for every video type that claims it,
// so files open in Reel even when another app also declares a type for the extension.
// It skips types that are not video, such as a source code type that shares an extension.
//
// macOS asks the user to confirm each change of a default app, and no API avoids that.
// So this changes only the types that do not open in Reel yet. After the first run,
// it asks nothing until a new extension is added.
import AppKit
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    print("Usage: set-default-player.swift /path/to/Reel.app")
    exit(2)
}
let app = URL(fileURLWithPath: CommandLine.arguments[1])
guard let bundle = Bundle(url: app), let info = bundle.infoDictionary,
      let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]],
      let extensions = documentTypes.first(where: { $0["CFBundleTypeName"] as? String == "Video files" })?["CFBundleTypeExtensions"] as? [String]
else {
    print("\(app.path) has no \"Video files\" document type.")
    exit(1)
}

// TypeScript files use these extensions. A video type that claims one of them is not changed,
// also when it claims a video extension too. For example, the AVCHD type claims .mts and .m2ts.
let typeScriptExtensions: Set = ["ts", "mts"]

var types: [UTType] = []
for ext in extensions {
    for type in UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: .audiovisualContent)
    where !types.contains(type) && typeScriptExtensions.isDisjoint(with: type.tags[.filenameExtension] ?? []) {
        types.append(type)
    }
}

let missing = types.filter {
    NSWorkspace.shared.urlForApplication(toOpen: $0).flatMap { Bundle(url: $0)?.bundleIdentifier } != bundle.bundleIdentifier
}
if missing.isEmpty {
    print("Reel is already the default app for all \(types.count) video types (\(extensions.count) extensions).")
    exit(0)
}
print("Setting Reel as the default app for \(missing.count) video types. macOS asks you to confirm each one.")

var failures: [String] = []
for type in missing {
    // The completion handler is optional, so Swift does not make an async version. Wait for it here.
    let error: Error? = await withCheckedContinuation { done in
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { done.resume(returning: $0) }
    }
    if let error {
        failures.append("\(type.identifier): \(error.localizedDescription)")
    }
}

print("Reel is the default app for \(types.count - failures.count) of \(types.count) video types (\(extensions.count) extensions).")
failures.forEach { print("  failed: \($0)") }
exit(failures.isEmpty ? 0 : 1)

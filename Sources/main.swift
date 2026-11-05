import AppKit

// Uploads write to an ssh process. When ssh exits early, the write fails with an error
// instead of a SIGPIPE that ends the app.
signal(SIGPIPE, SIG_IGN)

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

<img src="assets/icon.svg" width="64" height="64" alt="">

# Reel

A minimal macOS video player. It uses libmpv for playback, the same engine as IINA.

## Features

- The window opens at the size of the video. Large videos scale down to fit the screen.
- A double-click on the title bar toggles between "fill the screen" and the previous size.
- The title bar and the control bar sit above and below the video. They never cover it.
- Window resizes keep the video aspect ratio.
- When playback is paused, the control bar shows the frame number and the time in milliseconds. For MP4 and MOV files, the frame number is exact, also for variable frame rate screen recordings. For other files, mpv estimates it ("≈").
- mpv gets the display ICC profile, as in IINA. The profile updates when the window moves to another screen.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Space | Play or pause |
| ← / → | Back or forward 5 seconds |
| ⇧← / ⇧→ | Back or forward 30 seconds |
| , / . | Previous or next frame (pauses playback) |
| ⌘C | Copy the current frame |
| ⇧⌘C | Copy the current frame and 5 frames on each side |
| ⌃⌘F | Full screen |

The control bar has buttons for each of these actions.

## Copying frames

The copy commands pause playback and save each frame as a full-resolution PNG. Each frame becomes one clipboard item, with the PNG data and the file:

- Finder pastes the PNG files.
- Image apps (Slack, Figma, Preview) paste the images.

The file names include the frame number, for example `recording-f00573.png`. The files stay in `~/Library/Caches/com.gstark.Reel/Frames/`. Reel removes folders older than one day.

## Libraries

Reel gets libmpv and FFmpeg from the [MPVKit](https://github.com/mpvkit/MPVKit) Swift package. The package has prebuilt static libraries, so the app has no external dylibs. The build uses the LGPL product of MPVKit.

`project.yml` sets one exact MPVKit version. To move to the newest MPVKit release:

```sh
just update-dependencies         # newest release
just update-dependencies 1.0.0   # a specific MPVKit tag
```

The script writes the version into `project.yml`, regenerates the project, and resolves the package. It prints the link to the release notes. MPVKit marks its FFmpeg update builds (for example `1.1.0-n9.0.2`) as prereleases. The script includes them.

The FFmpeg build in MPVKit has no image encoders. Reel writes the PNG files with ImageIO.

## Build and install

Requirements: Xcode, XcodeGen (`brew install xcodegen`), just, and network access for the first package download.

```sh
just install   # builds Release and installs /Applications/Reel.app
```

`just install` also makes Reel the default app for 62 video file extensions. It leaves out `.ts` and `.mts`, because TypeScript files use those extensions. It also does not change a video type that claims one of them. macOS uses one type for `.mts` and `.m2ts`, so `.m2ts` files keep their current app. macOS asks you to confirm each change, so the first install shows one prompt per type. Later installs change only types that do not open in Reel yet, so they ask nothing. To change this, use Finder: Get Info > Open with > (an app) > Change All. To add an extension, add it to the "Video files" document type in `project.yml`. If macOS does not declare a type for the extension, also add it to `com.gstark.reel.video`.

For development, run `xcodegen generate` and open `Reel.xcodeproj`.

## Homebrew release

`just homebrew` publishes a release:

1. It stops if the working tree has changes.
2. It builds Release with the version `MARKETING_VERSION-yyyyMMddHHmm`.
3. It pushes the branch and creates a GitHub release in `gstark/reel` with the zipped app.
4. It writes `Casks/reel.rb` in the `gstark/tap` tap, then commits and pushes it.

Install with `brew install gstark/tap/reel`.

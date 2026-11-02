set shell := ["bash", "-euo", "pipefail", "-c"]

derived := "build"
release_app := derived + "/Build/Products/Release/Reel.app"
repo := "gstark/reel"
tap := "gstark/tap"
cask := "reel"

default:
    @just --list

# Regenerate Reel.xcodeproj from project.yml
generate:
    xcodegen generate

# Build the Release app into build/. Extra arguments go to xcodebuild.
build *settings: generate
    xcodebuild -project Reel.xcodeproj -scheme Reel -configuration Release -quiet \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath {{ derived }} {{ settings }} build

# Build, quit the running Reel, copy it to /Applications, and make it the default app for every video type
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    if /usr/bin/pgrep -xq Reel; then
      /usr/bin/osascript -e 'tell application id "com.gstark.Reel" to quit' 2>/dev/null || true
      while /usr/bin/pgrep -xq Reel; do /bin/sleep 0.2; done
    fi
    /bin/rm -rf /Applications/Reel.app
    /usr/bin/ditto "{{ release_app }}" /Applications/Reel.app
    lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    # Only the installed copy opens files. A build copy in build/ can be older and lack the icon.
    "$lsregister" -u "$PWD/{{ release_app }}" 2>/dev/null || true
    "$lsregister" -u "$PWD/{{ derived }}/Build/Products/Debug/Reel.app" 2>/dev/null || true
    "$lsregister" -f /Applications/Reel.app
    echo "Installed /Applications/Reel.app"
    xcrun swift scripts/set-default-player.swift /Applications/Reel.app

# Move mpv, FFmpeg, and the other media libraries to the newest MPVKit release, or to the given tag
update-dependencies *tag:
    scripts/update-dependencies.sh {{ tag }}

# Build, publish a GitHub release, and update the cask in the Homebrew tap
homebrew:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "$(git status --porcelain)" ]]; then
      echo "The working tree has changes. Commit them first." >&2
      exit 1
    fi

    base="$(/usr/bin/awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"
    stamp="$(/bin/date +%Y%m%d%H%M)"
    version="${base}-${stamp}"
    zip="build/Reel-${version}.zip"

    just build CURRENT_PROJECT_VERSION="$stamp"
    /bin/rm -f build/Reel-*.zip
    /usr/bin/ditto -c -k --keepParent "{{ release_app }}" "$zip"
    sha="$(/usr/bin/shasum -a 256 "$zip" | /usr/bin/cut -d' ' -f1)"

    git push origin "$(git branch --show-current)"
    gh release create "v${version}" "$zip" -R {{ repo }} \
      --target "$(git rev-parse HEAD)" \
      --title "Reel $version" \
      --notes "Build of $(git rev-parse --short HEAD)."

    tap_dir="$(brew --repository {{ tap }})"
    git -C "$tap_dir" pull --ff-only
    /bin/mkdir -p "$tap_dir/Casks"
    cat > "$tap_dir/Casks/{{ cask }}.rb" <<EOF
    cask "{{ cask }}" do
      version "$version"
      sha256 "$sha"

      url "https://github.com/{{ repo }}/releases/download/v#{version}/Reel-#{version}.zip"
      name "Reel"
      desc "Minimal video player built on libmpv"
      homepage "https://github.com/{{ repo }}"

      depends_on arch: :arm64
      depends_on macos: ">= :sonoma"

      app "Reel.app"

      # The build is ad-hoc signed and not notarized, so remove the quarantine flag to let it open.
      postflight_steps do
        run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{{{appdir}}/Reel.app"]
      end

      uninstall quit: "com.gstark.Reel"
    end
    EOF
    git -C "$tap_dir" add "Casks/{{ cask }}.rb"
    git -C "$tap_dir" commit -m "{{ cask }} $version"
    git -C "$tap_dir" push

    echo "Released $version. Run 'brew install {{ tap }}/{{ cask }}' to install it."

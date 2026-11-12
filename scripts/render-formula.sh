#!/usr/bin/env bash
# Prints the Homebrew formula for a released version.
# Usage: scripts/render-formula.sh <version> <sha256 of Skica-<version>.zip>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version> <sha256>" >&2
  exit 1
fi

VERSION="$1"
SHA256="$2"
REPOSITORY="aleksandargosevski/skica"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must look like 1.2.3, got \"$VERSION\"" >&2
  exit 1
fi
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Error: sha256 must be 64 lowercase hex characters" >&2
  exit 1
fi

cat <<FORMULA
class Skica < Formula
  desc "Fast, keyboard-first design app for macOS"
  homepage "https://github.com/${REPOSITORY}"
  url "https://github.com/${REPOSITORY}/releases/download/v${VERSION}/Skica-${VERSION}.zip"
  sha256 "${SHA256}"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    # Homebrew enters an archive's single top-level directory, which here is Skica.app itself.
    source = File.directory?("Contents") ? "." : "Skica.app"
    (prefix/"Skica.app").install Dir["#{source}/*"]
    bin.install_symlink prefix/"Skica.app/Contents/Helpers/skica"
  end

  def caveats
    <<~EOS
      Make Skica visible to Spotlight, Raycast and the Dock:
        ln -sfn #{opt_prefix}/Skica.app /Applications/Skica.app

      Open Skica once so Finder shows previews of .skica files.
      The skica command exports and converts files: skica --help
      Shortcuts live in ~/.config/skica/keybindings.json.
    EOS
  end

  test do
    system bin/"skica", "sample", testpath/"sample.skica"
    system bin/"skica", "export", testpath/"sample.skica", "-o", testpath/"out"
    assert_path_exists testpath/"out/iPhone.png"
  end
end
FORMULA

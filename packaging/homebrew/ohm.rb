# typed: strict
# frozen_string_literal: true

# Tap cask for kuarezma/homebrew-ohm. Preview builds are not notarized (no Developer ID yet),
# so homebrew/cask cannot accept them; copy this file to Casks/ohm.rb in the tap on each release.
cask "ohm" do
  version "0.1.0"
  sha256 "9f6cf6607970c3f60cdfd3a8ec25743e35d2b63d64de2f56310a3856af6f163a"

  url "https://github.com/kuarezma/ohm/releases/download/v#{version}/Ohm-#{version}-preview.zip"
  name "Ohm"
  desc "Energy and core governor for Apple Silicon"
  homepage "https://github.com/kuarezma/ohm"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Ohm.app"

  caveats <<~EOS
    Ohm #{version} is an unsigned preview (not notarized). If macOS blocks it on first launch:
      System Settings > Privacy & Security > "Open Anyway"
    or run:
      xattr -dr com.apple.quarantine "#{appdir}/Ohm.app"
    Unsigned builds keep data locally, so the widget and `ohm receipt` show no data.
  EOS

  zap trash: [
    "~/Library/Application Support/Ohm",
    "~/Library/Caches/dev.ohm.Ohm",
    "~/Library/Group Containers/*.dev.ohm",
    "~/Library/Preferences/dev.ohm.Ohm.plist",
  ]
end

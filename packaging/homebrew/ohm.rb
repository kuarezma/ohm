# typed: strict
# frozen_string_literal: true

# ilk imzalı sürümde doldurulur; `brew audit --cask --new` o zaman koşulur
cask "ohm" do
  version "0.0.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/kuarezma/ohm/releases/download/v#{version}/Ohm-#{version}.zip"
  name "Ohm"
  desc "Energy and core governor for Apple Silicon"
  homepage "https://github.com/kuarezma/ohm"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Ohm.app"

  zap trash: [
    "~/Library/Application Support/Ohm",
    "~/Library/Caches/dev.ohm.Ohm",
    "~/Library/Group Containers/*.dev.ohm",
    "~/Library/Preferences/dev.ohm.Ohm.plist",
  ]
end

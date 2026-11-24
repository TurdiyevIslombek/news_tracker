# Homebrew cask for AI Pulse. This repo doubles as its tap:
#   brew tap TurdiyevIslombek/news_tracker https://github.com/TurdiyevIslombek/news_tracker
#   brew install --cask ai-pulse
# version + sha256 are bumped automatically by .github/workflows/release.yml.
cask "ai-pulse" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/TurdiyevIslombek/news_tracker/releases/download/v#{version}/AI-Pulse-#{version}.dmg"
  name "AI Pulse"
  desc "Daily AI research and news digest: menu bar app and desktop widget"
  homepage "https://github.com/TurdiyevIslombek/news_tracker"

  depends_on macos: ">= :sonoma"

  app "AI Pulse.app"

  # AI Pulse is free and not signed with a paid Apple Developer ID, so Gatekeeper
  # would block the first launch. Installing through this cask means you trust it.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/AI Pulse.app"]
  end

  uninstall quit: "io.github.turdiyevislombek.aipulse"

  zap trash: [
    "~/Library/Application Support/AI Pulse",
    "~/Library/Containers/io.github.turdiyevislombek.aipulse.widget",
    "~/Library/Preferences/io.github.turdiyevislombek.aipulse.plist",
  ]
end

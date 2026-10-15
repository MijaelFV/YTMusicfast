# Homebrew cask for YT Musicfast. This repository doubles as its tap:
#
#   brew tap mijaelfv/ytmusicfast https://github.com/MijaelFV/YTMusicfast
#   brew install --cask ytmusicfast
#
# scripts/release.sh updates `version` and `sha256` for each release.
cask "ytmusicfast" do
  version "0.1.0"
  sha256 "7ba7699691454b8c86848e076dcc74bed675d031cbdd6217d46a7a9b01aee06e"

  url "https://github.com/MijaelFV/YTMusicfast/releases/download/v#{version}/YTMusicfast-#{version}.dmg"
  name "YT Musicfast"
  desc "Fast, native YouTube Music client"
  homepage "https://github.com/MijaelFV/YTMusicfast"

  # The app updates itself (Sparkle).
  auto_updates true
  depends_on macos: ">= :sequoia"

  app "YT Musicfast.app"
  binary "#{appdir}/YT Musicfast.app/Contents/Helpers/ytmusicfast"

  zap trash: [
    "~/Library/Application Support/YTMusicfast",
    "~/Library/Caches/YTMusicfast",
    "~/Library/Caches/dev.ytmusicfast.app",
    "~/Library/HTTPStorages/dev.ytmusicfast.app",
    "~/Library/Preferences/dev.ytmusicfast.app.plist",
    "~/Library/WebKit/dev.ytmusicfast.app",
  ]
end

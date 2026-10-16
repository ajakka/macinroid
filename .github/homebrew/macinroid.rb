cask "macinroid" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/anyfikra/macinroid/releases/download/v#{version}/Macinroid-#{version}.zip"
  name "Macinroid"
  desc "Transfer files to and from Android devices over USB"
  homepage "https://github.com/anyfikra/macinroid"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Macinroid.app"

  # com.macinroid is the bundle identifier of version 1.0.0
  zap trash: [
    "~/Library/Caches/com.anyfikra.macinroid",
    "~/Library/Caches/com.macinroid",
    "~/Library/Caches/Macinroid",
    "~/Library/HTTPStorages/com.anyfikra.macinroid",
    "~/Library/HTTPStorages/com.macinroid",
    "~/Library/Logs/Macinroid",
    "~/Library/Preferences/com.anyfikra.macinroid.plist",
    "~/Library/Preferences/com.macinroid.plist",
    "~/Library/Saved Application State/com.anyfikra.macinroid.savedState",
    "~/Library/Saved Application State/com.macinroid.savedState",
  ]
end

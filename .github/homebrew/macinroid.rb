cask "macinroid" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/ajakka/macinroid/releases/download/v#{version}/Macinroid-#{version}.zip"
  name "Macinroid"
  desc "Transfer files to and from Android devices over USB"
  homepage "https://github.com/ajakka/macinroid"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Macinroid.app"

  zap trash: [
    "~/Library/Caches/com.macinroid",
    "~/Library/Caches/Macinroid",
    "~/Library/HTTPStorages/com.macinroid",
    "~/Library/Preferences/com.macinroid.plist",
    "~/Library/Saved Application State/com.macinroid.savedState",
  ]
end

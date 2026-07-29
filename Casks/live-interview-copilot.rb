cask "live-interview-copilot" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/jude864huang-debug/live-interview-copilot/releases/download/v#{version}/Live-Interview-Copilot.dmg"
  name "Live Interview Copilot"
  desc "Real-time interview copilot"
  homepage "https://github.com/jude864huang-debug/live-interview-copilot"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Live Interview Copilot.app"

  zap trash: [
    "~/Library/Application Support/Live Interview Copilot",
    "~/Library/Caches/com.jude864huang.liveinterviewcopilot.app",
    "~/Library/HTTPStorages/com.jude864huang.liveinterviewcopilot.app",
    "~/Library/Preferences/com.jude864huang.liveinterviewcopilot.app.plist",
    "~/Library/Saved Application State/com.jude864huang.liveinterviewcopilot.app.savedState",
    "~/Library/Caches/com.opengranola.app",
    "~/Library/HTTPStorages/com.opengranola.app",
    "~/Library/Preferences/com.opengranola.app.plist",
    "~/Library/Saved Application State/com.opengranola.app.savedState",
  ]
end

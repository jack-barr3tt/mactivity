cask "mactivity" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/jack-barr3tt/mactivity/releases/download/v#{version}/Mactivity-darwin-arm64.zip"
  name "Mactivity"
  desc "Menu bar agent that records focus intervals"
  homepage "https://github.com/jack-barr3tt/mactivity"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Mactivity.app"
end

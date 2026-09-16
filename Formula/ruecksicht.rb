class Ruecksicht < Formula
  desc "Desktop widget host that renders JavaScript widgets behind your windows"
  homepage "https://github.com/shepardxia/ruecksicht"
  url "https://github.com/shepardxia/ruecksicht/releases/download/v1.0.7/ruecksicht-1.0.7.tar.gz"
  sha256 "6db6bf51fcb62249388cd0f3d375ef3716b5a00d6ba066a1d76b114bf558bad7"
  license "GPL-3.0-or-later"
  head "https://github.com/shepardxia/ruecksicht.git", branch: "master"

  depends_on "esbuild" => :build
  depends_on macos: :ventura

  # A release tarball carries the generated client.js; a HEAD checkout does not,
  # and building one needs the Node toolchain.
  depends_on "node" => :build if build.head?

  def install
    # SwiftPM keeps its manifest and module caches under HOME, which the build
    # sandbox does not grant.
    ENV["HOME"] = buildpath
    ENV["ESBUILD"] = Formula["esbuild"].opt_bin/"esbuild"

    system "./build-app.sh"
    prefix.install "build/Rücksicht.app"
  end

  service do
    run opt_prefix/"Rücksicht.app/Contents/MacOS/Ruecksicht"
    # Quitting from the menu is a decision, not a fault: only a crash is worth
    # restarting.
    keep_alive crashed: true
    log_path var/"log/ruecksicht.log"
    error_log_path var/"log/ruecksicht.log"
  end

  def caveats
    <<~EOS
      Rücksicht is installed at
        #{opt_prefix}/Rücksicht.app

      To reach it from Finder, Spotlight and the Dock:
        ln -sfn #{opt_prefix}/Rücksicht.app /Applications

      To run it now and at every login:
        brew services start ruecksicht

      Widgets live in ~/Library/Application Support/Rücksicht/widgets.
    EOS
  end

  test do
    app = prefix/"Rücksicht.app"
    system "codesign", "--verify", "--strict", app
    assert_match "local.ruecksicht.Ruecksicht",
      shell_output("/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' '#{app}/Contents/Info.plist'")

    # The daemon is the whole app minus its windows: if it binds a port and
    # serves the page, the bundle is complete.
    port = free_port
    pid = spawn app/"Contents/MacOS/ubersichtd", "--port", port.to_s,
                "--public", "#{app}/Contents/Resources"
    begin
      sleep 3
      assert_match "<html", shell_output("curl -s http://127.0.0.1:#{port}/")
    ensure
      Process.kill "TERM", pid
      Process.wait pid
    end
  end
end

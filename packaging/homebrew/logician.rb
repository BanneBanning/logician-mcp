# frozen_string_literal: true

# Gives an AI agent verified, MCP-standard control of Logic Pro.
class Logician < Formula
  desc "MCP server giving AI agents verified hands and ears in Logic Pro"
  homepage "https://github.com/BanneBanning/logician-mcp"
  url "https://github.com/BanneBanning/logician-mcp/archive/refs/tags/v1.0.0-beta.1.tar.gz"
  # The v1.0.0-beta.1 source tarball, hashed from GitHub's own archive on
  # 2026-09-04. Re-hash it on every version bump: Homebrew verifies the
  # download against this and aborts on a mismatch.
  #   curl -fsSL <url> | shasum -a 256
  sha256 "d0582336c9298fbec1eea181ba37b2c5dd7f033a86c5d5e13c2b3010800f45ea"
  license "MIT"
  head "https://github.com/BanneBanning/logician-mcp.git", branch: "main"

  # No signing certificate exists for this project, so there is no bottle:
  # every install compiles from source on the user's own machine with their
  # own local toolchain. That is a deliberate trade (a minute or two of
  # build time) against needing a paid Apple Developer account to notarize
  # a binary.
  # Building needs a Swift 6 toolchain (Package.swift is swift-tools-version
  # 6.0), which ships in Xcode 16, which Apple installs only on macOS 14.5
  # or later. The BUILT binary would run on Ventura - but every install
  # here compiles from source, so the build floor is the real floor.
  depends_on macos: :sonoma

  def install
    # `swift build` needs the Swift toolchain, which ships inside Xcode's
    # Command Line Tools - NOT the full Xcode.app that Homebrew's built-in
    # `depends_on :xcode` requirement demands. Requiring the full IDE would
    # force a ~10 GB download onto a musician who only wants one binary, and
    # it isn't true: `swift build --disable-sandbox -c release` compiles fine
    # against CLT alone (verified locally against Xcode 26 / Swift 6.3).
    # Homebrew itself cannot install without the Command Line Tools already
    # present, so `swift` is already on the PATH in the overwhelming case;
    # this check exists to turn the rare exception into a named fix instead
    # of a raw linker/compiler error many lines into the build log.
    odie <<~EOS unless which("swift")
      The Swift toolchain is required to build logician from source.
      It ships with Xcode's Command Line Tools - install it with:
        xcode-select --install
      then run `brew install` again.
    EOS

    # macOS 14.0-14.4 passes `depends_on macos: :sonoma` but cannot install
    # Xcode 16, so its toolchain tops out at Swift 5.10 and the manifest is
    # refused before a line is compiled ("using Swift tools version 6.0.0 but
    # the installed version is ..."). Catch that here with the fix named,
    # rather than as a manifest error in the middle of a build log.
    swift_version = Utils.safe_popen_read("swift", "-version")[/Apple Swift version (\d+)/, 1].to_i
    odie <<~EOS if swift_version < 6
      logician needs a Swift 6 toolchain to build (found Swift #{swift_version}).
      Swift 6 ships with Xcode 16, which requires macOS 14.5 or later.
      Update macOS, then install Apple's Command Line Tools:
        xcode-select --install
      and run `brew install` again.
    EOS

    system "swift", "build",
           "--disable-sandbox",
           "-c", "release",
           "--product", "logician"
    bin.install ".build/release/logician"
  end

  def caveats
    <<~EOS
      Homebrew has only built and installed the `logician` binary. Logic Pro
      cannot be driven yet - three one-time steps remain, and Logician itself
      walks you through all of them:

        1. Register this binary with your MCP client (Claude, Gemini, Cursor, …).
           Run:
             logician setup

        2. Install the Mackie Control surface Logician talks to Logic through.
           `logician setup` prints the exact Control Surfaces > Setup steps and
           the port names to select (or drive it by hand - see the README).

        3. Grant Accessibility to your MCP client, for the tools that fall back
           to Logic's UI (macOS will prompt, or: System Settings > Privacy &
           Security > Accessibility).

      Once all three are done, ask your agent to run `logic_health` - it
      verifies every step above and names the exact fix for anything still
      missing.
    EOS
  end

  test do
    # Logician speaks MCP over stdio; it never touches Logic Pro, the
    # Accessibility tree or the MIDI bridge until a tool that needs them is
    # actually called. `initialize` + `tools/list` is therefore a real,
    # hermetic round trip through the same JSON-RPC path a client uses -
    # proof the binary starts, negotiates the protocol and can enumerate
    # its tools, with nothing live required.
    initialize_request = {
      jsonrpc: "2.0",
      id:      1,
      method:  "initialize",
      params:  {
        protocolVersion: "2025-03-26",
        capabilities:    {},
        clientInfo:      { name: "brew-test", version: "1.0" },
      },
    }.to_json

    tools_list_request = {
      jsonrpc: "2.0",
      id:      2,
      method:  "tools/list",
    }.to_json

    output = pipe_output(
      bin/"logician",
      "#{initialize_request}\n#{tools_list_request}\n",
      0,
    )

    lines = output.lines.map(&:strip).reject(&:empty?)
    assert_equal 2, lines.length, "expected one JSON-RPC response per request, got:\n#{output}"

    initialize_response = JSON.parse(lines[0])
    assert_equal 1, initialize_response["id"]
    assert initialize_response.key?("result"), "initialize did not return a result: #{lines[0]}"

    tools_response = JSON.parse(lines[1])
    assert_equal 2, tools_response["id"]
    tools = tools_response.dig("result", "tools")
    refute_nil tools, "tools/list did not return a tools array: #{lines[1]}"
    assert tools.is_a?(Array) && !tools.empty?, "tools/list returned no tools"
  end
end

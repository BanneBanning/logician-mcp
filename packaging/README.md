# Cutting a release

Two distribution paths read the same tag, and BOTH are pinned to it: the
Homebrew formula (`packaging/homebrew/logician.rb`) fetches an exact tagged
tarball, and `packaging/install.sh` checks out an exact tag (`DEFAULT_REF`)
rather than whatever `main` holds. So every release updates three things: the
version string, the formula's `url`/`sha256`, and the script's `DEFAULT_REF`.
`PackagingSyncTests` fails the suite if the formula's version or the script's
`DEFAULT_REF` drifts from `serverVersion`, so a half-done bump cannot ship
quietly. There is no code signing anywhere in this pipeline - no Apple
Developer certificate exists for this project, so every install compiles from
source on the user's own machine, which is why the advertised floor is macOS
14.5 (Swift 6 needs Xcode 16, and Xcode 16 needs 14.5) even though a built
binary would run on macOS 13.

## Steps

Replace `X.Y.Z` throughout with the new version (no `v` prefix except where
shown). A pre-release suffix is allowed and is carried verbatim into the tag:
`1.0.0-beta.1` is tagged `v1.0.0-beta.1`.

### 1. Bump the version string, in all three places

Edit `Sources/Logician/Support.swift`:

```swift
let serverVersion = "X.Y.Z"
```

This also moves `cacheSchemaVersion` (it's defined from `serverVersion`),
which invalidates cached LCD/bank-map measurements on the next run - that is
intentional whenever a release could change what they mean.

Then the two files the version is *copied* into, both of which
`PackagingSyncTests` cross-checks against `serverVersion`:

```bash
# packaging/install.sh
DEFAULT_REF="vX.Y.Z"
# gemini-extension.json
"version": "X.Y.Z",
```

`install.sh` is served from `main`, so its `DEFAULT_REF` names a tag that must
already exist by the time anyone runs it - which is why the bump is committed
in the same commit the tag is cut from (step 3).

### 2. Build and test clean

```bash
swift build -c release -Xswiftc -warnings-as-errors
swift test
```

Both must be clean before tagging - a tag is a public, citable artifact;
fixing a red tag means a second tag, not a force-push.

### 3. Commit, tag, push

```bash
git add Sources/Logician/Support.swift CHANGELOG.md packaging/install.sh gemini-extension.json
git commit -m "Release X.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin main
git push origin vX.Y.Z
```

### 4. Compute the tarball checksum

GitHub builds the source tarball for a tag automatically at a predictable
URL - no upload step. Download the exact one the formula will fetch and hash
it:

```bash
curl -fsSL -o /tmp/logician-X.Y.Z.tar.gz \
  https://github.com/BanneBanning/logician-mcp/archive/refs/tags/vX.Y.Z.tar.gz
shasum -a 256 /tmp/logician-X.Y.Z.tar.gz
```

### 5. Update the formula

Until this step runs, the formula carries a 64-zero placeholder `sha256`.
That placeholder cannot ship by accident - Homebrew verifies the download
against it and aborts on the mismatch - and `PackagingSyncTests` skips with a
message pointing back here for as long as it stands.

In `packaging/homebrew/logician.rb`, set:

```ruby
url "https://github.com/BanneBanning/logician-mcp/archive/refs/tags/vX.Y.Z.tar.gz"
sha256 "<the hash from step 4>"
```

Sanity-check it before pushing:

```bash
brew style packaging/homebrew/logician.rb
```

(`brew audit` needs the formula to resolve by name inside a tap - see step 7
if you want the full `--strict` pass locally before pushing.)

### 6. Push the tap

The tap lives in its own repo, `BanneBanning/homebrew-logician` (created
once, see below - not this repo). Copy the updated formula across and push:

```bash
cp packaging/homebrew/logician.rb ../homebrew-logician/Formula/logician.rb
cd ../homebrew-logician
git add Formula/logician.rb
git commit -m "logician X.Y.Z"
git push
```

Anyone can now run `brew install bannebanning/logician/logician` (or
`brew upgrade` if they already have it) and get the new tag.

### 7. (Optional) Full local audit before pushing the tap

`brew audit --strict --formula <name>` needs the formula to resolve through
a tap directory, not a bare path. To dry-run that locally without touching
the real tap:

```bash
mkdir -p /opt/homebrew/Library/Taps/bannebanning/homebrew-logician/Formula
cp packaging/homebrew/logician.rb /opt/homebrew/Library/Taps/bannebanning/homebrew-logician/Formula/
brew audit --strict --formula bannebanning/logician/logician
rm -rf /opt/homebrew/Library/Taps/bannebanning
```

## Creating the tap repository (one-time, before the first release)

The tap repo does not exist yet. Create it once:

```bash
gh repo create BanneBanning/homebrew-logician --public \
  --description "Homebrew tap for Logician"
git clone git@github.com:BanneBanning/homebrew-logician.git
mkdir -p homebrew-logician/Formula
cp packaging/homebrew/logician.rb homebrew-logician/Formula/logician.rb
cd homebrew-logician && git add -A && git commit -m "Add logician formula" && git push
```

After that, step 6 above is all that is needed on every later release.

## What has to be true before any of this works publicly

- `BanneBanning/logician-mcp` must be **public** - GitHub does not serve
  archive tarballs for private repos to an unauthenticated `curl`/Homebrew.
- At least one tag must exist (`vX.Y.Z`, per step 3) - there are none yet.
- The tap repo `BanneBanning/homebrew-logician` must exist (see above) - it
  does not yet.

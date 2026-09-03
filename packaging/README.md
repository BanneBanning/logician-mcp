# Cutting a release

Two distribution paths read the same tag: the Homebrew formula
(`packaging/homebrew/logician.rb`) and `packaging/install.sh`. `install.sh`
always builds `main` fresh, so it needs nothing done to it per release. The
formula pins an exact tagged tarball, so every release means updating its
`url` and `sha256`. There is no code signing anywhere in this pipeline - no
Apple Developer certificate exists for this project, so every install
compiles from source on the user's own machine.

## Steps

Replace `X.Y.Z` throughout with the new version (no `v` prefix except where
shown).

### 1. Bump the version string

Edit `Sources/Logician/Support.swift`:

```swift
let serverVersion = "X.Y.Z"
```

This also moves `cacheSchemaVersion` (it's defined from `serverVersion`),
which invalidates cached LCD/bank-map measurements on the next run - that is
intentional whenever a release could change what they mean.

### 2. Build and test clean

```bash
swift build -c release -Xswiftc -warnings-as-errors
swift test
```

Both must be clean before tagging - a tag is a public, citable artifact;
fixing a red tag means a second tag, not a force-push.

### 3. Commit, tag, push

```bash
git add Sources/Logician/Support.swift CHANGELOG.md
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

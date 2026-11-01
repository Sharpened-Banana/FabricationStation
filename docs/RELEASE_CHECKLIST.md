# FabricationStation release checklist

The author follows this for every release. The implementer of the release tooling never pushes a tag. The first
tag, `v1.0.0`, is pushed by the author.

How the release works: pushing a tag `vX.Y.Z` (or `vX.Y.Z-beta.N` / `vX.Y.Z-alpha.N`; no other tag starts it) runs
`.github/workflows/release.yml`. It runs the CI jobs (`luacheck .`, `busted`), then `lua tools/check_release.lua`, then
the BigWigs packager, which uploads to GitHub, CurseForge, Wago and WoWInterface. A site whose token or project id is
missing is skipped. A tag containing `alpha` or `beta` is published as that release type, any other tag as a release.

Every `lua tools/...` command below needs Lua 5.1 or LuaJIT (the game's dialect), not Lua 5.4 or 5.5.

## One-time setup

- [ ] Create the CurseForge project, the Wago project and the WoWInterface addon.
- [ ] Set the repository **variables** `CF_PROJECT_ID`, `WAGO_PROJECT_ID` and `WOWI_ADDON_ID` (Settings > Secrets and
  variables > Actions > Variables).
- [ ] Set the repository **secrets** `CF_API_TOKEN`, `WAGO_API_TOKEN` and `WOWI_API_TOKEN` (same page, Secrets).
- [ ] Leave Settings > Actions > General > Workflow permissions at the read-only default: `release.yml` is read-only at
  the top level and grants `contents: write` to the release job only (it creates the GitHub release).
- [ ] On CurseForge, enable localization and import the phrases from `Locales/enUS.lua`.
- [ ] On CurseForge, set the relation to Auctionator as a **required dependency**. (The TOC lists it as optional; the
  packager's `required-dependencies` entry in `.pkgmeta` sets the store relation.)
- [ ] Confirm the licence setting on each site is MIT.

## Per release

- [ ] Bump `## Interface` in `FabricationStation.toc` from the current `live` build in Gethe/wow-ui-source (the
  `Interface` number of the `live` branch's `.toc` files).
- [ ] Run `luacheck .` and `busted`: both must be clean.
- [ ] Run `lua tools/check_locale.lua`.
- [ ] In `CHANGELOG.md`, move `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and keep a fresh empty `## [Unreleased]`
  above it.
- [ ] Run `lua tools/check_release.lua X.Y.Z` (the release workflow runs the same gate).
- [ ] Commit everything. The packager only packages tracked files, so the dry run below must run **after** the commit.
- [ ] Do the packager dry run (below).

### Packager dry run

No upload and no zip. The pin matches the workflow's `BigWigsMods/packager@v2` (latest tag v2.6.1). Run it from the
repository root:

```bash
S="${TMPDIR:-/tmp}/fs-release-dryrun"; rm -rf "$S"; mkdir -p "$S"
curl -sSfL -o "$S/release.sh" https://raw.githubusercontent.com/BigWigsMods/packager/v2.6.1/release.sh
bash "$S/release.sh" -t "$PWD" -d -z -e -l -r "$S/out"
```

`release.sh` needs bash 4.3 or newer. macOS ships bash 3.2 and the script stops at once with "bash version 4.3 or
above is required"; install a current bash (for example `brew install bash`) and run the script with it
(`"$(brew --prefix)/bin/bash" "$S/release.sh" ...`). Linux and the CI runner already have it.

`-d` skips the upload and the changelog commit, `-z` skips the zip, `-e` skips the svn externals (svn is not needed
locally) and `-l` skips localization (CurseForge only). Then check the package tree:

```bash
P="$S/out/FabricationStation"
for f in FabricationStation.toc LICENSE THIRD_PARTY_NOTICES.md Locales/Locales.xml; do test -e "$P/$f" || echo "MISSING $f"; done
for d in tests tools docs reports research_notes .github .gitignore .superpowers; do test ! -e "$P/$d" || echo "LEAKED $d"; done
test -f "$P/FabricationStation.toc" && test -f "$P/LICENSE" && test -f "$P/THIRD_PARTY_NOTICES.md" \
  && test -f "$P/Locales/Locales.xml" && test ! -e "$P/tests" && test ! -e "$P/tools" && test ! -e "$P/docs" \
  && test ! -e "$P/reports" && test ! -e "$P/.github" && test ! -e "$P/.gitignore" && echo PACKAGE_OK
```

- [ ] The dry run printed `PACKAGE_OK` and no `MISSING` or `LEAKED` line.
- [ ] CI-only check: `Libs/AceComm-3.0` and `Libs/AceLocale-3.0` are in the package. The local dry run uses `-e`, so the
  libraries (svn externals from `.pkgmeta`) are not fetched there. On the first tag, open the workflow's packager log
  (or the uploaded zip) and confirm both folders exist next to the other libraries. The packager installs subversion
  itself on the CI runner when `.pkgmeta` has `/trunk` externals.
- [ ] `Libs/` is git-ignored, so a local `bash tools/fetch-libs.sh` is for playing and testing only; it never reaches
  the package.

## In-game smoke tests

Install the packaged folder (or a symlink to the repo after `bash tools/fetch-libs.sh`) into
`World of Warcraft/_retail_/Interface/AddOns/FabricationStation` and test on the live client.

- [ ] Fresh SavedVariables (move `FabricationStation.lua` out of `WTF/Account/<account>/SavedVariables`): the setup
  wizard opens about five seconds after the first loading screen.
- [ ] Two accounts in one guild, both running the addon: guild crafters sync between them within 30 s.
- [ ] `/fs guild selftest` reports a wire size of at most 12 KB for a large profile.
- [ ] Turn sharing off on one account: the data it shared disappears on the peer.
- [ ] Enter a dungeon while a sync is running: the sync shows as paused, and resumes after leaving.
- [ ] Native fallback: for a guildmate without the addon, "Ask guild" on a recipe still answers through the game's own
  guild recipe query.
- [ ] Chat scan: a crafting request in Trade gives a toast. The toast's Whisper button only opens the chat edit box (it
  sends nothing). A repeat of the same request within 5 minutes gives no second toast. Inside an instance there are no
  errors.
- [ ] Item tooltips and the profession panel show the guild crafters line.
- [ ] BugSack (or `/console scriptErrors 1`) shows no errors after a full session of the above.

## Publish

- [ ] The author tags and pushes: `git tag -a vX.Y.Z -m "vX.Y.Z"` then `git push origin vX.Y.Z`.
- [ ] Watch the "Package and release" workflow until it is green.
- [ ] Verify the new file on CurseForge, on Wago and on WoWInterface (version, game version, changelog).
- [ ] Verify the GitHub release exists with its changelog and the packaged zip.
- [ ] Install the downloaded file once and check that `/fs` opens the window.

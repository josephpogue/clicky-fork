# Scripts

## `build-app.sh`

Builds the `leanring-buddy` scheme into `build/DerivedData` and prints the absolute path of `Clicky Fork.app` as its last line. It is the only way to build in this repo, and it never launches the app.

```bash
bash scripts/build-app.sh                          # Debug build
bash scripts/build-app.sh --configuration Release
bash scripts/build-app.sh --install                # also copy to /Applications/Clicky Fork.app
```

Signing team, in order:

1. `$CLICKY_DEVELOPMENT_TEAM`
2. the team (`OU`) of the first "Apple Development" identity in `security find-identity -v -p codesigning`
3. none: the app is signed ad hoc and a warning is printed (macOS permissions need re-granting after each rebuild)

`--install` asks a running copy to quit (`osascript`, bundle id `com.clickyfork.app`), waits for it to exit, then replaces the installed copy.

A failed build exits non-zero and shows the first `error:` lines.

# GitHub-Actions auf Commit-SHA gepinnt, Updates über Dependabot

Das Repo ist öffentlich. Fremde Actions werden deshalb über ihren Commit-SHA statt über ein veränderliches Tag eingebunden (Supply-Chain-Härtung), die Version steht als Kommentar daneben. Versionsupdates kommen über Dependabot (`github-actions`-Ecosystem), nicht über manuelles Nachziehen der Pins.

`directory: "/"` in `.github/dependabot.yml` deckt sowohl `ci.yml` als auch die lokale Composite-Action `.github/actions/swift-toolchain/action.yml` ab: für dieses Ecosystem ist das Verzeichnis die Repo-Wurzel, Dependabot durchsucht darunter Workflows und lokale Composite-Actions.

Betrifft: `.github/workflows/ci.yml` (`uses:`-Zeilen), `.github/actions/swift-toolchain/action.yml`, `.github/dependabot.yml`

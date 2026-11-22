<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/Icon-256.png" width="96" height="96" alt="AGY Switcher icon">
</p>
<h1 align="center">AGY Switcher</h1>
<p align="center">Switch Google accounts for Antigravity and agy from the macOS menu bar, check quotas, and track local usage.</p>
<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>
<p align="center">
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#screenshots">Screenshots</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

## Installation

AGY Switcher requires **macOS 26 or later**. Download `AGY-Switcher-v*-macOS-universal.dmg` for Apple Silicon and Intel Macs when a release is available. [GitHub Releases](https://github.com/tyuan511/agy-switcher/releases)

Open the DMG and drag **AGY Switcher** into Applications. You can also [build from source](#build-from-source).

### In-app updates

Release builds check GitHub Releases after launch and every 24 hours while running. When a newer stable version is available, the menu bar shows an update option. Open **Settings → Software update** to check manually and read release notes in English or Simplified Chinese. **Download and Restart** verifies the DMG's signature and notarization, then checks the enclosed app's signature, bundle ID, and version before replacing the current app and restarting. Install the app in an Applications folder you can write to.

For a private repository, create a fine-grained GitHub personal access token scoped to `tyuan511/agy-switcher` with **Read-only** access to **Contents**. Save it under **Private repository access** in Settings. The app stores the token in the local macOS Keychain. Public repositories support direct update checks and downloads. [Create a GitHub token](https://github.com/settings/personal-access-tokens/new)

## Quick start

1. Open AGY Switcher and click **+** in the upper-right corner of **Accounts**. Use your default browser to authorize a personal Google account with Antigravity access. Repeat for each account you want to add.
2. Open **Accounts** or the menu bar panel to see the active account, each model group's remaining quota, and when it resets. You can refresh manually or have the app refresh stale quotas when you open either view.
3. Click **Switch** next to the account you want to use. If Antigravity is running, AGY Switcher attempts to restart it. Restart `agy` in your terminal to start a session with the new account.
4. Open **Usage** to see input and output token counts, daily trends, and estimated costs in USD for the last 7 or 30 days. Choose **Enable Account Attribution** from the link menu in the upper-right corner to group newly started interactive `agy` sessions by sign-in email. Usage that can't be matched to an account appears under **Unattributed**.

In **Settings**, you can switch between Simplified Chinese and English, change the appearance and quota refresh interval, start the app at login, or hide the Dock icon.

## Screenshots

The screenshots show the Simplified Chinese interface with fictional email addresses, plans, quotas, and usage.

### Accounts

![Accounts window showing two sample accounts, the active account, remaining model quotas, and reset countdowns](docs/screenshots/accounts.png)

### Menu bar

<img src="docs/screenshots/menu-bar.png" width="370" alt="Menu bar panel showing the active and alternate accounts, quotas, and the Switch button">

### Usage

![agy usage view showing seven days of token usage, estimated costs in USD, and a breakdown by account](docs/screenshots/usage.png)

## Account and usage data

- Google authorization takes place in your browser. AGY Switcher stores tokens for added accounts in the macOS Keychain. Switching accounts updates the shared Keychain entry and local fallback credentials used by Antigravity and `agy`. macOS may ask for permission to access the shared entry.
- **Usage** reads the local `agy` SQLite session records. Account attribution records the session ID and sign-in email through the `agy` status line. You can disable it at any time.
- Cost estimates use Google Cloud's global Standard Model rates. Check your bill for actual charges. [Google Cloud model pricing](https://cloud.google.com/model-garden/pricing)

> [!NOTE]
> The app is designed for personal accounts that use the default Google sign-in. Quota reporting and account switching depend on the clients' interfaces and credential formats. The initial compatibility targets were Antigravity 2.34.0 and agy 1.5.12.

## Build from source

Use Xcode 26 or later. Run the unit tests and build the Debug app from the repository root.

```sh
swift test
xcodebuild -project AGYSwitcher.xcodeproj -scheme AGYSwitcher -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

The build produces `DerivedData/Build/Products/Debug/AGY Switcher.app`. The command uses ad hoc signing and works without a Developer ID certificate.

<details>
<summary>Manual checks</summary>

1. Add two Google accounts with Antigravity access. Check the model groups, remaining quotas, and reset countdowns for both accounts.
2. With Antigravity running, switch accounts from the menu bar. Confirm that Antigravity restarts, then check the account in the desktop app and in a fresh `agy` process. Use `/usage` in `agy` to compare quotas.
3. Close the main window, reopen **Accounts** from the menu bar, and confirm that the active account and quotas still match.

</details>

<details>
<summary>Releasing a version</summary>

Use the `$release` skill in a Codex chat for this repository to preview both sets of release notes. Once approved, run `$release 发布` to select a version automatically or `$release 发布 0.2.0` to specify one.

The release process commits the English and Simplified Chinese notes to `docs/release/`. Pushing a `vX.Y.Z` tag triggers GitHub Actions to build the universal DMG, sign it with Developer ID, submit it to Apple for notarization, and publish it to GitHub Releases. The release page shows the English notes with a link to the Simplified Chinese version. [Release workflow](.github/workflows/release.yml)

Before the first release, add these repository secrets under **Settings → Secrets and variables → Actions** on GitHub.

| Secret | Value |
| --- | --- |
| `APPLE_CERT_P12` | Base64-encoded Developer ID Application `.p12` containing the certificate and private key |
| `APPLE_CERT_PASSWORD` | Password set when exporting the `.p12` |
| `APPLE_API_KEY_P8` | Contents of the App Store Connect team API key `.p8` file used for notarization |
| `APPLE_API_KEY_ID` | App Store Connect API Key ID |
| `APPLE_API_ISSUER` | App Store Connect Issuer ID |

</details>

The account and quota interface draws on [Cockpit Tools](https://github.com/jlcodes99/cockpit-tools).

# Publishing LiteBrowser on GitHub

When this is set up, every new version is one command. GitHub then builds the **Android APK** and the **Mac app**, publishes a **GitHub Release**, and updates the **Homebrew formula** so Mac users get it with `brew upgrade`.

```
you ── ./scripts/publish.sh 1.0.1 ──► GitHub Actions ──┬─► LiteBrowser-1.0.1.apk         (Android)
                                                       ├─► LiteBrowser-1.0.1-macOS.zip   (Mac, direct download)
                                                       ├─► GitHub Release page
                                                       └─► <you>/homebrew-tap formula    (brew install)
```

---

## Option A: the automatic way (recommended)

From the `lite-browser` folder on your Mac:

```bash
./scripts/publish.sh          # first release: v1.0.0
```

The script:

1. Installs the GitHub CLI (`gh`) if needed and signs you in through your browser.
2. Creates **github.com/YOU/lite-browser** and pushes the code.
3. Creates **github.com/YOU/homebrew-tap**, which is where `brew` looks for the formula.
4. Asks you **once** for a token so GitHub can update the tap. It opens the token page for you:
   - Repository access: **Only select repositories → homebrew-tap**
   - Permissions → Repository permissions → **Contents: Read and write**
5. Creates an **Android signing key** in `~/.litebrowser/` and stores it as GitHub secrets. It offers to install Java for this if you don't have it.
   **Back up `~/.litebrowser/`.** Every future APK must be signed with the same key, or Android refuses to install the update.
6. Tags `v1.0.0` and pushes the tag, which starts the build.

Watch the build with `gh run watch` or on the **Actions** tab of your repository. It takes about 5–10 minutes.

**Later releases:**

```bash
./scripts/publish.sh 1.0.1
```

---

## Option B: the manual way (step by step)

### 1. Create the repositories

1. Go to https://github.com/new and create a **public** repository named `lite-browser`. Leave it empty: no README, no license.
2. Create a second public repository named exactly **`homebrew-tap`**. Tick "Add a README file".

### 2. Push the code

```bash
cd lite-browser
git init -b main
git add -A
git commit -m "LiteBrowser 1.0.0"
git remote add origin https://github.com/YOU/lite-browser.git
git push -u origin main
```

### 3. Add the secrets

In **lite-browser → Settings → Secrets and variables → Actions → New repository secret**:

| Secret | What it is | How to get it |
|---|---|---|
| `TAP_GITHUB_TOKEN` | Lets the build update your Homebrew tap | https://github.com/settings/personal-access-tokens/new: access to **homebrew-tap** only, **Contents: Read and write** |
| `ANDROID_KEYSTORE_BASE64` | Your APK signing key | See below |
| `ANDROID_KEYSTORE_PASSWORD` | The key's password | The one you chose |
| `ANDROID_KEY_PASSWORD` | Same password | The one you chose |
| `ANDROID_KEY_ALIAS` | `litebrowser` | — |

Create the signing key (needs Java: `brew install openjdk`):

```bash
mkdir -p ~/.litebrowser
"$(brew --prefix openjdk)/bin/keytool" -genkeypair -keystore ~/.litebrowser/release.jks \
  -alias litebrowser -keyalg RSA -keysize 2048 -validity 10000
base64 -i ~/.litebrowser/release.jks | pbcopy     # now paste it as ANDROID_KEYSTORE_BASE64
```

You can skip the Android secrets. The APK will still build, but it's signed with a temporary key, so people have to uninstall the old version before installing an update.

### 4. Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

Open the **Actions** tab to watch it. When it's green, the **Releases** page has the APK and the Mac zip, and your `homebrew-tap` has `Formula/lite-browser.rb`.

---

## How people install it

**Mac** (needs Homebrew from https://brew.sh):

```bash
brew install YOU/tap/lite-browser
litebrowser                              # or open it from Launchpad / Applications
```

Updates: `brew upgrade lite-browser`.

Homebrew builds the app on the user's Mac from your source code. That means Gatekeeper doesn't block it and there's no "unidentified developer" warning. The first install also installs Apple's Command Line Tools if they're missing.

**Android:**

1. On the phone, open `https://github.com/YOU/lite-browser/releases/latest`.
2. Tap `LiteBrowser-x.y.z.apk` to download it, then open it.
3. If Android asks, allow your browser to **Install unknown apps**, then tap **Install**.
4. Optional: to make it the default browser, go to Settings → Apps → Default apps → Browser app → LiteBrowser.

**Mac without Homebrew:** download `LiteBrowser-x.y.z-macOS.zip` from the release. The app isn't signed with an Apple Developer ID, so the first time, right-click it and choose **Open**. If macOS still refuses, run `xattr -dr com.apple.quarantine /Applications/LiteBrowser.app`.

---

## Good to know

- **Test a build without releasing:** Actions → *Build & Release* → **Run workflow**. The APK and Mac zip appear as downloadable artifacts on the run page.
- **Version numbers:** the tag sets them (`v1.2.0` becomes 1.2.0 in both apps). Android's internal build number increases automatically.
- **Google Play:** this setup publishes the APK on GitHub. Google Play needs a developer account ($25 once) and an `.aab` bundle. Run `gradle -p android bundleRelease` and upload the bundle in the Play Console.
- **Proper Mac signing (optional):** with an Apple Developer account ($99 a year) you can sign and notarize the zip download. Homebrew users don't need this.
- **Something failed?** Open the red run in the Actions tab and expand the failed step. The most common causes are a missing secret or a token without **Contents: Read and write** on `homebrew-tap`.

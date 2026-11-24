#!/bin/bash
# Publishes LiteBrowser to GitHub in one go:
#   1. creates github.com/<you>/lite-browser and pushes the code
#   2. creates github.com/<you>/homebrew-tap (so Mac users can `brew install <you>/tap/lite-browser`)
#   3. saves the secrets GitHub needs (Homebrew token, Android signing key)
#   4. tags a version, which starts the automatic build of the APK + Mac app + release
#
# Usage:  ./scripts/publish.sh            (first release, v1.0.0)
#         ./scripts/publish.sh 1.0.1      (later releases)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
bold() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# --- 0. Tools ---------------------------------------------------------------------------------
command -v git >/dev/null || { echo "git is missing. Run: xcode-select --install"; exit 1; }
if ! command -v gh >/dev/null; then
  echo "Installing the GitHub command-line tool…"
  brew install gh
fi
if ! gh auth status >/dev/null 2>&1; then
  bold "Sign in to GitHub (a browser window will open)"
  gh auth login --hostname github.com --git-protocol https --web
fi
OWNER=$(gh api user -q .login)
REPO="$OWNER/lite-browser"
TAP="$OWNER/homebrew-tap"
bold "Publishing LiteBrowser $VERSION as github.com/$REPO"

# --- 1. Code repository -----------------------------------------------------------------------
# Put your GitHub name into the install instructions
sed -i '' "s#YOU/tap/lite-browser#$OWNER/tap/lite-browser#g; s#YOUR_GITHUB_USER/lite-browser#$REPO#g" README.md Formula/lite-browser.rb Info.plist 2>/dev/null || true
[ -d .git ] || git init -b main >/dev/null
git add -A
git -c user.name="${GIT_AUTHOR_NAME:-$OWNER}" -c user.email="${GIT_AUTHOR_EMAIL:-$OWNER@users.noreply.github.com}" \
  commit -q -m "LiteBrowser $VERSION" || true
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO" --public --description "Lightweight browser with Google search and smart DNS error fixes — macOS (brew) and Android (APK)"
fi
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
gh auth setup-git >/dev/null 2>&1 || true
git push -u origin main

# --- 2. Homebrew tap repository ---------------------------------------------------------------
if ! gh repo view "$TAP" >/dev/null 2>&1; then
  gh repo create "$TAP" --public --add-readme --description "Homebrew formulae by $OWNER"
fi

# --- 3a. Token that lets the release workflow update the tap ------------------------------------
if ! gh secret list -R "$REPO" 2>/dev/null | grep -q '^TAP_GITHUB_TOKEN'; then
  bold "One-time step: create a token for Homebrew updates"
  cat <<EOT
  1. Open: https://github.com/settings/personal-access-tokens/new
  2. Token name: litebrowser-tap    Expiration: 1 year (or longer)
  3. Repository access: "Only select repositories" → $TAP
  4. Permissions → Repository permissions → Contents → "Read and write"
  5. Click "Generate token" and copy it.
EOT
  open "https://github.com/settings/personal-access-tokens/new" 2>/dev/null || true
  read -rsp "Paste the token here and press Enter: " TOKEN; echo
  printf %s "$TOKEN" | gh secret set TAP_GITHUB_TOKEN -R "$REPO"
  echo "Saved."
fi

# --- 3b. Android signing key (keeps the same key so APK updates install over older versions) ----
KEYDIR="$HOME/.litebrowser"
KS="$KEYDIR/release.jks"
PASSFILE="$KEYDIR/keystore-password.txt"
find_keytool() {
  local jdk; jdk="$(brew --prefix openjdk 2>/dev/null || true)"
  if [ -n "$jdk" ] && [ -x "$jdk/bin/keytool" ]; then echo "$jdk/bin/keytool"; return; fi
  if /usr/libexec/java_home >/dev/null 2>&1; then echo keytool; fi
}
if [ ! -f "$KS" ]; then
  KEYTOOL="$(find_keytool)"
  if [ -z "$KEYTOOL" ]; then
    echo
    echo "An Android signing key keeps every APK update installable over the previous one."
    read -rp "Install Java (brew install openjdk, ~300 MB) to create one? [Y/n] " yn
    if [[ ! "$yn" =~ ^[Nn] ]]; then brew install openjdk; KEYTOOL="$(find_keytool)"; fi
  fi
  if [ -n "$KEYTOOL" ]; then
    bold "Creating your Android signing key"
    mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR"
    PASS=$(openssl rand -hex 16)
    "$KEYTOOL" -genkeypair -keystore "$KS" -alias litebrowser -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$PASS" -keypass "$PASS" -dname "CN=LiteBrowser, O=$OWNER" >/dev/null
    printf %s "$PASS" > "$PASSFILE" && chmod 600 "$PASSFILE" "$KS"
    echo "Key saved in $KEYDIR. BACK IT UP (e.g. in a password manager): without it you can't publish updates."
  else
    echo "Skipping the signing key. The APK will be signed with a temporary key (updates must be uninstalled first)."
  fi
fi
if [ -f "$KS" ] && ! gh secret list -R "$REPO" 2>/dev/null | grep -q '^ANDROID_KEYSTORE_BASE64'; then
  base64 -i "$KS" | gh secret set ANDROID_KEYSTORE_BASE64 -R "$REPO"
  gh secret set ANDROID_KEYSTORE_PASSWORD -R "$REPO" < "$PASSFILE"
  gh secret set ANDROID_KEY_PASSWORD -R "$REPO" < "$PASSFILE"
  printf litebrowser | gh secret set ANDROID_KEY_ALIAS -R "$REPO"
  echo "Android signing key saved to GitHub."
fi

# --- 4. Tag the release (this starts the build) -----------------------------------------------
TAG="v$VERSION"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists. Use a new version number, e.g. ./scripts/publish.sh 1.0.1"
  exit 1
fi
git tag -a "$TAG" -m "LiteBrowser $VERSION"
git push origin "$TAG"

bold "Done! GitHub is now building the APK and the Mac app (about 5–10 minutes)."
echo "Watch it:     gh run watch -R $REPO      (or https://github.com/$REPO/actions)"
echo "Release page: https://github.com/$REPO/releases/tag/$TAG"
echo
echo "Then people install it with:"
echo "  Mac:      brew install $OWNER/tap/lite-browser"
echo "  Android:  download LiteBrowser-$VERSION.apk from the release page"

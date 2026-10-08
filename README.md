# LiveCloud

A small iPhone app that uploads Live Photos to pCloud and saves them back to Photos **as Live Photos**.

Each Live Photo is stored in the pCloud folder `/LiveCloud` as two files with the same name, e.g.
`20261008_141500_IMG_1234.HEIC` + `20261008_141500_IMG_1234.MOV`. Keep both files and don't rename or edit them — that's what lets the app rebuild the Live Photo.

No Mac needed: GitHub builds the app, and you install it from Windows.

## 1. Put the code on GitHub

1. Create a new repository on github.com (a **public** repo gets free macOS build minutes; private repos have a limited monthly allowance).
2. Upload the contents of this folder (`project.yml`, `README.md`, `.gitignore`, `.github/`, `LiveCloud/`) to the root of the repo, on the `main` branch.
   - If the `.github` folder doesn't come along (some uploads skip dot-folders), use **Add file › Create new file**, name it `.github/workflows/build.yml`, and paste in that file's contents.

## 2. Build

Pushing to `main` starts the build automatically. You can also start it by hand: **Actions › Build IPA › Run workflow**.

When it finishes (a few minutes), open the run and download the **LiveCloud-ipa** artifact. Unzip it to get `LiveCloud.ipa`.

If the build fails, open the failed step, copy the error text, and paste it into your chat with Claude.

## 3. Install on your iPhone (from Windows)

1. Install **Sideloadly** (sideloadly.io) plus iTunes and iCloud from Apple's website (not the Microsoft Store versions).
2. Connect the iPhone by USB, open Sideloadly, drop in `LiveCloud.ipa`, enter your Apple ID, and click Start.
3. On the iPhone:
   - **Settings › Privacy & Security › Developer Mode** → on (the phone restarts).
   - **Settings › General › VPN & Device Management** → trust your Apple ID.

With a free Apple ID the app expires after **7 days**. Repeat step 3.2 to refresh it; your login and pCloud files are unaffected.

## 4. Use it

- **Log in** with your pCloud email and password, and pick the data region your account uses (shown in pCloud's web settings). The app keeps your login in the iPhone's encrypted Keychain and never sends the password itself over the network.
- **Upload** tab: choose Live Photos and tap Upload.
- **pCloud** tab: pull to refresh, tap **Save** on an item to put it back into Photos as a Live Photo.
- **Log** tab: shows what happened, including errors. Use **Copy** to share it when something goes wrong.

When asked, allow **full** Photos access; with limited access only the photos you allowed can be uploaded.

## Known limitations

- Accounts with **two-factor authentication** can't log in with this simple email/password flow yet.
- Live Photos are uploaded in their **original** form; edits made in the Photos app are not included.
- Uploading the same photo twice overwrites the earlier copy.

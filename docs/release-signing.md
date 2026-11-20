# Release signing

The Release workflow tests the tagged commit before the signing job starts.
The signing job uses the GitHub Actions `release` environment.

## Set up the release environment

In the swift-ember repository, open **Settings > Environments** and create
`release`. Under **Deployment branches and tags**, choose **Selected branches
and tags**. Add a tag rule for `*.*.*` and a branch rule for the default
branch. The workflow checks that the tag is in `major.minor.patch` form and
points to a commit on the default branch. The branch rule lets you run the
workflow manually from the default branch and supply an existing tag. If you
configure **Required reviewers**, approve the signing job in **Actions >
Review deployments** after the tests pass.

Under **Environment secrets**, add these five values. You can use the same
values as device-relay if you release both projects under the same Apple
Developer account.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded `.p12` containing one valid Developer ID Application certificate and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password used to export the `.p12` |
| `NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect Team API key (`.p8`) with the Developer role |
| `NOTARY_KEY_ID` | The API key's Key ID |
| `NOTARY_ISSUER_ID` | The Team API key's Issuer ID in App Store Connect |

Export the certificate and private key as a password-protected `.p12` from
Keychain Access. Create a Team API key under **Users and Access >
Integrations** in App Store Connect if you need a key. From the swift-ember
checkout, you can set the secrets with the GitHub CLI.

```sh
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release
gh secret set DEVELOPER_ID_P12_PASSWORD --env release
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64 --env release
gh secret set NOTARY_KEY_ID --env release
gh secret set NOTARY_ISSUER_ID --env release
```

Use the same commands to update the secrets when you rotate the certificate
or API key. The workflow finds the Developer ID Application identity by its
certificate hash at run time. Keep the signing identity name and Team ID
out of repository files and logs.

## Build and verify the release

Push the release tag or run **Actions > Release > Run workflow** from the
default branch and enter the existing tag. After the tests pass, the signing
job checks all five secrets, then imports the certificate into a temporary
runner keychain and writes the API key to a temporary file.

The packaging script signs one executable with hardened runtime and a secure
timestamp. It checks the signature, submits the executable to Apple as a ZIP,
and requires both an `Accepted` response and a successful online ticket check.
The executable stays byte-for-byte identical in `swift-ember.zip` and
`swift-ember.artifactbundle.zip`. Standalone executables cannot carry a stapled
ticket, so Gatekeeper checks the ticket online on first launch after a
browser download.

The signing job removes the temporary keychain and key files even if signing
or notarization fails. If Apple returns a submission ID, you can look up the
details with an authorized API key.

```sh
xcrun notarytool log "$submission_id" \
  --key /path/to/AuthKey_XXXXXXXXXX.p8 --key-id "$key_id" --issuer "$issuer_id"
```

After correcting a missing secret or a failed submission, rerun the workflow
for the same tag. On success the workflow creates or updates a draft GitHub
Release. Complete the [physical iPhone release checklist](release-checklist.md)
before publishing it.

For a local packaging check, run `scripts/package-release.sh 0.5.0`.
This uses ad-hoc signing when `EMBER_CODESIGN_IDENTITY` is unset and requires
no release secrets. Set `EMBER_CODESIGN_IDENTITY` for Developer ID signing
and optionally `EMBER_CODESIGN_KEYCHAIN` to select its keychain.

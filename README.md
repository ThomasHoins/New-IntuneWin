# New-IntuneWin

A single PowerShell script that **creates, verifies and unpacks `.intunewin` packages** for Microsoft Intune Win32 apps, without `IntuneWinAppUtil.exe`.

> **Unofficial.** This project is not affiliated with or endorsed by Microsoft. The `.intunewin` container is not publicly specified by Microsoft. The format implemented here was reconstructed from public documentation and from analysing packages created by the official tool. See [Limitations](#limitations-and-compatibility).

## Why

The official Microsoft Win32 Content Prep Tool is the supported way to create `.intunewin` files. In some environments, though, the EXE cannot be run (endpoint protection, application control, build agents without exe permissions). This script produces the same package structure using only Windows PowerShell and .NET, and it also lets you inspect and unpack existing packages.

If the official tool works for you, use the official tool.

## Features

- **Pack** a folder into a `.intunewin` file (ZIP, AES-256-CBC, HMAC-SHA256, SHA-256 digest, `Detection.xml`)
- **Unpack** an existing `.intunewin` back into the original files, with MAC verification and path-traversal protection
- **Test** a package: container layout, ZIP methods, MAC, decryption, file digest and size
- No admin rights, no external modules, no compiled code

## Requirements

- Windows PowerShell 5.1 (developed and tested on this version; PowerShell 7 has not been tested)
- No network access needed

## Usage

```powershell
# Pack (default mode)
.\New-IntuneWin.ps1 -SourceFolder C:\src\App -SetupFile Install.bat -OutputFolder C:\out

# Unpack
.\New-IntuneWin.ps1 -Unpack -Path C:\out\Install.intunewin -Destination C:\unpacked\App

# Test, optionally listing the files of the inner archive
.\New-IntuneWin.ps1 -Test -Path C:\out\Install.intunewin -ListContent
```

Paths with spaces need plain straight quotes and must not end with a backslash before the closing quote (`'C:\My App'`, not `"C:\My App\"`). The script also strips stray quotation marks from its path parameters.

### Parameters

| Mode | Parameter | Description |
|---|---|---|
| Pack | `-SourceFolder` | Folder containing the installer and all supporting files (required) |
| Pack | `-SetupFile` | Setup file, relative to `-SourceFolder` (required) |
| Pack | `-OutputFolder` | Target folder, created if missing (required) |
| Pack | `-OutputName` | Name of the resulting file. Default: name of the setup file |
| Pack | `-PlainZip` | Use an existing plaintext ZIP instead of zipping `-SourceFolder` |
| Pack | `-ToolVersion` | Value of the `ToolVersion` attribute in `Detection.xml` (default `1.8.7.0`) |
| Pack | `-Force` | Overwrite an existing target file |
| Unpack | `-Unpack` | Switch that selects the unpack mode |
| Unpack | `-Path` | The `.intunewin` file (required) |
| Unpack | `-Destination` | New or empty folder (required) |
| Unpack | `-KeepPlainZip` | Also keep the decrypted inner ZIP as `<file>.plain.zip` |
| Test | `-Test` | Switch that selects the test mode |
| Test | `-Path` | The `.intunewin` file (required) |
| Test | `-ListContent` | List the entries of the inner ZIP |

A successful test looks like this:

```
ContainerGespeichert : True
MacOk                : True
DecryptOk            : True
DigestOk             : True
SizeOk               : True
ProfileIdentifier    : ProfileVersion1
```

All of `ContainerGespeichert`, `MacOk`, `DecryptOk`, `DigestOk` and `SizeOk` should be `True`. (`ContainerGespeichert` means that the entries of the outer container are stored with ZIP method 0, see [Format notes](#format-notes).)

## What this script does not do

- **It does not upload anything.** Upload the resulting file in the Intune admin center, or through the Microsoft Graph API.
- **It does not set app metadata.** Publisher, description, install and uninstall commands, detection rules and requirements are not part of a `.intunewin` file. The official tool does not write them either. Set them in the portal or via Graph (`win32LobApp`).
- **It does not generate `MsiInfo`.** For MSI packages the official tool reads product code, version and publisher from the MSI database and stores them in the `MsiInfo` block of `Detection.xml`. This script does not, so Intune cannot prefill those values.

## Format notes

A `.intunewin` file is a ZIP container:

```
App.intunewin                              (outer ZIP, entries stored with method 0)
└── IntuneWinPackage/
    ├── Contents/
    │   └── IntunePackage.intunewin        (encrypted payload)
    └── Metadata/
        └── Detection.xml
```

**Encrypted payload** (`IntunePackage.intunewin`):

| Offset | Length | Content |
|---|---|---|
| 0 | 32 | HMAC-SHA256 over bytes 32 to the end (IV + ciphertext) |
| 32 | 16 | AES initialization vector |
| 48 | n | AES-256-CBC ciphertext, PKCS7 padding |

The plaintext is a ZIP archive of the source folder. Encrypted size is `48 + (floor(size / 16) + 1) * 16` bytes.

**`Detection.xml`** (fields written by this script):

```xml
<ApplicationInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ToolVersion="1.8.7.0">
  <Name>Install.bat</Name>
  <UnencryptedContentSize>12609285</UnencryptedContentSize>
  <FileName>IntunePackage.intunewin</FileName>
  <SetupFile>Install.bat</SetupFile>
  <EncryptionInfo>
    <EncryptionKey>base64, 32 bytes</EncryptionKey>
    <MacKey>base64, 32 bytes</MacKey>
    <InitializationVector>base64, 16 bytes</InitializationVector>
    <Mac>base64, 32 bytes</Mac>
    <ProfileIdentifier>ProfileVersion1</ProfileIdentifier>
    <FileDigest>base64, 32 bytes</FileDigest>
    <FileDigestAlgorithm>SHA256</FileDigestAlgorithm>
  </EncryptionInfo>
</ApplicationInfo>
```

| Field | Meaning |
|---|---|
| `UnencryptedContentSize` | Size in bytes of the plaintext ZIP |
| `EncryptionKey`, `MacKey`, `InitializationVector` | Random values generated per package |
| `Mac` | HMAC-SHA256 stored in the first 32 bytes of the payload |
| `FileDigest` | SHA-256 of the **plaintext** ZIP (not of the encrypted file) |
| `ProfileIdentifier` | `ProfileVersion1` is the only profile observed |

Two details matter for the Intune portal:

1. **The outer ZIP entries must use ZIP method 0 (stored).** The portal appears to read the inner payload directly from the container. In Windows PowerShell 5.1 (.NET Framework), `CompressionLevel.NoCompression` still writes Deflate blocks, so the script writes the outer container itself. A package built with .NET's `NoCompression` uploaded to Intune failed with *"Your app is not ready yet"*.
2. **`Detection.xml` is written byte-for-byte like the official tool's output**: CRLF line endings, two-space indentation, no BOM, no XML declaration and no trailing newline. Whether each of these details is strictly required is not known; matching them removed the differences to the official file.

## Security notes

- The encryption protects against corruption and tampering in transit, **not against reading**. The keys are stored in `Detection.xml` inside the same file, so anyone holding a `.intunewin` can unpack it. Do not put secrets, passwords or certificates in a package in plain form.
- Unpacking verifies the MAC before decrypting and aborts on a mismatch. ZIP entries whose paths would leave the destination folder are rejected.
- Only unpack packages from sources you trust. The unpacked files are installers and scripts and may trigger endpoint protection.
- Check your organisation's policy before using an alternative to the official tool.

## Limitations and compatibility

- Verified by comparison with one package created by `IntuneWinAppUtil.exe` 1.8.7.0 (layout, MAC, digest, size, ZIP structure). A package created by this script was successfully uploaded through the Intune admin center for a script-based Win32 app (`Install.bat`). MSI packages and large packages have not been tested.
- Not supported: `MsiInfo` generation, ZIP64 (files of 4 GB and more are rejected with an error), PowerShell 7.
- The inner plaintext ZIP is not byte-identical to the one the official tool creates (compression settings differ). Unpack both packages and compare the file lists if you want to be sure.
- Microsoft may change the format, for example with a new `ProfileIdentifier` or stricter validation. A reimplementation will not follow such changes automatically. Compare against a fresh package from the official tool whenever Intune behaviour changes, using `-Test` on both files.

## Contributing

Issues and pull requests are welcome, especially:

- test results with MSI packages, large packages and PowerShell 7
- differences you find between this script's output and the official tool's output (please include the output of `-Test` for both files, with the `Detection.xml` keys removed)

## License

Add the license of your choice here and include a `LICENSE` file.

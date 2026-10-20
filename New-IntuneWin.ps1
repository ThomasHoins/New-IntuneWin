<#
.SYNOPSIS
    Erzeugt, prüft und entpackt .intunewin-Dateien ohne IntuneWinAppUtil.exe.

.DESCRIPTION
    Drei Modi, gewählt über die Parameter:
      Pack   (Standard)  Quellordner -> .intunewin
      -Unpack            .intunewin  -> Ordner mit den Originaldateien
      -Test              .intunewin prüfen (Container, MAC, Entschlüsselung, Digest, Größe)

.EXAMPLE
    .\New-IntuneWin.ps1 -SourceFolder C:\src\App -SetupFile Install.bat -OutputFolder C:\out
.EXAMPLE
    .\New-IntuneWin.ps1 -Unpack -Path C:\out\App.intunewin -Destination C:\Entpackt\App
.EXAMPLE
    .\New-IntuneWin.ps1 -Test -Path C:\out\App.intunewin -ListContent
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Pack')]
param(
    # --- Pack ---
    [Parameter(ParameterSetName = 'Pack', Mandatory)][string]$SourceFolder,
    [Parameter(ParameterSetName = 'Pack', Mandatory)][string]$SetupFile,       # relativ zum SourceFolder
    [Parameter(ParameterSetName = 'Pack', Mandatory)][string]$OutputFolder,
    [Parameter(ParameterSetName = 'Pack')][string]$OutputName,                  # Standard: Name der Setup-Datei
    [Parameter(ParameterSetName = 'Pack')][string]$PlainZip,                    # fertiges Klartext-ZIP statt SourceFolder verwenden
    [Parameter(ParameterSetName = 'Pack')][string]$ToolVersion = '1.8.7.0',
    [Parameter(ParameterSetName = 'Pack')][switch]$Force,                       # vorhandene Zieldatei überschreiben

    # --- Unpack ---
    [Parameter(ParameterSetName = 'Unpack', Mandatory)][switch]$Unpack,
    [Parameter(ParameterSetName = 'Unpack', Mandatory)][string]$Destination,    # neuer oder leerer Ordner
    [Parameter(ParameterSetName = 'Unpack')][switch]$KeepPlainZip,              # Klartext-ZIP als <Datei>.plain.zip ablegen

    # --- Test ---
    [Parameter(ParameterSetName = 'Test', Mandatory)][switch]$Test,
    [Parameter(ParameterSetName = 'Test')][switch]$ListContent,                 # Dateiliste des inneren ZIPs anzeigen

    # --- Unpack und Test ---
    [Parameter(ParameterSetName = 'Unpack', Mandatory)]
    [Parameter(ParameterSetName = 'Test', Mandatory)][string]$Path              # .intunewin-Datei
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:quotes = [char[]]@('"', "'", [char]0x201E, [char]0x201C, [char]0x201D, [char]0x2018, [char]0x2019)
$script:NameEnc = 'IntuneWinPackage/Contents/IntunePackage.intunewin'
$script:NameXml = 'IntuneWinPackage/Metadata/Detection.xml'

# ============================ Hilfsfunktionen ============================

function Get-CleanPath {
    # Entfernt Leerzeichen, (typografische) Anführungszeichen und einen abschließenden Backslash
    param([string]$Value)
    $v = $Value.Trim().Trim($script:quotes)
    if ($v.Length -gt 3) { $v = $v.TrimEnd('\') }
    $v
}

function New-WorkDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}

function Get-ZipInfo {
    # Liest das Central Directory eines ZIPs (ohne ZIP64) und liefert pro Eintrag Methode, CRC und Größen
    param([string]$ZipPath)
    $fs = [IO.File]::OpenRead($ZipPath)
    $br = New-Object IO.BinaryReader($fs)
    try {
        $tailLen = [int][Math]::Min($fs.Length, 65557)
        $fs.Position = $fs.Length - $tailLen
        $tail = $br.ReadBytes($tailLen)
        $i = $tailLen - 22
        while ($i -ge 0 -and [BitConverter]::ToUInt32($tail, $i) -ne 0x06054b50) { $i-- }
        if ($i -lt 0) { throw "Kein ZIP-Ende gefunden: $ZipPath" }
        $count  = [BitConverter]::ToUInt16($tail, $i + 10)
        $cdSize = [BitConverter]::ToUInt32($tail, $i + 12)
        $cdOff  = [BitConverter]::ToUInt32($tail, $i + 16)
        if ($cdOff -eq [uint32]::MaxValue -or $count -eq [uint16]::MaxValue) { throw 'ZIP64 wird nicht unterstützt.' }
        $fs.Position = $cdOff
        $cd = $br.ReadBytes([int]$cdSize)
        $p = 0
        for ($n = 0; $n -lt $count; $n++) {
            if ([BitConverter]::ToUInt32($cd, $p) -ne 0x02014b50) { throw 'Ungültiger Central-Directory-Eintrag.' }
            $nl = [BitConverter]::ToUInt16($cd, $p + 28)
            $el = [BitConverter]::ToUInt16($cd, $p + 30)
            $cl = [BitConverter]::ToUInt16($cd, $p + 32)
            [pscustomobject]@{
                Name   = [Text.Encoding]::UTF8.GetString($cd, $p + 46, $nl)
                Flags  = [BitConverter]::ToUInt16($cd, $p + 8)
                Method = [BitConverter]::ToUInt16($cd, $p + 10)
                Crc    = [BitConverter]::ToUInt32($cd, $p + 16)
                CSize  = [BitConverter]::ToUInt32($cd, $p + 20)
                USize  = [BitConverter]::ToUInt32($cd, $p + 24)
            }
            $p += 46 + $nl + $el + $cl
        }
    } finally { $br.Dispose(); $fs.Dispose() }
}

# ============================ Packen ============================

function New-ZipFromFolder {
    # Eigene Implementierung: Eintragsnamen mit '/', leere Ordner werden mitgenommen
    param([string]$Folder, [string]$ZipPath)
    $fs  = [IO.File]::Create($ZipPath)
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $base = $Folder.TrimEnd('\') + '\'
        Get-ChildItem -LiteralPath $Folder -Recurse -File -Force | ForEach-Object {
            $rel = $_.FullName.Substring($base.Length).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $_.FullName, $rel, [IO.Compression.CompressionLevel]::Optimal)
        }
        Get-ChildItem -LiteralPath $Folder -Recurse -Directory -Force | Where-Object {
            -not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1)
        } | ForEach-Object {
            [void]$zip.CreateEntry($_.FullName.Substring($base.Length).Replace('\', '/') + '/')
        }
    } finally { $zip.Dispose(); $fs.Dispose() }
}

function Protect-IntuneContent {
    # Klartext-ZIP -> Datei im Format: HMAC (32) | IV (16) | AES-256-CBC-Ciphertext
    param([string]$PlainPath, [string]$EncPath)

    $rng    = [Security.Cryptography.RandomNumberGenerator]::Create()
    $key    = New-Object byte[] 32
    $macKey = New-Object byte[] 32
    $iv     = New-Object byte[] 16
    $rng.GetBytes($key); $rng.GetBytes($macKey); $rng.GetBytes($iv)
    $rng.Dispose()

    # FileDigest = SHA-256 über das unverschlüsselte ZIP
    $sha = [Security.Cryptography.SHA256]::Create()
    $in  = [IO.File]::OpenRead($PlainPath)
    try { $digest = $sha.ComputeHash($in); $plainSize = $in.Length } finally { $in.Dispose() }

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $aes.Key = $key;    $aes.IV = $iv
    $out = [IO.File]::Create($EncPath)
    $out.Write((New-Object byte[] 32), 0, 32)      # Platzhalter für den MAC
    $out.Write($iv, 0, 16)
    $cs  = New-Object Security.Cryptography.CryptoStream($out, $aes.CreateEncryptor(), 'Write')
    $in  = [IO.File]::OpenRead($PlainPath)
    try { $in.CopyTo($cs); $cs.FlushFinalBlock() }
    finally { $in.Dispose(); $cs.Dispose(); $out.Dispose(); $aes.Dispose() }

    # MAC = HMAC-SHA256(MacKey, IV + Ciphertext), in die ersten 32 Byte schreiben
    $fs = [IO.File]::Open($EncPath, 'Open', 'ReadWrite')
    try {
        $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, $macKey)
        $fs.Position = 32
        $mac = $hmac.ComputeHash($fs)
        $fs.Position = 0
        $fs.Write($mac, 0, 32)
    } finally { $fs.Dispose() }

    [pscustomobject]@{ Key = $key; MacKey = $macKey; IV = $iv; Mac = $mac; Digest = $digest; PlainSize = $plainSize }
}

function New-DetectionXml {
    # Byte-genau wie die Datei des offiziellen Tools: CRLF, keine XML-Deklaration, kein abschließender Umbruch
    param($Enc, [string]$Setup, [string]$Version)
    $b64   = { param($b) [Convert]::ToBase64String($b) }
    $esc   = { param($s) [Security.SecurityElement]::Escape($s) }
    $name  = & $esc (Split-Path $Setup -Leaf)
    $setupX = & $esc $Setup
    $lines = @(
        "<ApplicationInfo xmlns:xsd=""http://www.w3.org/2001/XMLSchema"" xmlns:xsi=""http://www.w3.org/2001/XMLSchema-instance"" ToolVersion=""$Version"">"
        "  <Name>$name</Name>"
        "  <UnencryptedContentSize>$($Enc.PlainSize)</UnencryptedContentSize>"
        '  <FileName>IntunePackage.intunewin</FileName>'
        "  <SetupFile>$setupX</SetupFile>"
        '  <EncryptionInfo>'
        "    <EncryptionKey>$(& $b64 $Enc.Key)</EncryptionKey>"
        "    <MacKey>$(& $b64 $Enc.MacKey)</MacKey>"
        "    <InitializationVector>$(& $b64 $Enc.IV)</InitializationVector>"
        "    <Mac>$(& $b64 $Enc.Mac)</Mac>"
        '    <ProfileIdentifier>ProfileVersion1</ProfileIdentifier>'
        "    <FileDigest>$(& $b64 $Enc.Digest)</FileDigest>"
        '    <FileDigestAlgorithm>SHA256</FileDigestAlgorithm>'
        '  </EncryptionInfo>'
        '</ApplicationInfo>'
    )
    $lines -join "`r`n"
}

function Write-StoredZip {
    # Schreibt ein ZIP mit Methode 0 (gespeichert). .NET Framework kann das nicht:
    # NoCompression erzeugt dort Deflate-Blöcke, und das Portal lehnt solche Container ab.
    param([string]$Target, [object[]]$Items)
    foreach ($it in $Items) {
        if ($it.Size -ge [uint32]::MaxValue) { throw 'Dateien ab 4 GB brauchen ZIP64 und werden nicht unterstützt.' }
    }
    $now  = Get-Date
    $dosD = [uint16]((($now.Year - 1980) -shl 9) -bor ($now.Month -shl 5) -bor $now.Day)
    $dosT = [uint16](($now.Hour -shl 11) -bor ($now.Minute -shl 5) -bor [int][Math]::Floor($now.Second / 2))
    $fs = [IO.File]::Create($Target)
    $bw = New-Object IO.BinaryWriter($fs)
    $central = @()
    try {
        foreach ($it in $Items) {
            $nameB  = [Text.Encoding]::UTF8.GetBytes($it.Name)
            $offset = [uint32]$fs.Position
            $bw.Write([uint32]0x04034b50)              # Local file header
            $bw.Write([uint16]10)                      # Version needed
            $bw.Write([uint16]0)                       # Flags
            $bw.Write([uint16]0)                       # Methode 0 = stored
            $bw.Write($dosT); $bw.Write($dosD)
            $bw.Write([uint32]$it.Crc)
            $bw.Write([uint32]$it.Size); $bw.Write([uint32]$it.Size)
            $bw.Write([uint16]$nameB.Length); $bw.Write([uint16]0)
            $bw.Write($nameB)
            $bw.Flush()
            $in = [IO.File]::OpenRead($it.Path)
            try { $in.CopyTo($fs) } finally { $in.Dispose() }
            $central += , @($it, $nameB, $offset)
        }
        $cdStart = [uint32]$fs.Position
        foreach ($c in $central) {
            $it = $c[0]; $nameB = $c[1]
            $bw.Write([uint32]0x02014b50)              # Central directory header
            $bw.Write([uint16]20); $bw.Write([uint16]10)
            $bw.Write([uint16]0);  $bw.Write([uint16]0)
            $bw.Write($dosT); $bw.Write($dosD)
            $bw.Write([uint32]$it.Crc)
            $bw.Write([uint32]$it.Size); $bw.Write([uint32]$it.Size)
            $bw.Write([uint16]$nameB.Length)
            $bw.Write([uint16]0); $bw.Write([uint16]0) # Extra, Kommentar
            $bw.Write([uint16]0); $bw.Write([uint16]0) # Disk, interne Attribute
            $bw.Write([uint32]0)                       # externe Attribute
            $bw.Write([uint32]$c[2])                   # Offset Local Header
            $bw.Write($nameB)
        }
        $cdSize = [uint32]($fs.Position - $cdStart)
        $bw.Write([uint32]0x06054b50)                  # End of central directory
        $bw.Write([uint16]0); $bw.Write([uint16]0)
        $bw.Write([uint16]$Items.Count); $bw.Write([uint16]$Items.Count)
        $bw.Write($cdSize); $bw.Write($cdStart)
        $bw.Write([uint16]0)
        $bw.Flush()
    } finally { $bw.Dispose(); $fs.Dispose() }
}

function Invoke-Pack {
    $src   = (Resolve-Path -LiteralPath (Get-CleanPath $SourceFolder)).Path
    $setup = Get-CleanPath $SetupFile
    if (-not (Test-Path -LiteralPath (Join-Path $src $setup) -PathType Leaf)) {
        throw "SetupFile nicht gefunden: $(Join-Path $src $setup)"
    }
    $outDir = Get-CleanPath $OutputFolder
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $outDir = (Resolve-Path -LiteralPath $outDir).Path
    $name = if ($OutputName) { $OutputName } else { [IO.Path]::GetFileNameWithoutExtension($setup) }
    if ($name -notlike '*.intunewin') { $name += '.intunewin' }
    $target = Join-Path $outDir $name
    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        throw "Zieldatei existiert bereits (mit -Force überschreiben): $target"
    }

    $work = New-WorkDir
    try {
        $plain   = Join-Path $work 'plain.zip'
        $enc     = Join-Path $work 'IntunePackage.intunewin'
        $xmlFile = Join-Path $work 'Detection.xml'

        # 1) Klartext-ZIP
        if ($PlainZip) { Copy-Item -LiteralPath (Get-CleanPath $PlainZip) -Destination $plain }
        else           { New-ZipFromFolder -Folder $src -ZipPath $plain }

        # 2) Hash, AES-Verschlüsselung, MAC
        $info = Protect-IntuneContent -PlainPath $plain -EncPath $enc

        # 3) Detection.xml
        $xml = New-DetectionXml -Enc $info -Setup $setup -Version $ToolVersion
        [IO.File]::WriteAllBytes($xmlFile, (New-Object Text.UTF8Encoding($false)).GetBytes($xml))

        # 4) CRC32-Werte über ein Hilfs-ZIP ermitteln (braucht kurz Platz in der Größe der Datei)
        $tmpZip = Join-Path $work 'crc.zip'
        $tfs = [IO.File]::Create($tmpZip)
        $tz  = New-Object IO.Compression.ZipArchive($tfs, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($tz, $enc,     $script:NameEnc, [IO.Compression.CompressionLevel]::Fastest)
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($tz, $xmlFile, $script:NameXml, [IO.Compression.CompressionLevel]::Fastest)
        } finally { $tz.Dispose(); $tfs.Dispose() }
        $crc = @{}
        foreach ($e in @(Get-ZipInfo $tmpZip)) { $crc[$e.Name] = $e.Crc }

        # 5) Finaler Container mit Methode 0
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Write-StoredZip -Target $target -Items @(
            @{ Name = $script:NameEnc; Path = $enc;     Crc = $crc[$script:NameEnc]; Size = (Get-Item -LiteralPath $enc).Length }
            @{ Name = $script:NameXml; Path = $xmlFile; Crc = $crc[$script:NameXml]; Size = (Get-Item -LiteralPath $xmlFile).Length }
        )
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "Erzeugt: $target"
    Invoke-Test -File $target
}

# ============================ Lesen: Prüfen und Entpacken ============================

function Open-IntuneWin {
    # Liest Container, prüft MAC, entschlüsselt nach $Tmp\plain.zip, prüft Digest und Größe
    param([string]$File, [string]$Tmp, [switch]$RequireMac)
    $zip = [IO.Compression.ZipFile]::OpenRead($File)
    try {
        $xmlE = $zip.Entries | Where-Object { $_.Name -eq 'Detection.xml' } | Select-Object -First 1
        $encE = $zip.Entries | Where-Object { $_.Name -eq 'IntunePackage.intunewin' } | Select-Object -First 1
        if (-not $xmlE -or -not $encE) { throw 'Detection.xml oder IntunePackage.intunewin fehlt im Container.' }
        $sr = New-Object IO.StreamReader($xmlE.Open())
        try { [xml]$x = $sr.ReadToEnd() } finally { $sr.Dispose() }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($encE, (Join-Path $Tmp 'enc'))
    } finally { $zip.Dispose() }

    $i   = $x.ApplicationInfo.EncryptionInfo
    $key = [Convert]::FromBase64String($i.EncryptionKey)
    $mk  = [Convert]::FromBase64String($i.MacKey)
    $plain = Join-Path $Tmp 'plain.zip'
    $macOk = $false; $decOk = $false; $digestOk = $false; $sizeOk = $false

    $fs = [IO.File]::OpenRead((Join-Path $Tmp 'enc'))
    try {
        $stored = New-Object byte[] 32
        [void]$fs.Read($stored, 0, 32)
        $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, $mk)
        $calc = $hmac.ComputeHash($fs)
        $macOk = ([Convert]::ToBase64String($stored) -eq [Convert]::ToBase64String($calc))
        if (-not $macOk -and $RequireMac) {
            throw 'MAC-Prüfung fehlgeschlagen: Datei ist beschädigt oder manipuliert. Abbruch.'
        }
        $iv = New-Object byte[] 16
        $fs.Position = 32
        [void]$fs.Read($iv, 0, 16)
        $aes = [Security.Cryptography.Aes]::Create()
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $key; $aes.IV = $iv
        try {
            $cs = New-Object Security.Cryptography.CryptoStream($fs, $aes.CreateDecryptor(), 'Read')
            $o  = [IO.File]::Create($plain)
            try { $cs.CopyTo($o) } finally { $o.Dispose() }
            $decOk = $true
        } catch { if ($RequireMac) { throw } }
    } finally { $fs.Dispose() }

    if ($decOk) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $p = [IO.File]::OpenRead($plain)
        try { $d = [Convert]::ToBase64String($sha.ComputeHash($p)); $len = $p.Length } finally { $p.Dispose() }
        $digestOk = ($d -eq $i.FileDigest)
        $sizeOk   = ($len -eq [int64]$x.ApplicationInfo.UnencryptedContentSize)
    }
    [pscustomobject]@{
        Xml = $x; PlainZip = $plain
        MacOk = $macOk; DecryptOk = $decOk; DigestOk = $digestOk; SizeOk = $sizeOk
    }
}

function Invoke-Test {
    param([string]$File, [switch]$List)
    $File = (Resolve-Path -LiteralPath $File).Path
    $entries = @(Get-ZipInfo $File)
    Write-Host 'Einträge im Container:'
    ($entries | Format-Table Name, Method, CSize, USize -AutoSize | Out-String).TrimEnd() | Write-Host
    $stored = -not @($entries | Where-Object { $_.Method -ne 0 })
    if (-not $stored) {
        Write-Warning 'Mindestens ein Eintrag ist nicht mit Methode 0 (gespeichert) abgelegt. Das kann den Upload im Portal scheitern lassen.'
    }
    $tmp = New-WorkDir
    try {
        $r = Open-IntuneWin -File $File -Tmp $tmp
        if ($List -and $r.DecryptOk) {
            $z = [IO.Compression.ZipFile]::OpenRead($r.PlainZip)
            try { Write-Host "`nInneres ZIP ($($z.Entries.Count) Einträge):"; $z.Entries | ForEach-Object { Write-Host "  $($_.FullName)  ($($_.Length) Byte)" } }
            finally { $z.Dispose() }
        }
        $xmlLen = ($entries | Where-Object { $_.Name -like '*Detection.xml' } | Select-Object -First 1).USize
        [pscustomobject]@{
            ContainerGespeichert = $stored
            MacOk                = $r.MacOk
            DecryptOk            = $r.DecryptOk
            DigestOk             = $r.DigestOk
            SizeOk               = $r.SizeOk
            ProfileIdentifier    = $r.Xml.ApplicationInfo.EncryptionInfo.ProfileIdentifier
            ToolVersion          = $r.Xml.ApplicationInfo.ToolVersion
            SetupFile            = $r.Xml.ApplicationInfo.SetupFile
            DetectionXmlBytes    = $xmlLen
        } | Format-List
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-Unpack {
    $file = (Resolve-Path -LiteralPath (Get-CleanPath $Path)).Path
    $dest = Get-CleanPath $Destination
    if ((Test-Path -LiteralPath $dest) -and (Get-ChildItem -LiteralPath $dest -Force | Select-Object -First 1)) {
        throw "Zielordner ist nicht leer: $dest"
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $destRoot = [IO.Path]::GetFullPath($dest).TrimEnd('\') + '\'

    $tmp = New-WorkDir
    try {
        $r = Open-IntuneWin -File $file -Tmp $tmp -RequireMac
        if (-not $r.DigestOk) { Write-Warning 'FileDigest stimmt nicht mit dem entschlüsselten ZIP überein.' }
        if (-not $r.SizeOk)   { Write-Warning 'Größe weicht von UnencryptedContentSize ab.' }
        if ($KeepPlainZip)    { Copy-Item -LiteralPath $r.PlainZip -Destination ($file + '.plain.zip') -Force }

        $files = 0
        $z = [IO.Compression.ZipFile]::OpenRead($r.PlainZip)
        try {
            foreach ($e in $z.Entries) {
                $target = [IO.Path]::GetFullPath($destRoot + $e.FullName.Replace('/', '\'))
                if (-not $target.StartsWith($destRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Unzulässiger Pfad im Archiv: $($e.FullName)"
                }
                if ([string]::IsNullOrEmpty($e.Name)) {            # Verzeichniseintrag
                    New-Item -ItemType Directory -Force -Path $target | Out-Null
                    continue
                }
                New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                $files++
            }
        } finally { $z.Dispose() }

        [pscustomobject]@{
            Dateien     = $files
            SetupFile   = $r.Xml.ApplicationInfo.SetupFile
            ToolVersion = $r.Xml.ApplicationInfo.ToolVersion
            DigestOk    = $r.DigestOk
            SizeOk      = $r.SizeOk
            Ziel        = $dest
        } | Format-List
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ============================ Hauptablauf ============================

switch ($PSCmdlet.ParameterSetName) {
    'Pack'   { Invoke-Pack }
    'Unpack' { Invoke-Unpack }
    'Test'   { Invoke-Test -File (Get-CleanPath $Path) -List:$ListContent }
}

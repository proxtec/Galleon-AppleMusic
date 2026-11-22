# Apple Music Now Playing - Hilfsprozess (Windows PowerShell 5.1)
# Liest die Windows-Mediensteuerung (SMTC) aus, zeichnet die Display-Bilder und gibt alles als JSON-Zeilen aus.
# Befehle (stdin, zeilenweise): toggle | next | prev | seek:<s> | mode:apple|any | render:on|off
#                               volrender:on|off | vol:<+/-Prozent> | mute | shuffle | repeat | open
param([string]$Mode = 'apple', [switch]$NoRender)
$script:Mode = $Mode

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8

Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType=WindowsRuntime]

function Log([string]$msg) { [Console]::Error.WriteLine($msg) }

# ---------------- WinRT-Hilfen ----------------
$script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await($op, [Type]$type) {
    $task = $script:asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    if (-not $task.Wait(4000)) { return $null }
    return $task.Result
}

function Emit($obj) {
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress -Depth 4))
    [Console]::Out.Flush()
}

# ---------------- Systemlautstaerke (Core Audio) ----------------
$script:audioOk = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAmAudioEndpointVolume {
  int f(); int g(); int h(); int i();
  int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
  int j();
  int GetMasterVolumeLevelScalar(out float pfLevel);
  int k(); int l(); int m(); int n();
  int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
  int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAmMMDevice { int Activate(ref Guid id, int clsCtx, int activationParams, out IAmAudioEndpointVolume aev); }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAmMMDeviceEnumerator { int f(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IAmMMDevice endpoint); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class AmMMDeviceEnumeratorComObject { }
public static class AmAudio {
  static IAmAudioEndpointVolume Vol() {
    var enumerator = new AmMMDeviceEnumeratorComObject() as IAmMMDeviceEnumerator;
    IAmMMDevice dev = null;
    Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
    IAmAudioEndpointVolume epv = null;
    var epvid = typeof(IAmAudioEndpointVolume).GUID;
    Marshal.ThrowExceptionForHR(dev.Activate(ref epvid, 23, 0, out epv));
    return epv;
  }
  public static float GetVolume() { float v = -1; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
  public static void SetVolume(float v) { Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(Math.Max(0f, Math.Min(1f, v)), Guid.Empty)); }
  public static bool GetMute() { bool m; Marshal.ThrowExceptionForHR(Vol().GetMute(out m)); return m; }
  public static void SetMute(bool m) { Marshal.ThrowExceptionForHR(Vol().SetMute(m, Guid.Empty)); }
}
'@
    $script:audioOk = $true
}
catch { Log "Lautstaerke-Steuerung nicht verfuegbar: $_" }

# ---------------- SMTC ----------------
function Get-Manager {
    return Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
    ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
}

function Get-Session {
    foreach ($s in @($script:mgr.GetSessions())) {
        if ($s.SourceAppUserModelId -match 'AppleMusic|iTunes') { return $s }
    }
    if ($script:Mode -eq 'any') { return $script:mgr.GetCurrentSession() }
    return $null
}

function Get-Position($s) {
    $tl = $s.GetTimelineProperties()
    $pos = $tl.Position.TotalSeconds
    $dur = ($tl.EndTime - $tl.StartTime).TotalSeconds
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing' -and $tl.LastUpdatedTime.Year -gt 2000) {
        $pos += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds
    }
    if ($dur -gt 0 -and $pos -gt $dur) { $pos = $dur }
    if ($pos -lt 0) { $pos = 0 }
    return @($pos, $dur)
}

function Split-Artist([string]$artist, [string]$album) {
    # Apple Music fuer Windows schreibt teils "Kuenstler <Gedankenstrich> Album" ins Kuenstlerfeld
    $sep = ' ' + [char]0x2014 + ' '
    $i = if ($artist) { $artist.IndexOf($sep) } else { -1 }
    if ($i -gt 0) {
        if (-not $album) { $album = $artist.Substring($i + 3) }
        $artist = $artist.Substring(0, $i)
    }
    return @($artist, $album)
}

# Cover aus der Windows-Mediensteuerung
function Get-ArtSmtc($props) {
    if ($null -eq $props -or $null -eq $props.Thumbnail) { throw 'App liefert kein Cover (Thumbnail leer)' }
    $stream = Await ($props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    if ($null -eq $stream) { throw 'Cover-Stream nicht lesbar' }
    $bytes = $null
    try {
        $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
        $ms = New-Object System.IO.MemoryStream
        $net.CopyTo($ms)
        $bytes = $ms.ToArray()
        $net.Dispose()
    }
    catch { Log "Cover via Stream fehlgeschlagen: $_" }
    if ($null -eq $bytes -or $bytes.Length -eq 0) {
        $size = [uint32]$stream.Size
        if ($size -eq 0) { throw 'Cover-Stream ist leer' }
        $reader = New-Object Windows.Storage.Streams.DataReader ($stream.GetInputStreamAt(0))
        $null = Await ($reader.LoadAsync($size)) ([uint32])
        $bytes = New-Object byte[] $size
        $reader.ReadBytes($bytes)
        $reader.Dispose()
    }
    return $bytes
}

# Fallback: Cover ueber die oeffentliche Apple-Suche (iTunes Search API) holen
function Get-ArtOnline([string]$title, [string]$artist) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $term = [Uri]::EscapeDataString(("$artist $title").Trim())
    $res = Invoke-RestMethod -Uri "https://itunes.apple.com/search?term=$term&entity=song&limit=1&country=de" -TimeoutSec 5 -UseBasicParsing
    if (-not $res.results -or $res.resultCount -eq 0) { throw 'Apple-Suche fand keinen Treffer' }
    $url = $res.results[0].artworkUrl100 -replace '\d+x\d+bb', '600x600bb'
    $img = Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing
    return [byte[]]$img.Content
}

function To-DataUrl([byte[]]$bytes) {
    $ct = 'image/png'
    if ($bytes.Length -gt 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { $ct = 'image/jpeg' }
    return "data:$ct;base64," + [Convert]::ToBase64String($bytes)
}

# ---------------- Zeichnen ----------------
$script:W = 200; $script:H = 100
$script:render = -not $NoRender
$script:volRender = $false
$script:artImg = $null; $script:artStream = $null
$script:baseBmp = $null; $script:baseKey = $null
$script:lastFrameKey = $null; $script:lastVolKey = $null
$script:marqueeKey = $null; $script:marqueeStart = [DateTime]::Now; $script:titleW = 0; $script:fast = $false

function C($a, $r, $g, $b) { return [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

function New-Font([string[]]$families, [float]$px) {
    foreach ($fam in $families) {
        try {
            $f = New-Object System.Drawing.Font($fam, $px, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            if ($f.Name -eq $fam) { return $f }
            $f.Dispose()
        } catch {}
    }
    return New-Object System.Drawing.Font('Segoe UI', $px, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
}
$script:fTitle = New-Font @('Segoe UI Semibold') 14
$script:fArtist = New-Font @('Segoe UI') 12
$script:fTime = New-Font @('Segoe UI Semibold') 9
$script:fBig = New-Font @('Segoe UI Semibold') 22
$script:fLabel = New-Font @('Segoe UI') 12
$iconFamilies = @('Segoe Fluent Icons', 'Segoe MDL2 Assets')
$script:fIconSmall = New-Font $iconFamilies 26
$script:fIconKey = New-Font $iconFamilies 58
$script:fIconCover = New-Font $iconFamilies 30

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min($r * 2, [Math]::Min($w, $h))
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Set-Quality($g) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
}

function Set-Art([byte[]]$bytes) {
    if ($script:artImg) { $script:artImg.Dispose(); $script:artImg = $null }
    if ($script:artStream) { $script:artStream.Dispose(); $script:artStream = $null }
    $script:baseKey = $null; $script:lastVolKey = $null
    if ($null -eq $bytes) { return }
    try {
        $script:artStream = New-Object System.IO.MemoryStream(, $bytes)
        $script:artImg = [System.Drawing.Image]::FromStream($script:artStream)
    } catch { Log "Cover-Bild ungueltig: $_"; $script:artImg = $null }
}

function Draw-Text($g, [string]$text, $font, $color, [float]$x, [float]$y, [float]$w, [float]$h, [string]$align = 'Near') {
    $sf = New-Object System.Drawing.StringFormat
    $sf.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $sf.Alignment = [System.Drawing.StringAlignment]::$align
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $br = New-Object System.Drawing.SolidBrush($color)
    $g.DrawString($text, $font, $br, (New-Object System.Drawing.RectangleF($x, $y, $w, $h)), $sf)
    $br.Dispose(); $sf.Dispose()
}

function To-PngDataUrl($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $url = 'data:image/png;base64,' + [Convert]::ToBase64String($ms.ToArray())
    $ms.Dispose()
    return $url
}

# Hintergrund: stark weichgezeichnetes, abgedunkeltes Cover (wie in Apple Music) bzw. Dunkelgrau
function Draw-Backdrop($g, [int]$W, [int]$H) {
    $g.Clear((C 255 28 28 30))
    $img = $script:artImg
    if (-not $img) { return }
    $tiny = New-Object System.Drawing.Bitmap(10, 5)
    $tg = [System.Drawing.Graphics]::FromImage($tiny); Set-Quality $tg
    $sh = [int]($img.Height * 0.5)
    $tg.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, 10, 5)), 0, [int](($img.Height - $sh) / 2), $img.Width, $sh, [System.Drawing.GraphicsUnit]::Pixel)
    $tg.Dispose()
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
    $g.DrawImage($tiny, (New-Object System.Drawing.Rectangle(0, 0, $W, $H)), 0, 0, 10, 5, [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $tiny.Dispose(); $ia.Dispose()
    $veil = New-Object System.Drawing.SolidBrush((C 120 0 0 0)); $g.FillRectangle($veil, 0, 0, $W, $H); $veil.Dispose()
}

# Statischer Teil des Now-Playing-Bildes (aendert sich nur bei neuem Titel / Play-Pause / Cover)
function Get-Base($st) {
    $k = "$($st.active)|$($st.key)|$($st.status)|$([bool]$script:artImg)"
    if ($k -eq $script:baseKey -and $script:baseBmp) { return $script:baseBmp }
    if ($script:baseBmp) { $script:baseBmp.Dispose() }
    $W = $script:W; $H = $script:H
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp); Set-Quality $g
    $img = $script:artImg
    Draw-Backdrop $g $W $H

    # Artwork mit abgerundeten Ecken und weichem Schatten
    $ax = 10; $ay = 18; $as = 64; $ar = 8
    for ($i = 4; $i -ge 1; $i--) {
        $sp = New-RoundRect ($ax - $i + 1) ($ay - $i + 3) ($as + 2 * $i - 2) ($as + 2 * $i - 2) ($ar + $i)
        $sb = New-Object System.Drawing.SolidBrush((C 22 0 0 0)); $g.FillPath($sb, $sp); $sb.Dispose(); $sp.Dispose()
    }
    $path = New-RoundRect $ax $ay $as $as $ar
    if ($img -and $st.active) {
        $scaled = New-Object System.Drawing.Bitmap($as, $as)
        $sg = [System.Drawing.Graphics]::FromImage($scaled); Set-Quality $sg
        $side = [Math]::Min($img.Width, $img.Height)
        $sg.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $as, $as)), [int](($img.Width - $side) / 2), [int](($img.Height - $side) / 2), $side, $side, [System.Drawing.GraphicsUnit]::Pixel)
        $sg.Dispose()
        $tb = New-Object System.Drawing.TextureBrush($scaled)
        $tb.TranslateTransform($ax, $ay)
        $g.FillPath($tb, $path); $tb.Dispose(); $scaled.Dispose()
    }
    else {
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point($ax, $ay)), (New-Object System.Drawing.Point($ax, ($ay + $as))), (C 255 72 72 76), (C 255 44 44 48))
        $g.FillPath($lg, $path); $lg.Dispose()
        Draw-Text $g ([string][char]0xE8D6) $script:fIconCover (C 255 250 45 72) $ax $ay $as $as 'Center'
    }
    $hair = New-Object System.Drawing.Pen((C 40 255 255 255), 1); $g.DrawPath($hair, $path); $hair.Dispose()

    if ($st.active -and $st.status -ne 'Playing') {
        $pb = New-Object System.Drawing.SolidBrush((C 120 0 0 0)); $g.FillPath($pb, $path); $pb.Dispose()
        $cx = $ax + $as / 2; $cy = $ay + $as / 2
        $tri = [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(($cx - 8), ($cy - 11))), (New-Object System.Drawing.PointF(($cx - 8), ($cy + 11))), (New-Object System.Drawing.PointF(($cx + 12), $cy)))
        $wb = New-Object System.Drawing.SolidBrush((C 240 255 255 255)); $g.FillPolygon($wb, $tri); $wb.Dispose()
    }
    $path.Dispose()

    $tx = 84; $tw = $W - $tx - 8
    if ($st.active) {
        $artist = if ($st.artist) { $st.artist } else { $st.album }
        Draw-Text $g $artist $script:fArtist (C 170 255 255 255) $tx 37 $tw 17
    }
    else {
        Draw-Text $g 'Apple Music' $script:fTitle (C 255 255 255 255) $tx 30 $tw 20
        Draw-Text $g 'Keine Wiedergabe' $script:fArtist (C 150 255 255 255) $tx 49 $tw 17
    }
    $g.Dispose()
    $script:baseBmp = $bmp; $script:baseKey = $k
    return $bmp
}

function Format-Time([double]$s) {
    $s = [Math]::Max(0, [Math]::Floor($s))
    $h = [Math]::Floor($s / 3600); $m = [Math]::Floor(($s % 3600) / 60); $sec = $s % 60
    if ($h -gt 0) { return ('{0}:{1:00}:{2:00}' -f $h, $m, $sec) }
    return ('{0}:{1:00}' -f $m, $sec)
}

function Render-Frame($st) {
    $base = Get-Base $st
    $tx = 84; $tw = $script:W - $tx - 8
    $title = if ($st.title) { $st.title } else { 'Unbekannter Titel' }
    $offset = 0; $script:fast = $false
    if ($st.active) {
        if ($script:marqueeKey -ne $st.key) {
            $script:marqueeKey = $st.key; $script:marqueeStart = [DateTime]::Now
            $mg = [System.Drawing.Graphics]::FromImage($base); Set-Quality $mg
            $script:titleW = $mg.MeasureString($title, $script:fTitle, (New-Object System.Drawing.PointF(0, 0)), [System.Drawing.StringFormat]::GenericTypographic).Width
            $mg.Dispose()
        }
        if ($script:titleW -gt $tw) {
            # Laufschrift: 2,5 s Pause, dann ca. 24 px/s
            $script:fast = $true
            $cycle = 2500 + ($script:titleW + 36) / 24 * 1000
            $t = (([DateTime]::Now - $script:marqueeStart).TotalMilliseconds) % $cycle
            if ($t -gt 2500) { $offset = [Math]::Round(($t - 2500) / 1000 * 24) }
        }
    }
    $frameKey = "$($script:baseKey)|$($st.position)|$($st.duration)|$offset"
    if ($frameKey -eq $script:lastFrameKey) { return }
    $script:lastFrameKey = $frameKey
    $bmp = $base.Clone()
    $g = [System.Drawing.Graphics]::FromImage($bmp); Set-Quality $g
    if ($st.active) {
        $white = New-Object System.Drawing.SolidBrush((C 255 255 255 255))
        $g.SetClip((New-Object System.Drawing.RectangleF($tx, 14, $tw, 24)))
        $gt = [System.Drawing.StringFormat]::GenericTypographic
        if ($script:titleW -gt $tw) {
            $g.DrawString($title, $script:fTitle, $white, [float]($tx - $offset), [float]17, $gt)
            $g.DrawString($title, $script:fTitle, $white, [float]($tx - $offset + $script:titleW + 36), [float]17, $gt)
        }
        else { $g.DrawString($title, $script:fTitle, $white, [float]$tx, [float]17, $gt) }
        $g.ResetClip(); $white.Dispose()
    }
    if ($st.active -and $st.duration -gt 0) {
        $tw = $script:W - $tx - 10; $py = 64; $ph = 4
        $pct = [Math]::Min(1, [Math]::Max(0, $st.position / $st.duration))
        $track = New-RoundRect $tx $py $tw $ph 2
        $tb = New-Object System.Drawing.SolidBrush((C 60 255 255 255)); $g.FillPath($tb, $track); $tb.Dispose(); $track.Dispose()
        $fill = New-RoundRect $tx $py ([Math]::Max($ph, $tw * $pct)) $ph 2
        $fb = New-Object System.Drawing.SolidBrush((C 235 255 255 255)); $g.FillPath($fb, $fill); $fb.Dispose(); $fill.Dispose()
        Draw-Text $g (Format-Time $st.position) $script:fTime (C 150 255 255 255) $tx 71 ($tw / 2) 14 'Near'
        Draw-Text $g ('-' + (Format-Time ($st.duration - $st.position))) $script:fTime (C 150 255 255 255) ($tx + $tw / 2) 71 ($tw / 2) 14 'Far'
    }
    $g.Dispose()
    $url = To-PngDataUrl $bmp
    $bmp.Dispose()
    Emit ([ordered]@{ type = 'frame'; data = $url })
}

# Lautstaerke-Feld fuers Display (Hintergrund passend zum aktuellen Cover)
function Render-Volume() {
    if (-not $script:audioOk) { return }
    $v = [int][Math]::Round([AmAudio]::GetVolume() * 100)
    $mute = [AmAudio]::GetMute()
    $k = "$v|$mute|$([bool]$script:artImg)|$($script:baseKey)"
    if ($k -eq $script:lastVolKey) { return }
    $script:lastVolKey = $k
    $W = $script:W; $H = $script:H
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp); Set-Quality $g
    Draw-Backdrop $g $W $H
    $glyph = if ($mute -or $v -eq 0) { 0xE74F } elseif ($v -lt 34) { 0xE993 } elseif ($v -lt 67) { 0xE994 } else { 0xE995 }
    Draw-Text $g ([string][char]$glyph) $script:fIconSmall (C 255 255 255 255) 12 16 34 34 'Near'
    Draw-Text $g ('Lautst' + [char]0xE4 + 'rke') $script:fLabel (C 160 255 255 255) 48 16 80 34 'Near'
    $valText = if ($mute) { 'Stumm' } else { "$v %" }
    Draw-Text $g $valText $script:fBig (C 255 255 255 255) 96 13 92 38 'Far'
    $bx = 12; $bw = $W - 24; $by = 64; $bh = 6
    $track = New-RoundRect $bx $by $bw $bh 3
    $tb = New-Object System.Drawing.SolidBrush((C 60 255 255 255)); $g.FillPath($tb, $track); $tb.Dispose(); $track.Dispose()
    if ($v -gt 0) {
        $fill = New-RoundRect $bx $by ([Math]::Max($bh, $bw * $v / 100)) $bh 3
        $alpha = if ($mute) { 90 } else { 235 }
        $fb = New-Object System.Drawing.SolidBrush((C $alpha 255 255 255)); $g.FillPath($fb, $fill); $fb.Dispose(); $fill.Dispose()
    }
    $g.Dispose()
    $url = To-PngDataUrl $bmp
    $bmp.Dispose()
    Emit ([ordered]@{ type = 'volframe'; data = $url })
}

# Tastenbilder (144x144) mit Segoe-Fluent-Symbolen
function Render-KeyIcon([int]$glyph, $color) {
    $bmp = New-Object System.Drawing.Bitmap(144, 144, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp); Set-Quality $g
    $g.Clear((C 255 0 0 0))
    $path = New-RoundRect 0 0 144 144 30
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, 144)), (C 255 58 58 64), (C 255 28 28 32))
    $g.FillPath($lg, $path); $lg.Dispose(); $path.Dispose()
    Draw-Text $g ([string][char]$glyph) $script:fIconKey $color 0 0 144 144 'Center'
    $g.Dispose()
    $url = To-PngDataUrl $bmp
    $bmp.Dispose()
    return $url
}

function Emit-KeyIcons {
    $white = C 255 255 255 255; $dim = C 110 255 255 255; $pink = C 255 250 45 72
    Emit ([ordered]@{
            type = 'keyimgs'
            imgs = [ordered]@{
                next        = Render-KeyIcon 0xE893 $white
                previous    = Render-KeyIcon 0xE892 $white
                shuffle_off = Render-KeyIcon 0xE8B1 $dim
                shuffle_on  = Render-KeyIcon 0xE8B1 $pink
                repeat_off  = Render-KeyIcon 0xE8EE $dim
                repeat_all  = Render-KeyIcon 0xE8EE $pink
                repeat_one  = Render-KeyIcon 0xE8ED $pink
                open        = Render-KeyIcon 0xE8D6 $pink
            }
        })
}

# ---------------- Befehle ----------------
function Invoke-Cmd([string]$line) {
    switch -Wildcard ($line) {
        'mode:*' { $script:Mode = $line.Substring(5); $script:lastJson = $null; return }
        'render:on' { $script:render = $true; $script:lastFrameKey = $null; $script:lastJson = $null; return }
        'render:off' { $script:render = $false; return }
        'volrender:on' { $script:volRender = $true; $script:lastVolKey = $null; return }
        'volrender:off' { $script:volRender = $false; return }
        'vol:*' {
            if (-not $script:audioOk) { return }
            $d = [double]::Parse($line.Substring(4), [Globalization.CultureInfo]::InvariantCulture)
            if ([AmAudio]::GetMute() -and $d -gt 0) { [AmAudio]::SetMute($false) }
            [AmAudio]::SetVolume([float]([AmAudio]::GetVolume() + $d / 100))
            return
        }
        'mute' { if ($script:audioOk) { [AmAudio]::SetMute(-not [AmAudio]::GetMute()) }; return }
        'open' {
            $aumid = if ($script:lastAumid) { $script:lastAumid } else { 'AppleInc.AppleMusicWin_nzyj5cx40ttqa!App' }
            Start-Process explorer.exe "shell:AppsFolder\$aumid"
            return
        }
    }
    $s = Get-Session
    if ($null -eq $s) { return }
    switch -Wildcard ($line) {
        'toggle' { $null = Await ($s.TryTogglePlayPauseAsync()) ([bool]) }
        'next' { $null = Await ($s.TrySkipNextAsync()) ([bool]) }
        'prev' { $null = Await ($s.TrySkipPreviousAsync()) ([bool]) }
        'seek:*' {
            $delta = [double]::Parse($line.Substring(5), [Globalization.CultureInfo]::InvariantCulture)
            $p = Get-Position $s
            $target = [Math]::Max(0, $p[0] + $delta)
            if ($p[1] -gt 0) { $target = [Math]::Min($target, $p[1] - 1) }
            $null = Await ($s.TryChangePlaybackPositionAsync([long]($target * 10000000))) ([bool])
        }
        'shuffle' {
            $cur = $s.GetPlaybackInfo().IsShuffleActive
            $ok = Await ($s.TryChangeShuffleActiveAsync(-not [bool]$cur)) ([bool])
            if (-not $ok) { Log 'Shuffle: Apple Music hat den Befehl abgelehnt' }
        }
        'repeat' {
            # Reihenfolge wie in Apple Music: Aus -> Alle -> Einen
            $cur = "$($s.GetPlaybackInfo().AutoRepeatMode)"
            $next = switch ($cur) { 'List' { 1 } 'Track' { 0 } default { 2 } }
            $ok = Await ($s.TryChangeAutoRepeatModeAsync($next)) ([bool])
            if (-not $ok) { Log 'Wiederholen: Apple Music hat den Befehl abgelehnt' }
        }
    }
    $script:lastJson = $null
}

# Befehle in eigenem Runspace lesen ([Console]::In.ReadLineAsync() blockiert unter PowerShell 5.1)
$script:cmdQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$readerRs = [runspacefactory]::CreateRunspace(); $readerRs.Open()
$readerPs = [powershell]::Create(); $readerPs.Runspace = $readerRs
$null = $readerPs.AddScript({
        param($q)
        $r = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
        while ($true) {
            $l = $r.ReadLine()
            if ($null -eq $l) { $q.Enqueue('__eof__'); break }
            $q.Enqueue($l)
        }
    }).AddArgument($script:cmdQueue)
$null = $readerPs.BeginInvoke()

# ---------------- Hauptschleife ----------------
Log "start: PS $($PSVersionTable.PSVersion) | Sprachmodus: $($ExecutionContext.SessionState.LanguageMode) | Mode: $($script:Mode) | Lautstaerke: $($script:audioOk)"
$script:mgr = Get-Manager
if ($null -eq $script:mgr) { Log 'FEHLER: Windows-Mediensteuerung (SMTC) nicht erreichbar' }
Emit ([ordered]@{ type = 'hello' })
try { Emit-KeyIcons } catch { Log "Tastenbilder fehlgeschlagen: $_" }

$script:lastJson = $null; $script:lastSessions = $null; $script:lastAumid = $null
$lastKey = $null; $artDone = $false; $artTries = 0; $artOnlineTried = $false
$lastArtTry = [DateTime]::MinValue

while ($true) {
    $line = $null
    while ($script:cmdQueue.TryDequeue([ref]$line)) {
        if ($line -eq '__eof__') { [Environment]::Exit(0) }
        try { Invoke-Cmd $line.Trim() } catch { Log "Befehl '$line' fehlgeschlagen: $_" }
    }

    try {
        if ($null -eq $script:mgr) { $script:mgr = Get-Manager }
        $ids = (@($script:mgr.GetSessions()) | ForEach-Object { $_.SourceAppUserModelId }) -join ', '
        if ($ids -ne $script:lastSessions) { $script:lastSessions = $ids; Log "Medien-Apps: [$ids]" }

        $s = Get-Session
        if ($null -eq $s) {
            $state = [ordered]@{ type = 'state'; active = $false; mode = $script:Mode }
            if ($null -ne $lastKey) { $lastKey = $null; Set-Art $null }
        }
        else {
            $script:lastAumid = $s.SourceAppUserModelId
            $props = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
            $info = $s.GetPlaybackInfo()
            $p = Get-Position $s
            $aa = Split-Artist $props.Artist $props.AlbumTitle
            $key = "$($props.Title)|$($props.Artist)|$($props.AlbumTitle)"
            if ($key -ne $lastKey) { $lastKey = $key; $artDone = $false; $artTries = 0; $artOnlineTried = $false; Set-Art $null }

            # Cover: erst aus der Mediensteuerung (Apple Music liefert es oft verzoegert), sonst online
            if (-not $artDone -and ([DateTime]::Now - $lastArtTry).TotalMilliseconds -ge 700) {
                $lastArtTry = [DateTime]::Now
                $bytes = $null
                if ($artTries -lt 4) {
                    $artTries++
                    try { $bytes = Get-ArtSmtc $props }
                    catch { if ($artTries -eq 4) { Log "Cover aus Apple Music nicht verfuegbar: $_" } }
                }
                elseif (-not $artOnlineTried -and $props.Title) {
                    $artOnlineTried = $true
                    try { $bytes = Get-ArtOnline $props.Title $aa[0]; Log "Cover online gefunden: $($props.Title)" }
                    catch { Log "Cover online nicht gefunden: $_" }
                }
                else { $artDone = $true }
                if ($bytes -and $bytes.Length -gt 0) {
                    Set-Art $bytes
                    if ($script:artImg) {
                        $artDone = $true
                        Emit ([ordered]@{ type = 'art'; key = $key; data = (To-DataUrl $bytes) })
                    }
                }
            }

            $state = [ordered]@{
                type     = 'state'
                active   = $true
                mode     = $script:Mode
                app      = $s.SourceAppUserModelId
                key      = $key
                title    = $props.Title
                artist   = $aa[0]
                album    = $aa[1]
                status   = $info.PlaybackStatus.ToString()
                shuffle  = [bool]$info.IsShuffleActive
                repeat   = "$($info.AutoRepeatMode)"
                position = [Math]::Floor($p[0])
                duration = [Math]::Floor($p[1])
            }
        }
        if ($script:render) { try { Render-Frame $state } catch { Log "Zeichnen fehlgeschlagen: $_" } }
        if ($script:volRender) { try { Render-Volume } catch { Log "Lautstaerke-Anzeige fehlgeschlagen: $_" } }
        $json = $state | ConvertTo-Json -Compress
        if ($json -ne $script:lastJson) {
            $script:lastJson = $json
            [Console]::Out.WriteLine($json)
            [Console]::Out.Flush()
        }
    }
    catch {
        Log "Fehler in der Hauptschleife: $_"
        $script:mgr = $null
        Start-Sleep -Milliseconds 1500
    }
    if ($script:fast -and $script:render) { Start-Sleep -Milliseconds 80 } else { Start-Sleep -Milliseconds 200 }
}

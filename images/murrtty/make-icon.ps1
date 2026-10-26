param(
    [string]$Out = (Join-Path $PSScriptRoot '..\..\dist\windows\murrtty.ico'),
    [string]$Preview = (Join-Path $PSScriptRoot 'icon.png')
)
# murrtty's placeholder icon: a dark rounded square, a teal "m" and an orange
# block cursor. Every standard Windows size; 256 px as PNG, the rest as
# 32-bit DIBs (what every ICO reader takes). Writes dist\windows\murrtty.ico
# and the README's icon.png; needs Windows PowerShell or PowerShell 7 on
# Windows (System.Drawing).
Add-Type -AssemblyName System.Drawing

function Draw([int]$s) {
    $bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $r = [single]([Math]::Max(2, $s * 0.2))
    $inset = [single]([Math]::Max(0, $s * 0.03))
    $w = [single]($s - 2 * $inset)
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddArc($inset, $inset, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($inset + $w - 2 * $r, $inset, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($inset + $w - 2 * $r, $inset + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc($inset, $inset + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 0x1e, 0x20, 0x30)), $path)

    # The "m" and a block cursor after it, its height the m's, centered as
    # a pair on the glyph's outline (not its font box).
    $family = [System.Drawing.FontFamily]::new('Segoe UI')
    # Measure at one size, then pick the size at which the pair spans 64%.
    $probe = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $probe.AddString('m', $family, [int][System.Drawing.FontStyle]::Bold, [single]100, [System.Drawing.PointF]::new(0, 0), [System.Drawing.StringFormat]::GenericTypographic)
    $pb = $probe.GetBounds()
    $em = [single](100 * ($s * 0.64) / ($pb.Width + $pb.Height * 0.55 + 100 * 0.06))
    $glyph = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $glyph.AddString('m', $family, [int][System.Drawing.FontStyle]::Bold, $em, [System.Drawing.PointF]::new(0, 0), [System.Drawing.StringFormat]::GenericTypographic)
    $gb = $glyph.GetBounds()
    $curW = [single]([Math]::Max(2, $gb.Height * 0.55))
    $gap = [single]([Math]::Max(1, $em * 0.06))
    $total = $gb.Width + $gap + $curW
    $dx = [single](($s - $total) / 2 - $gb.X)
    $dy = [single](($s - $gb.Height) / 2 - $gb.Y)
    $m = [System.Drawing.Drawing2D.Matrix]::new()
    $m.Translate($dx, $dy)
    $glyph.Transform($m)
    $g.FillPath([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 0x8b, 0xd5, 0xca)), $glyph)
    $nb = $glyph.GetBounds()
    $g.FillRectangle([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 0xf5, 0xa9, 0x7f)), [single]($nb.Right + $gap), $nb.Y, $curW, $nb.Height)
    $g.Dispose()
    return $bmp
}

function DibBytes([System.Drawing.Bitmap]$bmp) {
    $s = $bmp.Width
    $ms = [IO.MemoryStream]::new()
    $bw = [IO.BinaryWriter]::new($ms)
    $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    for ($y = $s - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $s; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
        }
    }
    # AND mask: all zero (the alpha channel decides), rows padded to 32 bits.
    $stride = [int]([Math]::Ceiling($s / 32.0) * 4)
    $bw.Write([byte[]]::new($stride * $s))
    $bw.Flush()
    return $ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
$images = foreach ($s in $sizes) {
    $bmp = Draw $s
    if ($s -eq 256) {
        $ms = [IO.MemoryStream]::new()
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png)
        , $ms.ToArray()
    } else {
        , (DibBytes $bmp)
    }
    $bmp.Dispose()
}

$icoStream = [IO.MemoryStream]::new()
$bw = [IO.BinaryWriter]::new($icoStream)
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $d = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]$images[$i].Length); $bw.Write([int]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $bw.Write([byte[]]$img) }
$bw.Flush()
[IO.File]::WriteAllBytes($Out, $icoStream.ToArray())
"wrote $Out ($($icoStream.Length) bytes, $($sizes.Count) sizes)"

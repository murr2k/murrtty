param(
    [string]$Gtk, [int]$GX, [int]$GY, [int]$GW, [int]$GH,
    [string]$Mine, [int]$MX, [int]$MY, [double]$MineScale,
    [int]$Zoom, [string]$Out
)
# Side by side: a region of the GTK reference (96 DPI) above the same region
# of murrtty's capture scaled from its DPI to 96, both zoomed `Zoom` times
# with nearest-neighbor, for comparing icons and spacing pixel by pixel.
Add-Type -AssemblyName System.Drawing
$g = [System.Drawing.Image]::FromFile($Gtk)
$m = [System.Drawing.Image]::FromFile($Mine)
$canvas = New-Object System.Drawing.Bitmap ($GW * $Zoom), ($GH * $Zoom * 2 + 8)
$gr = [System.Drawing.Graphics]::FromImage($canvas)
$gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$gr.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$gr.Clear([System.Drawing.Color]::Magenta)
$gr.DrawImage($g, (New-Object System.Drawing.Rectangle 0, 0, ($GW * $Zoom), ($GH * $Zoom)), (New-Object System.Drawing.Rectangle $GX, $GY, $GW, $GH), [System.Drawing.GraphicsUnit]::Pixel)
$src = New-Object System.Drawing.RectangleF $MX, $MY, ($GW * $MineScale), ($GH * $MineScale)
$gr.DrawImage($m, (New-Object System.Drawing.RectangleF 0, ($GH * $Zoom + 8), ($GW * $Zoom), ($GH * $Zoom)), $src, [System.Drawing.GraphicsUnit]::Pixel)
$canvas.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$gr.Dispose(); $canvas.Dispose(); $g.Dispose(); $m.Dispose()
"wrote $Out"

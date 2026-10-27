$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$iconDirectory = Join-Path $PSScriptRoot '..\HelloYrq\Assets.xcassets\AppIcon.appiconset'
New-Item -ItemType Directory -Path $iconDirectory -Force | Out-Null
$bitmap = New-Object System.Drawing.Bitmap(1024, 1024, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb))
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$font = New-Object System.Drawing.Font('Microsoft YaHei', 480, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel))
$format = New-Object System.Drawing.StringFormat
try {
    $graphics.Clear([System.Drawing.Color]::FromArgb(37, 99, 235))
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $graphics.DrawString(([string][char]0x8981), $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, 1024, 1024)), $format)
    $bitmap.Save((Join-Path $iconDirectory 'AppIcon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $format.Dispose()
    $font.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
}

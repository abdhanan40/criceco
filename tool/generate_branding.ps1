# Generates every CricEco logo / launcher / splash asset from the approved
# icon render (branding/source/criceco_icon_approved.webp, 1024x1024).
#
# The approved render shows the icon as a 3D mock-up (light backdrop, bevel,
# drop shadow). Android / iOS need flat layers, so this script:
#   1. extracts the glyph pixel-for-pixel from the flat tile face (colour-keyed
#      against the tile colour, anti-aliasing preserved as alpha);
#   2. samples the exact tile and glyph colours from the render;
#   3. rebuilds the flat rounded tile (measured corner radius) and places the
#      glyph exactly where the render has it — proportions, position, colours
#      untouched. Only the mock-up's bevel, shadow and backdrop are dropped.
# Adaptive / maskable layers scale the glyph (aspect locked) so it stays inside
# the platform safe zone and is never cropped by circular masks.
#
# Usage (from the repo root):  powershell -ExecutionPolicy Bypass -File tool/generate_branding.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'branding/source/criceco_icon_approved.webp'

Add-Type -AssemblyName PresentationCore
$code = @'
using System; using System.IO; using System.Drawing; using System.Drawing.Drawing2D;
using System.Drawing.Imaging; using System.Runtime.InteropServices;

public static class Brand {
  // Measured on the approved render: flat tile face and glyph bounds.
  const int FaceX = 171, FaceY = 171, Face = 701;
  const int GX0 = 247, GY0 = 242, GX1 = 727, GY1 = 781; // glyph bbox + 3px
  public const double CornerFrac = 0.185;                  // tile corner radius / tile size

  public static Color TileColor, Ink;
  static Bitmap glyph; // Face x Face, glyph colour with straight alpha
  public static double MaxReach; // farthest glyph pixel from the tile centre (px)

  public static void Load(string png) {
    using (var b = new Bitmap(png)) {
      int w = b.Width, h = b.Height;
      var d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      var a = new int[w * h]; Marshal.Copy(d.Scan0, a, 0, a.Length); b.UnlockBits(d);
      // Tile colour: glyph-free pixels inside the bbox; ink: fully covered pixels.
      long tr = 0, tg = 0, tb = 0, tn = 0, ir = 0, ig = 0, ib = 0, inn = 0;
      for (int y = GY0; y <= GY1; y++) for (int x = GX0; x <= GX1; x++) {
        int c = a[y * w + x]; int r = (c >> 16) & 255, g = (c >> 8) & 255, bl = c & 255;
        if (g < 48) { tr += r; tg += g; tb += bl; tn++; }
        else if (g > 160) { ir += r; ig += g; ib += bl; inn++; }
      }
      TileColor = Color.FromArgb((int)(tr / tn), (int)(tg / tn), (int)(tb / tn));
      Ink = Color.FromArgb((int)(ir / inn), (int)(ig / inn), (int)(ib / inn));
      double span = Ink.G - TileColor.G;
      glyph = new Bitmap(Face, Face, PixelFormat.Format32bppArgb);
      var gd = glyph.LockBits(new Rectangle(0, 0, Face, Face), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
      var o = new int[Face * Face]; MaxReach = 0; double cx = Face / 2.0, cy = Face / 2.0;
      for (int y = GY0; y <= GY1; y++) for (int x = GX0; x <= GX1; x++) {
        int g = (a[y * w + x] >> 8) & 255;
        double al = (g - TileColor.G) / span;
        if (al < 0.06) continue; if (al > 0.94) al = 1;
        int px = x - FaceX, py = y - FaceY;
        o[py * Face + px] = ((int)Math.Round(al * 255) << 24) | (Ink.R << 16) | (Ink.G << 8) | Ink.B;
        double reach = Math.Sqrt((px + 0.5 - cx) * (px + 0.5 - cx) + (py + 0.5 - cy) * (py + 0.5 - cy));
        if (reach > MaxReach) MaxReach = reach;
      }
      Marshal.Copy(o, 0, gd.Scan0, o.Length); glyph.UnlockBits(gd);
    }
  }

  static Graphics G(Bitmap b) {
    var g = Graphics.FromImage(b);
    g.SmoothingMode = SmoothingMode.AntiAlias; g.InterpolationMode = InterpolationMode.HighQualityBicubic;
    g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.CompositingQuality = CompositingQuality.HighQuality;
    return g;
  }

  static GraphicsPath Rounded(RectangleF r, float rad) {
    var p = new GraphicsPath(); float d = rad * 2;
    p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
    p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
    p.CloseFigure(); return p;
  }

  static void DrawGlyph(Graphics g, float cx, float cy, float tilePx, Color? tint) {
    var dest = new RectangleF(cx - tilePx / 2, cy - tilePx / 2, tilePx, tilePx);
    if (tint == null) { g.DrawImage(glyph, dest); return; }
    var t = tint.Value; var cm = new ColorMatrix(new float[][] {
      new float[] {0,0,0,0,0}, new float[] {0,0,0,0,0}, new float[] {0,0,0,0,0},
      new float[] {0,0,0,1,0}, new float[] {t.R/255f, t.G/255f, t.B/255f, 0, 1} });
    using (var ia = new ImageAttributes()) {
      ia.SetColorMatrix(cm);
      g.DrawImage(glyph, Rectangle.Round(dest), 0, 0, Face, Face, GraphicsUnit.Pixel, ia);
    }
  }

  static void Save(Bitmap b, string path, bool opaque) {
    Directory.CreateDirectory(Path.GetDirectoryName(path));
    if (!opaque) { b.Save(path, ImageFormat.Png); return; }
    using (var rgb = new Bitmap(b.Width, b.Height, PixelFormat.Format24bppRgb)) {
      using (var g = Graphics.FromImage(rgb)) g.DrawImage(b, 0, 0, b.Width, b.Height);
      rgb.Save(path, ImageFormat.Png);
    }
  }

  /// Flat rounded tile with the glyph at the approved proportions.
  /// [tileFrac] = tile size / canvas (transparent margin around it).
  public static void Tile(string path, int canvas, double tileFrac) {
    using (var b = new Bitmap(canvas, canvas, PixelFormat.Format32bppArgb)) using (var g = G(b)) {
      float t = (float)(canvas * tileFrac), o = (canvas - t) / 2;
      using (var br = new SolidBrush(Brand.TileColor)) using (var p = Rounded(new RectangleF(o, o, t, t), (float)(t * CornerFrac))) g.FillPath(br, p);
      DrawGlyph(g, canvas / 2f, canvas / 2f, t, null);
      Save(b, path, false);
    }
  }

  /// Circle-shaped legacy round icon; glyph kept inside the circle.
  public static void Round(string path, int canvas) {
    using (var b = new Bitmap(canvas, canvas, PixelFormat.Format32bppArgb)) using (var g = G(b)) {
      float d = canvas * 44f / 48f, o = (canvas - d) / 2;
      using (var br = new SolidBrush(Brand.TileColor)) g.FillEllipse(br, o, o, d, d);
      DrawGlyph(g, canvas / 2f, canvas / 2f, SafeTile(canvas, d / 2 * 0.86), null);
      Save(b, path, false);
    }
  }

  /// Tile size (px) that keeps every glyph pixel within [radius] of the centre.
  static float SafeTile(int canvas, double radius) { return (float)(Face * radius / MaxReach); }

  /// Glyph-only layer (transparent) with the glyph inside [safeFrac]*canvas of the centre.
  public static void Layer(string path, int canvas, double safeFrac, bool white) {
    using (var b = new Bitmap(canvas, canvas, PixelFormat.Format32bppArgb)) using (var g = G(b)) {
      DrawGlyph(g, canvas / 2f, canvas / 2f, SafeTile(canvas, canvas * safeFrac), white ? (Color?)Color.White : null);
      Save(b, path, false);
    }
  }

  /// Full-bleed square (tile colour to the edges); glyph at approved proportions
  /// (iOS applies its own mask) or inside a safe radius (web maskable).
  public static void FullBleed(string path, int canvas, double safeFrac, bool opaque) {
    using (var b = new Bitmap(canvas, canvas, PixelFormat.Format32bppArgb)) using (var g = G(b)) {
      g.Clear(Brand.TileColor);
      float t = safeFrac <= 0 ? canvas : SafeTile(canvas, canvas * safeFrac);
      DrawGlyph(g, canvas / 2f, canvas / 2f, t, null);
      Save(b, path, opaque);
    }
  }

  public static string Hex(Color c) { return string.Format("#{0:X2}{1:X2}{2:X2}", c.R, c.G, c.B); }
}
'@
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Drawing

# Decode the approved WebP (Windows imaging codec) to a lossless PNG.
$work = Join-Path $env:TEMP 'criceco-branding'; New-Item -ItemType Directory -Force $work | Out-Null
$png = Join-Path $work 'source.png'
$fs = [IO.File]::OpenRead($src)
$dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create($fs, 'PreservePixelFormat', 'OnLoad')
$enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($dec.Frames[0]))
$out = [IO.File]::Create($png); $enc.Save($out); $out.Close(); $fs.Close()

[Brand]::Load($png)
"tile $([Brand]::Hex([Brand]::TileColor))  glyph $([Brand]::Hex([Brand]::Ink))  reach $([Math]::Round([Brand]::MaxReach,1))px"

$res = Join-Path $root 'android/app/src/main/res'
# Adaptive icon: 108dp layers; glyph inside the 66dp safe circle (radius 33/108 ≈ 0.3056 → 0.30).
$dens = @{ 'mdpi' = 1.0; 'hdpi' = 1.5; 'xhdpi' = 2.0; 'xxhdpi' = 3.0; 'xxxhdpi' = 4.0 }
foreach ($d in $dens.Keys) {
  $f = $dens[$d]
  [Brand]::Tile("$res/mipmap-$d/ic_launcher.png", [int](48 * $f), 44 / 48)          # legacy (< API 26)
  [Brand]::Round("$res/mipmap-$d/ic_launcher_round.png", [int](48 * $f))           # legacy round
  [Brand]::Layer("$res/mipmap-$d/ic_launcher_foreground.png", [int](108 * $f), 0.30, $false)
  [Brand]::Layer("$res/mipmap-$d/ic_launcher_monochrome.png", [int](108 * $f), 0.30, $true)
  [Brand]::Layer("$res/drawable-$d/splash_logo.png", [int](160 * $f), 0.30, $false) # pre-API 31 splash
}

# In-app logo (flat tile, transparent corners). 512 px: downscaled from the 701 px face.
[Brand]::Tile((Join-Path $root 'assets/branding/criceco_logo.png'), 512, 1.0)

# iOS AppIcon: opaque full-bleed squares at the approved proportions.
$ios = Join-Path $root 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
foreach ($spec in @('20x20@1x:20','20x20@2x:40','20x20@3x:60','29x29@1x:29','29x29@2x:58','29x29@3x:87',
                    '40x40@1x:40','40x40@2x:80','40x40@3x:120','60x60@2x:120','60x60@3x:180','76x76@1x:76',
                    '76x76@2x:152','83.5x83.5@2x:167','1024x1024@1x:1024')) {
  $name, $px = $spec -split ':'
  [Brand]::FullBleed("$ios/Icon-App-$name.png", [int]$px, 0, $true)
}

# Web: rounded icons, maskable (safe radius 40%) and favicon.
$web = Join-Path $root 'web'
[Brand]::Tile("$web/icons/Icon-192.png", 192, 1.0)
[Brand]::Tile("$web/icons/Icon-512.png", 512, 1.0)
[Brand]::FullBleed("$web/icons/Icon-maskable-192.png", 192, 0.38, $false)
[Brand]::FullBleed("$web/icons/Icon-maskable-512.png", 512, 0.38, $false)
[Brand]::Tile("$web/favicon.png", 32, 1.0)
'done'

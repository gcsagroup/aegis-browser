[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis brand assets

This directory is the current official GCSA-aegis brand delivery package. The editable logo sources are the SVG files. PNG, ICNS, Asset Catalog, and Icon Composer files are platform deliverables or derived artifacts and must not be edited as if they were the logo masters.

Use all colors in sRGB. The current PNG files do not embed an ICC profile; do not convert them to Display P3, CMYK, or another color space when importing them into design or build tools.

## Logo masters

All three SVG files use transparent backgrounds and true vector paths with no embedded bitmap. The shield contains a clear letter G and exactly three network nodes at the left, right, and bottom.

- `svg/gcsa-aegis-logo-color.svg`: the default color version, with a teal-to-blue gradient of `#12CDBF → #13B9D5 → #168FEF`. Use it on light or neutral backgrounds.
- `svg/gcsa-aegis-logo-mono.svg`: the solid deep-navy version in `#0B2538`. Use it for monochrome printing, engraving, templates, and restricted-color environments.
- `svg/gcsa-aegis-logo-reversed.svg`: the solid white reversed version in `#FFFFFF`. Use it on dark, blue, or photographic backgrounds.

Export new sizes from the corresponding SVG; do not upscale low-resolution PNG files. Do not change the number or relative positions of the three nodes, the opening of the G, or the shield proportions, and do not add Google, Chrome, or Chromium visual elements.

## PNG assets

Logo PNG files are divided into `png/logo-color/`, `png/logo-mono/`, and `png/logo-reversed/`. Each group provides these square sizes:

`16, 22, 24, 32, 48, 64, 128, 256, 512, 1024 px`

These logo PNG files are RGBA and their transparent regions must be preserved. Small sizes are intended for menus, toolbars, and status surfaces. Prefer SVG or the 1024px PNG for brand presentation, documentation, or another export pass.

macOS app icons are in `app-icon/macos/png/` and provide:

`16, 24, 32, 48, 64, 128, 192, 256, 512, 1024 px`

The macOS icons are RGBA. Their main tile is already a rounded square and retains transparent outer corners.

The shared full-bleed iOS and iPadOS master is:

`app-icon/ios/gcsa-aegis-app-icon-ios-1024.png`

This file is a `1024 × 1024`, 8-bit RGB square master with no alpha channel and fully opaque corners.

## Using the assets on macOS

### Xcode Asset Catalog

Prefer `macos/Assets.xcassets/`:

1. Merge this Asset Catalog into the macOS target, or merge only its `AppIcon.appiconset`.
2. Point the target's App Icon Set to `AppIcon` in General or Build Settings.
3. Recompile the Asset Catalog with the Xcode/SDK used by the current project; do not edit the generated `Assets.car` by hand.
4. After packaging, inspect `.app/Contents/Resources/Assets.car` and verify the icon in Finder, the Dock, the app switcher, and the About page.

`macos/AppIcon.icon/` is an editable Icon Composer-style package containing `icon.json` and a 1024px layer asset. Use it only when the target Xcode/build chain explicitly supports `.icon` packages.

`macos/Assets.car` is a compiled verification artifact from the current build chain, not a source file that is portable across Xcode versions. Production builds should regenerate it from `Assets.xcassets` or the `.icon` source.

### ICNS or non-Xcode packaging

`macos/GCSA-aegis.icns` can be used by Chromium, scripted packaging, or a macOS bundle that still reads `CFBundleIconFile`:

1. Include the ICNS in the build resources instead of modifying an already signed app.
2. Ensure that `CFBundleIconFile` in `Info.plist` points to the corresponding filename.
3. Rebuild and sign the app, then inspect the actual resource in the final bundle.

The current ICNS unpacks successfully. It contains five base layers at `16, 32, 128, 256, 512 px` and a Retina `@2x` layer for each, for 10 standard representations in total. Modern macOS releases should still prefer recompiling `Assets.car` from the complete `Assets.xcassets` source.

## Using the assets on iOS and iPadOS

1. Import `app-icon/ios/gcsa-aegis-app-icon-ios-1024.png` into the iOS target's `Assets.xcassets/AppIcon.appiconset`.
2. Keep the source full-bleed and fully opaque. Do not manually round the corners, add transparent corners, or wrap it in another rounded-square border.
3. Let Xcode and iOS/iPadOS apply the appropriate system masks on the Home Screen, in Spotlight, in Settings, and on other surfaces.
4. Check the shield, G, and three nodes at real iPhone and iPad AppIcon sizes; do not judge clarity only from the 1024px preview.

### Why the iOS and macOS icons differ

- iOS/iPadOS input must be a full-bleed, fully opaque square that reaches every corner. The system applies the platform mask later; pre-rounded corners cause double shrinking, transparent corners, or exposed edges.
- The current macOS design already contains a rounded square, outer rim, and transparent outer corners. The system does not correct the same full-bleed image for developers in the iOS manner.
- Therefore, do not submit the macOS RGBA icon directly as the iOS AppIcon, and do not use the iOS full-bleed master directly as a finished ICNS file.

## iOS adaptation record

The iOS full-bleed master was adapted with Codex's built-in `imagegen`, using the selected V4 macOS app icon as the edit target. This was not a logo redesign; the edit was limited to the outer app-tile boundary and background extension.

<details>
<summary>Show the final imagegen prompt</summary>

```text
Use case: precise-object-edit.
Asset type: iOS and iPadOS AppIcon 1024×1024 master.
Input image: Image 1 is the approved GCSA-aegis V4 macOS app icon and is the exact visual reference and edit target.

Primary request: create the platform-adapted iOS master by changing only the outer app-tile treatment. Remove the pre-cut rounded-square boundary, transparent corners, outer rounded rim, and any checkerboard. Seamlessly extend the existing deep navy, royal blue, and cyan flowing background all the way to every edge and every square corner so the complete 1024×1024 canvas is fully opaque and full-bleed. iOS will apply its own mask later.

Invariants: preserve the central shield, the capital G, the left/right/bottom exactly three circular nodes, their positions, proportions, luminous white-cyan treatment, shadows, and overall composition as faithfully as possible. Keep exactly three nodes and no extra dots. Keep the same approved blue/cyan palette and flowing background language. The central mark must stay within the same safe area and remain readable at 29–60 px.

Output constraints: one front-facing square icon only; fully opaque RGB image with no alpha; no pre-rounded corners; no inner rounded tile outline; no transparent pixels; no checkerboard; no text; no watermark; no Google or Chrome elements; no extra nodes; no device mockup; no presentation background.
```

</details>

## Completed validation

Validation date: 2026-08-29.

- All three SVG files passed XML parsing and actual rendering with `rsvg-convert`; each contains exactly three nodes and no embedded `<image>` or `data:image` content.
- A total of 61 PNG files were checked. Every filename's declared size matches its actual pixel dimensions; size errors: 0.
- Of those files, 60 are 8-bit RGBA. The only RGB file is the expected 1024px full-bleed iOS/iPadOS master.
- The logo and macOS icon masters have an alpha range of `0–255`; the iOS master has no alpha channel and all four corners contain valid color pixels.
- `Contents.json` and `icon.json` both passed JSON parsing.
- macOS `iconutil` successfully unpacked `GCSA-aegis.icns` into base layers at 16, 32, 128, 256, and 512px plus their Retina `@2x` layers, for 10 representations in total.
- `assetutil` successfully parsed `Assets.car`. The recorded build chain is Xcode 26.6 (17F113) on macOS, with nine AppIcon/Icon renditions. Its file structure is basically valid, but this does not replace recompilation with the target Xcode, final App bundle runtime verification, or signing checks.

These checks show that the current brand package has usable file structure, dimensions, and basic formats. They do not prove completed Chromium integration, iOS real-device validation, macOS signing, notarization, or a production release.

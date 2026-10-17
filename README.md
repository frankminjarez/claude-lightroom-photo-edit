# Claude AI Photo Edit for Lightroom Classic

A Lightroom Classic plug-in that lets you edit photos by describing the look you want in plain language. Claude looks at each photo and its current develop settings, then sets White Balance, Tone, Presence, Tone Curve, HSL, Color Grading and Detail to match your description.

> "moody cinematic with teal shadows and warm highlights"
> "bright airy portrait, lifted blacks, clean whites"

Each edit is written to the photo's develop settings, so it stays non-destructive and can be undone from **Develop ▸ History**.

---

## Features

- **Edit from a text prompt.** Describe the mood, colour palette and contrast, and Claude picks the slider values.
- **Batch editing.** Select any number of photos and the plug-in edits them one after another, with a progress bar you can cancel.
- **Panel control.** Choose which develop panels Claude may change. Panels you leave unchecked are not touched.
- **Uses the current settings.** Claude gets the photo's existing develop settings along with the image, so it builds on edits you've already made instead of starting over.
- **Before → after summary.** When the run finishes, you get a per-photo list of every slider that changed, with old and new values and Claude's explanation of its choices.
- **Prompt history.** Your last 100 prompts are saved and can be picked from a dropdown.
- **Remembered choices.** Your panel selections and last prompt are kept between runs.
- **Safe values.** Every value Claude returns is limited to Lightroom's valid range before it's applied.

## Adjustable panels

| Panel | Settings | On by default |
|---|---|---|
| White Balance | Temperature, Tint | ✅ |
| Basic Tone | Exposure, Contrast, Highlights, Shadows, Whites, Blacks | ✅ |
| Presence | Clarity, Vibrance, Saturation | ✅ |
| Tone Curve | Parametric Shadows, Darks, Lights, Highlights | ✅ |
| HSL Color Mixer | Hue / Saturation / Luminance for all 8 colour channels | ✅ |
| Color Grading | Shadows, Midtones, Highlights hue & saturation; Balance (also writes the Split Toning keys for Lightroom versions before 10) | ✅ |
| Detail | Sharpening (Amount, Radius, Detail, Masking) and Noise Reduction (Luminance & Color) | ⬜ |

## Requirements

- **Adobe Lightroom Classic** (Lightroom SDK 6.0 or later)
- An **Anthropic API key**, available from the [Anthropic Console](https://console.anthropic.com/). API usage is billed to your Anthropic account.
- An internet connection

## Installation

1. Download `ClaudePhotoEdit.lrplugin.zip` from the [Releases](../../releases) page and unzip it, or clone this repository.
2. Find the `ClaudePhotoEdit.lrplugin` folder. On macOS it shows as a single package.
3. In Lightroom Classic, open **File ▸ Plug-in Manager…**
4. Click **Add**, select the `ClaudePhotoEdit.lrplugin` folder, and click **Add Plug-in**.
5. Check that **Claude AI Photo Edit** appears in the list and is enabled.

## Setup

1. Go to **File ▸ Plug-in Extras ▸ Claude Edit Settings…**
2. Enter your Anthropic API key.
3. (Optional) Choose the Claude model and the preview size sent to the API.
4. Click **Test Connection** to check that the key and model work, then click **Save**.

| Setting | Default | Notes |
|---|---|---|
| API key | — | Required. Stored locally in Lightroom's plug-in preferences. |
| Model | `claude-opus-4-5` | Pick from the list or type any Claude model ID that accepts image input. |
| Preview size | `1024` px | Longest side of the preview sent to Claude: 512, 768, 1024, 1568 or 2048 px. Larger previews show more detail but cost more and take longer. |

## Usage

1. In the Library or Develop module, select one or more photos.
2. Choose **File ▸ Plug-in Extras ▸ Edit with Claude AI**.
3. In the dialog:
   - Type a **style prompt**, or pick one from **Recent prompts**. If you leave it blank, the plug-in uses *"Natural and well-balanced"*.
   - Check the **panels Claude may adjust**.
4. Click **Apply Edit**.
5. When the run finishes, read the summary of what changed and why.

To undo, use **Develop ▸ History** or **Edit ▸ Undo**.

### Prompt tips

Describing mood, colour palette and contrast together gives the best results. For example:

- `moody cinematic with teal shadows and warm highlights`
- `bright airy portrait, lifted blacks, clean whites`
- `faded film look, muted greens, soft contrast`
- `punchy landscape, deep blue sky, crisp detail`

## How it works

For each selected photo, the plug-in:

1. Reads the photo's current develop settings.
2. Gets a JPEG preview from Lightroom's preview cache.
3. Sends the preview, a summary of the current settings and your style prompt to the [Anthropic Messages API](https://docs.anthropic.com/en/api/messages). The response format it asks for includes only the panels you checked.
4. Reads the JSON that Claude returns and limits each value to its valid Lightroom range.
5. Applies the new settings in one catalog write (one History step per photo).
6. Adds a before → after summary for the results dialog.

The plug-in is plain Lua 5.1 and needs no external libraries. It includes its own JSON encoder/decoder and Base64 encoder.

### Project layout

```
├── README.md
├── LICENSE
└── ClaudePhotoEdit.lrplugin/
    ├── Info.lua             # Plug-in manifest and menu items
    ├── ClaudeEdit.lua       # Main "Edit with Claude AI" action
    ├── SettingsDialog.lua   # API key / model / preview size settings
    └── json.lua             # Pure-Lua JSON encoder/decoder
```

## Privacy

- Only a **downscaled JPEG preview** of each photo and its develop settings are sent to Anthropic. The original files never leave your computer.
- Your API key is stored in Lightroom's plug-in preferences on your machine.
- See [Anthropic's privacy policy](https://www.anthropic.com/legal/privacy) for how API data is handled.

## Troubleshooting

| Message | Fix |
|---|---|
| **No API key found** | Enter your key in **File ▸ Plug-in Extras ▸ Claude Edit Settings…** |
| **Preview appears stale** | Click another photo, then select this one again and re-run. Or build previews with **Library ▸ Previews ▸ Build Standard-Sized Previews**. |
| **Timed out waiting for preview** | Build previews with **Library ▸ Previews ▸ Build Standard-Sized Previews** and retry. |
| **Preview too large** (over 9 MB or 8000 px) | Lower the thumbnail size in settings, or build standard-sized previews. |
| **API error 401** | The API key is invalid or has been revoked. |
| **API error 429 / 529** | Rate-limited or overloaded. Wait a moment and try again, or edit fewer photos per run. |
| **Could not parse JSON from Claude response** | Rare. Re-run the edit. The plug-in already strips code fences and extra text around the JSON. |

## Contributing

Issues and pull requests are welcome. Please test changes in Lightroom Classic before you open a PR, and keep the code compatible with Lua 5.1.

## License

[MIT](LICENSE)

## Disclaimer

This is an independent project. It is not affiliated with or endorsed by Adobe or Anthropic. Lightroom is a trademark of Adobe Inc.; Claude is a trademark of Anthropic, PBC.

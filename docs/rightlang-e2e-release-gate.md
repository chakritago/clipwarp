# ClipWarp RightLang — Windows Stable Release Gate

**Status:** NOT VERIFIED ON A REAL DESKTOP. Do not mark stable or merge PR #2 on CI alone.

## Reproduce on a Windows 10/11 interactive desktop

1. Install English (US) and Thai Kedmanee keyboard layouts. Clone the PR branch.
2. Open a non-elevated **Windows PowerShell 5.1 STA** window in the repository directory.
3. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1`.
4. Run `powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File .\tests\rightlang-interactive.ps1 -EditorBridge`.
5. Configure experimental editor support and allowlist only for test programs.
6. **Record app version and test observations**, not typed words or clipboard content.
7. Do not approve Stable until all required steps are verified and any failures are fixed.

## Accessibility 3.0, learned words and app-specific policy

Settings offers independent scale values for general UI (10–18), list editors (10–24),
and Before/After preview (10–24). Keyboard paths: **Tab / Shift+Tab** between
fields, **F6** to the tabs, **Ctrl+F** to search learned words, **Delete** to remove
a selected learned word and **Ctrl+S** to save. Check that focused controls remain
visibly outlined with both regular and Windows High Contrast palettes. Settings
use DPI autoscaling, but automated CI cannot simulate a physical monitor transition.

Learning-management search includes contains and starts-with modes. The **ไม่แนะนำ
คำที่เลือก** control adds an individual word to the ignored-suggestions list;
it does not erase a manually defined correction. When using passive suggestions,
the **ไม่แนะนำอีก** action explicitly records an ignored word. Do not log text
content in diagnostic reports.

App-specific rules use `process=mode,hints`. For example, `notepad=manual,off`,
`winword=off,inherit`. Supported `mode` values: `inherit`, `manual`,
`auto`, `off`; `hints`: `inherit`, `on`, `off`. These rules do **not**
grant permission to monitor a process: the explicit allowed/blocked application
lists still apply and **global Off or global hints disabled always wins**.

The interactive test can only attest observations and running process versions.
It does not perform a hidden or simulated physical keyboard run.
Use the emitted `RealDesktopGateSatisfied` flag only alongside manually
reviewed evidence for Word formatting, VS Code provider behavior, full Undo,
Clipboard race cases, and High DPI / High Contrast. It cannot by itself
authorize a Stable release.

## Manual matrix (not satisfied by GitHub Actions)

| Application | Check | Pass requirements |
| --- | --- | --- |
| Windows 11 modern Notepad | TextPattern accessible, selected word, Shift+Caps Lock preview | Preview shows only selected word; Enter changes only selection |
| Windows 10 legacy Notepad | Native Edit fallback, Shift+Backspace, F8 | Text restored only if verified caret context |
| Word desktop (record version) | Uniform bold/italic/font/color selection | Reject uncertain/mixed styles; surrounding text unchanged |
| Word desktop | Text replacement and Ctrl+Z | If supported, original text and its formatting are restored |
| VS Code (record version) | Editor TextPattern exposed or unsupported fallback | Either safely correct selection or decline without editing |
| Each app | Switch window while preview is open | Never change another window |
| Password editor | Attempt all shortcuts | No observation/replacement |
| Every app | Repeat identical wrong word | Cooldown and ignored-word rules respected |
| Every app | Fast typing, mouse click and arrow keys | No stuck keys or long hook stalls |
| Clipboard path | Copy/paste plain text, HTML, images; concurrent clipboard writers | Existing Clipboard operations and ownership invariants intact |
| Accessibility | 700×620 and 930×730 at 100%, 150%, 200% display scale | Controls readable, actionable and navigable with keyboard |
| Accessibility | Dark Mode and Windows High Contrast | Sufficient contrast, no invisible actions, text not clipped |
| Privacy | Learning off and ignored suggestions | No new learned words saved to disk |
| Privacy | Disable feature and privacy pause | No automatic correction or hotkey processing |

## Evidence to attach to PR

- CI run URL for latest commit and counts for PowerShell 5.1 and PowerShell 7.
- Tester-confirmed JSON checklist produced by `rightlang-interactive.ps1`, after reviewing it for privacy.
- Windows and each editor version, keyboard layouts, and observed expected/actual behavior.
- Screenshot proof for formatting checks (no private text).
- Distinguish **NOT TESTED**, **FAILED**, **PASSED** for each app; do not convert unavailable app into a pass.

The UI Automation bridge is deliberately opt-in. Word has a conservative **uniform
formatting fingerprint guard**, which catches some mixed-style selections but **cannot
guarantee that new text inherits every original Word run property**.
Native Undo also depends on each provider's caret text-range support. The app
does not use the clipboard to inspect a rich-text selection.

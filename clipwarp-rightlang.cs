// ClipWarp RightLang-inspired Thai/English keyboard-layout repair.
// This is original code: no RightLang binary, libraries or proprietary resources are used.
// It processes only a bounded in-memory token in explicitly allowed desktop apps.
namespace ClipwarpRightLang
{
    using System;
    using System.Collections.Generic;
    using System.Diagnostics;
    using System.Runtime.InteropServices;
    using System.Text;
    using System.Windows.Forms;
    using System.Drawing;
    public sealed class Engine : IDisposable
    {
        private const int WH_MOUSE_LL = 14, WM_LBUTTONDOWN = 0x0201, WM_RBUTTONDOWN = 0x0204, WM_MBUTTONDOWN = 0x0207;
        private const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;
        private const int VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0D, VK_SPACE = 0x20;
        private const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LEFT = 0x25, VK_RIGHT = 0x27;
        private const int VK_CAPITAL = 0x14, VK_ESCAPE = 0x1B, VK_F8 = 0x77;
        private const int VK_LWIN = 0x5B, VK_RWIN = 0x5C;
        private const uint WM_GETTEXT = 0x000D, WM_GETTEXTLENGTH = 0x000E, EM_GETSEL = 0x00B0, EM_GETPASSWORDCHAR = 0x00D2;
        private const uint SMTO_ABORTIFHUNG = 0x0002, GWL_STYLE = 0xFFFFFFF0, ES_PASSWORD = 0x0020;
        private const uint KEYEVENTF_KEYUP = 2, KEYEVENTF_UNICODE = 4;
        private const uint LLKHF_INJECTED = 0x10;
        private delegate IntPtr KeyboardProc(int code, IntPtr message, IntPtr data);
        private readonly KeyboardProc proc;
        private readonly KeyboardProc mouseProc;
        private IntPtr hook;
        private IntPtr mouseHook;
        private IntPtr previousWindow;
        private string token = "";
        private PreviewRequest pending;
        private UndoRequest lastUndo;
        private PreviewBubble bubble;
        private Timer bubbleTimer;
        private const int MaxText = 4096;
        private const int MaxToken = 64;
        private sealed class PreviewRequest {
            public IntPtr Window, Focus;
            public string Source, Replacement;
            public bool IsSelection;
            public int SelectionStart, SelectionEnd;
            public DateTime Until;
        }
        private sealed class UndoRequest {
            public IntPtr Window, Focus;
            public string Source, Replacement;
            public bool HasTrailingSpace;
            public DateTime Until;
        }
        private sealed class PreviewBubble : Form {
            readonly Label label;
            protected override bool ShowWithoutActivation { get { return true; } }
            protected override CreateParams CreateParams {
                get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x00000080; return p; }
            }
            public PreviewBubble() {
                FormBorderStyle = FormBorderStyle.None;
                ShowInTaskbar = false; TopMost = true; AutoScaleMode = AutoScaleMode.Dpi;
                BackColor = Color.FromArgb(30, 37, 51);
                Size = new Size(380, 110);
                label = new Label { Dock = DockStyle.Fill, ForeColor = Color.White,
                    Font = new Font("Segoe UI", 10.5f), TextAlign = ContentAlignment.MiddleLeft,
                    Padding = new Padding(14), AutoEllipsis = true };
                Controls.Add(label);
            }
            public void Present(string source, string corrected, string command) {
                label.Text = source + "  →  " + corrected + Environment.NewLine + command;
                Point pos = Cursor.Position;
                Rectangle work = Screen.FromPoint(pos).WorkingArea;
                Location = new Point(Math.Min(work.Right - Width, Math.Max(work.Left, pos.X + 12)),
                                     Math.Min(work.Bottom - Height, Math.Max(work.Top, pos.Y + 18)));
                if (!Visible) Show();
                else { TopMost = true; Invalidate(); }
            }
            public void Dismiss() { if (Visible) Hide(); }
        }
        private string mode = "manual";
        private Dictionary<string, string> instant = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> words = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> excluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public bool Installed { get { return hook != IntPtr.Zero; } }

        public Engine() {
            proc = OnKeyboard; mouseProc = OnMouse;
            bubble = new PreviewBubble();
            bubbleTimer = new Timer();
            bubbleTimer.Interval = 250;
            bubbleTimer.Tick += delegate {
                if (pending != null && DateTime.UtcNow > pending.Until) CancelPreview();
                if (lastUndo != null && DateTime.UtcNow > lastUndo.Until) {
                    lastUndo = null;
                    if (pending == null) bubble.Dismiss();
                }
            };
            bubbleTimer.Start();
        }

        public void Configure(string selectedMode, IDictionary<string, string> immediateWords,
                              IEnumerable<string> knownWords, IEnumerable<string> allowedApps,
                              IEnumerable<string> excludedApps)
        {
            string next = selectedMode == "auto" || selectedMode == "manual" ? selectedMode : "off";
            if (next != mode) { token = ""; CancelPreview(); lastUndo = null; }
            mode = next;
            instant = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (immediateWords != null)
                foreach (KeyValuePair<string, string> kv in immediateWords)
                    if (!string.IsNullOrWhiteSpace(kv.Key) && !string.IsNullOrWhiteSpace(kv.Value)
                        && kv.Key.Length <= 64 && kv.Value.Length <= 128)
                        instant[kv.Key] = kv.Value;
            words = MakeSet(knownWords);
            allowed = MakeSet(allowedApps);
            excluded = MakeSet(excludedApps);
        }

        private static HashSet<string> MakeSet(IEnumerable<string> values)
        {
            HashSet<string> set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (values != null)
                foreach (string value in values)
                    if (!string.IsNullOrWhiteSpace(value)) set.Add(value.Trim());
            return set;
        }

        // Application names are normalized by PowerShell before Configure is called;
        // ordinary words must retain their spelling (including trailing letters).
        public void Start()
        {
            if (hook != IntPtr.Zero) return;
            // Fail closed if we cannot reset the word buffer after pointer edits.
            mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, GetModuleHandle(null), 0);
            if (mouseHook == IntPtr.Zero) return;
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero) { UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
        }

        public void Dispose()
        {
            if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
            if (mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
            token = ""; pending = null; lastUndo = null;
            bubbleTimer.Stop(); bubbleTimer.Dispose(); bubble.Dispose();
            GC.KeepAlive(proc);
            GC.KeepAlive(mouseProc);
        }

        public static string ConvertLayout(string input)
        {
            if (string.IsNullOrEmpty(input) || input.Length > 64) return null;
            bool hasThai = false, hasEnglish = false;
            foreach (char c in input)
            {
                if (c >= '\u0E00' && c <= '\u0E7F') hasThai = true;
                else if (c <= 0x7F) hasEnglish = true;
                else return null;
            }
            if (hasThai == hasEnglish) return null; // do not rewrite mixed/unknown scripts
            IntPtr from = LoadKeyboardLayout(hasThai ? "0000041E" : "00000409", 0);
            IntPtr to = LoadKeyboardLayout(hasThai ? "00000409" : "0000041E", 0);
            if (from == IntPtr.Zero || to == IntPtr.Zero) return null;
            StringBuilder result = new StringBuilder();
            foreach (char c in input)
            {
                short key = VkKeyScanEx(c, from);
                if (key == -1) return null;
                uint vk = (uint)(key & 0xff);
                byte[] state = new byte[256];
                if ((key & 0x100) != 0) state[VK_SHIFT] = 0x80;
                if ((key & 0x200) != 0) state[VK_CONTROL] = 0x80;
                if ((key & 0x400) != 0) state[VK_MENU] = 0x80;
                StringBuilder output = new StringBuilder(8);
                int n = ToUnicodeEx(vk, MapVirtualKeyEx(vk, 0, to), state, output, output.Capacity, 0, to);
                if (n != 1) return null; // reject dead keys and multi-codepoint results
                result.Append(output[0]);
            }
            return result.ToString();
        }

        public static bool CanCorrect(string source, string target, bool selected, bool explicitRule, bool knownWord) {
            return !string.IsNullOrEmpty(source) && source.Length >= 2 && source.Length <= MaxToken
                && !string.IsNullOrEmpty(target) && target.Length <= 128 && source != target
                && (selected || explicitRule || knownWord);
        }

        private string ReplacementFor(string source, bool forced) {
            if (string.IsNullOrEmpty(source) || source.Length > MaxToken) return null;
            string correction;
            bool rule = instant.TryGetValue(source, out correction);
            if (!rule) correction = ConvertLayout(source);
            if (!CanCorrect(source, correction, forced, rule, correction != null && words.Contains(correction))) return null;
            return correction;
        }

        private void CancelPreview() {
            pending = null;
            if (lastUndo == null) bubble.Dismiss();
        }

        private bool ShowPreview(string source, string corrected, IntPtr window, IntPtr focus,
                                 bool selection, int start, int end) {
            if (!CanCorrect(source, corrected, true, false, false)) return false;
            pending = new PreviewRequest { Source = source, Replacement = corrected,
                Window = window, Focus = focus, IsSelection = selection,
                SelectionStart = start, SelectionEnd = end,
                Until = DateTime.UtcNow.AddSeconds(6) };
            bubble.Present(source, corrected, "Enter = Apply     Esc = Cancel");
            return true;
        }

        private bool ApplyPreview() {
            PreviewRequest p = pending; pending = null;
            bubble.Dismiss();
            if (p == null || DateTime.UtcNow > p.Until || GetForegroundWindow() != p.Window) return false;
            EditorState check;
            if (!TryReadEditor(p.Window, out check) || check.Focus != p.Focus) return false;
            if (p.IsSelection) {
                if (check.Start != p.SelectionStart || check.End != p.SelectionEnd
                    || check.Text.Substring(check.Start, check.End - check.Start) != p.Source) return false;
                return ReplaceText(p.Source, p.Replacement, p.Window, p.Focus, true);
            }
            // The original token must still appear immediately before the caret.
            if (!IsUndoCandidate(check.Text, check.Start, check.End, p.Source)) return false;
            return ReplaceText(p.Source, p.Replacement, p.Window, p.Focus, false);
        }

        private sealed class EditorState {
            public IntPtr Focus;
            public string Text;
            public int Start, End;
        }
        // Cross-process read is bounded (4 Ki UTF-16 chars), timed out and limited
        // to documented native Edit controls. Never use the clipboard for selection.
        public static bool IsSupportedEditorClass(string name) {
            return !string.IsNullOrEmpty(name) &&
                (name.Equals("Edit", StringComparison.OrdinalIgnoreCase) ||
                 name.StartsWith("WindowsForms10.EDIT.", StringComparison.OrdinalIgnoreCase));
        }
        public static bool IsApplicationEligible(string name, ICollection<string> allowedApps,
                                                 ICollection<string> blockedApps) {
            if (string.IsNullOrEmpty(name) || allowedApps == null || !allowedApps.Contains(name)) return false;
            return blockedApps == null || !blockedApps.Contains(name);
        }
        private static bool TryReadEditor(IntPtr window, out EditorState state) {
            state = null;
            uint pid;
            uint thread = GetWindowThreadProcessId(window, out pid);
            if (thread == 0) return false;
            GUITHREADINFO info = new GUITHREADINFO(); info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
            if (!GetGUIThreadInfo(thread, ref info) || info.hwndFocus == IntPtr.Zero) return false;
            IntPtr focus = info.hwndFocus;
            StringBuilder cls = new StringBuilder(128);
            if (GetClassName(focus, cls, cls.Capacity) < 1) return false;
            string controlClass = cls.ToString();
            if (!IsSupportedEditorClass(controlClass)) return false;
            if ((GetWindowLongPtrSafe(focus, -16).ToInt64() & ES_PASSWORD) != 0) return false;
            IntPtr reply;
            if (SendMessageTimeout(focus, EM_GETPASSWORDCHAR, IntPtr.Zero, IntPtr.Zero,
                                   SMTO_ABORTIFHUNG, 80, out reply) == IntPtr.Zero || reply != IntPtr.Zero) return false;
            if (SendMessageTimeout(focus, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero,
                                   SMTO_ABORTIFHUNG, 80, out reply) == IntPtr.Zero) return false;
            long length = reply.ToInt64();
            if (length < 0 || length > MaxText) return false;
            if (SendMessageTimeout(focus, EM_GETSEL, IntPtr.Zero, IntPtr.Zero,
                                   SMTO_ABORTIFHUNG, 80, out reply) == IntPtr.Zero) return false;
            long packed = reply.ToInt64();
            int start = (int)(packed & 0xffff), end = (int)((packed >> 16) & 0xffff);
            if (end < start || end > length) return false;
            StringBuilder textBuffer = new StringBuilder((int)length + 1);
            if (SendMessageTimeoutText(focus, WM_GETTEXT, new IntPtr(length + 1), textBuffer,
                                       SMTO_ABORTIFHUNG, 80, out reply) == IntPtr.Zero) return false;
            string text = textBuffer.ToString();
            if (text.Length != length) return false;
            state = new EditorState { Focus = focus, Text = text, Start = start, End = end };
            return true;
        }
        private static IntPtr GetWindowLongPtrSafe(IntPtr h, int index) {
            return IntPtr.Size == 8 ? GetWindowLongPtr(h, index) : new IntPtr(GetWindowLong(h, index));
        }
        private bool ShowSelectionPreview(IntPtr window) {
            EditorState e;
            if (!TryReadEditor(window, out e)) return false;
            int count = e.End - e.Start;
            if (count < 2 || count > MaxToken) return false;
            string source = e.Text.Substring(e.Start, count);
            string correction = ReplacementFor(source, true);
            return correction != null && ShowPreview(source, correction, window, e.Focus, true, e.Start, e.End);
        }
        private bool ShowTokenPreview(IntPtr window) {
            string correction = ReplacementFor(token, true);
            if (correction == null) return false;
            EditorState e;
            if (!TryReadEditor(window, out e) || !IsUndoCandidate(e.Text, e.Start, e.End, token)) return false;
            return ShowPreview(token, correction, window, e.Focus, false, e.Start, e.End);
        }
        private bool ReplaceText(string source, string replacement, IntPtr window, IntPtr focus, bool selection, bool trailingSpace = false) {
            if (GetForegroundWindow() != window) return false;
            List<INPUT> events = new List<INPUT>();
            if (!selection)
                for (int i = 0; i < source.Length; i++) {
                    events.Add(Key(VK_BACK, 0, 0)); events.Add(Key(VK_BACK, 0, KEYEVENTF_KEYUP));
                }
            foreach (char c in replacement) {
                events.Add(Key(0, c, KEYEVENTF_UNICODE));
                events.Add(Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
            INPUT[] keys = events.ToArray();
            if (SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT))) != keys.Length) {
                token = ""; lastUndo = null; return false;
            }
            token = "";
            lastUndo = new UndoRequest { Window = window, Focus = focus, Source = source,
                Replacement = replacement, HasTrailingSpace = trailingSpace,
                Until = DateTime.UtcNow.AddSeconds(8) };
            bubble.Present(source, replacement, "Applied ✓    F8 = Undo (8s)");
            return true;
        }
        public static bool IsUndoCandidate(string text, int selectionStart, int selectionEnd, string replacement) {
            return !string.IsNullOrEmpty(text) && !string.IsNullOrEmpty(replacement) &&
                replacement.Length <= 128 && selectionStart == selectionEnd &&
                selectionStart >= replacement.Length && selectionStart <= text.Length &&
                string.Equals(text.Substring(selectionStart - replacement.Length, replacement.Length),
                              replacement, StringComparison.Ordinal);
        }
        private bool UndoLast(IntPtr window) {
            UndoRequest last = lastUndo;
            if (last == null || DateTime.UtcNow > last.Until || last.Window != window) return false;
            EditorState e;
            if (!TryReadEditor(window, out e) || e.Focus != last.Focus || e.Start != e.End) {
                lastUndo = null; bubble.Dismiss(); return false;
            }
            int effectiveCaret = e.Start;
            if (last.HasTrailingSpace) {
                if (effectiveCaret < 1 || e.Text[effectiveCaret - 1] != ' ') {
                    lastUndo = null; bubble.Dismiss(); return false;
                }
                effectiveCaret--;
            }
            if (!IsUndoCandidate(e.Text, effectiveCaret, effectiveCaret, last.Replacement)) {
                lastUndo = null; bubble.Dismiss(); return false;
            }
            lastUndo = null;
            bubble.Dismiss();
            List<INPUT> events = new List<INPUT>();
            if (last.HasTrailingSpace) {
                events.Add(Key(VK_LEFT, 0, 0)); events.Add(Key(VK_LEFT, 0, KEYEVENTF_KEYUP));
            }
            for (int i = 0; i < last.Replacement.Length; i++) {
                events.Add(Key(VK_BACK, 0, 0)); events.Add(Key(VK_BACK, 0, KEYEVENTF_KEYUP));
            }
            foreach (char c in last.Source) {
                events.Add(Key(0, c, KEYEVENTF_UNICODE));
                events.Add(Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
            if (last.HasTrailingSpace) {
                events.Add(Key(VK_RIGHT, 0, 0)); events.Add(Key(VK_RIGHT, 0, KEYEVENTF_KEYUP));
            }
            INPUT[] keys = events.ToArray();
            token = "";
            return SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT))) == keys.Length;
        }

        private IntPtr OnMouse(int code, IntPtr message, IntPtr data)
        {
            if (code >= 0)
            {
                int msg = message.ToInt32();
                if (msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN || msg == WM_MBUTTONDOWN)
                { token = ""; lastUndo = null; CancelPreview(); }
            }
            return CallNextHookEx(mouseHook, code, message, data);
        }

        private IntPtr OnKeyboard(int code, IntPtr message, IntPtr data)
        {
            if (code < 0 || (message.ToInt32() != WM_KEYDOWN && message.ToInt32() != WM_SYSKEYDOWN))
                return CallNextHookEx(hook, code, message, data);
            KBDLLHOOKSTRUCT entry = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(data, typeof(KBDLLHOOKSTRUCT));
            if ((entry.flags & LLKHF_INJECTED) != 0) return CallNextHookEx(hook, code, message, data);
            try
            {
                if (mode == "off") { token = ""; CancelPreview(); lastUndo = null; return CallNextHookEx(hook, code, message, data); }
                IntPtr window = GetForegroundWindow();
                if (window != previousWindow) { token = ""; CancelPreview(); lastUndo = null; previousWindow = window; }
                uint pid;
                uint thread = GetWindowThreadProcessId(window, out pid);
                string processName;
                try { processName = Process.GetProcessById((int)pid).ProcessName; }
                catch { token = ""; return CallNextHookEx(hook, code, message, data); }
                if (!IsApplicationEligible(processName, allowed, excluded))
                { token = ""; CancelPreview(); lastUndo = null; return CallNextHookEx(hook, code, message, data); }
                int vk = (int)entry.vkCode;
                bool ctrl = KeyHeld(VK_CONTROL), alt = KeyHeld(VK_MENU), shift = KeyHeld(VK_SHIFT);
                if (pending != null && DateTime.UtcNow > pending.Until) CancelPreview();
                if (pending != null) {
                    if (vk == VK_ESCAPE) { CancelPreview(); token = ""; return new IntPtr(1); }
                    if (vk == VK_RETURN && !ctrl && !alt && !shift) {
                        ApplyPreview(); return new IntPtr(1);
                    }
                    if (vk != VK_SHIFT && vk != VK_CONTROL && vk != VK_MENU && vk != VK_CAPITAL) {
                        CancelPreview();
                        token = "";
                    }
                }
                if (vk == VK_F8 && !ctrl && !alt && !shift && lastUndo != null) {
                    bool undone = UndoLast(window);
                    if (undone) return new IntPtr(1);
                }
                if (ctrl && vk == VK_CAPITAL && !alt)
                {
                    mode = mode == "auto" ? "manual" : "auto";
                    token = "";
                    if (ModeToggled != null) ModeToggled(mode);
                    return new IntPtr(1);
                }
                if (shift && vk == VK_CAPITAL && !ctrl && !alt) {
                    if (ShowSelectionPreview(window)) { token = ""; return new IntPtr(1); }
                }
                if ((shift && vk == VK_BACK && !ctrl && !alt) ||
                    (ctrl && alt && vk == (int)'R')) {
                    if (ShowTokenPreview(window)) return new IntPtr(1);
                    return CallNextHookEx(hook, code, message, data);
                }
                if (vk != VK_SHIFT && vk != VK_CONTROL && vk != VK_MENU && vk != VK_CAPITAL
                    && vk != VK_F8) { lastUndo = null; if (pending == null) bubble.Dismiss(); }
                if (ctrl || alt || KeyHeld(VK_LWIN) || KeyHeld(VK_RWIN))
                { token = ""; return CallNextHookEx(hook, code, message, data); }
                if (vk == VK_BACK)
                {
                    if (token.Length > 0) token = token.Substring(0, token.Length - 1);
                }
                else if (vk == VK_SPACE || vk == VK_RETURN || vk == VK_TAB)
                {
                    if (mode == "auto" && vk == VK_SPACE) ReplaceToken(false, window);
                    token = "";
                }
                else if (vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU || vk == VK_CAPITAL) { }
                else if (vk == 0x25 || vk == 0x26 || vk == 0x27 || vk == 0x28 ||
                         vk == 0x24 || vk == 0x23 || vk == 0x2D || vk == 0x2E || vk == 0x1B)
                    token = "";
                else
                {
                    byte[] state = new byte[256];
                    if (shift) state[VK_SHIFT] = 0x80;
                    if ((GetKeyState(VK_CAPITAL) & 1) != 0) state[VK_CAPITAL] = 1;
                    StringBuilder result = new StringBuilder(8);
                    IntPtr layout = GetKeyboardLayout(thread);
                    int n = ToUnicodeEx(entry.vkCode, entry.scanCode, state, result, result.Capacity, 0, layout);
                    if (n == 1 && !char.IsControl(result[0]))
                        token = (token + result[0]);
                    else token = "";
                    if (token.Length > 64) token = "";
                }
            }
            catch { token = ""; } // never block the originating keystroke if inspection fails
            return CallNextHookEx(hook, code, message, data);
        }

        public event Action<string> ModeToggled;

        private bool ReplaceToken(bool forced, IntPtr window) {
            string replacement = ReplacementFor(token, forced);
            if (replacement == null) return false;
            EditorState e;
            if (!TryReadEditor(window, out e) ||
                !IsUndoCandidate(e.Text, e.Start, e.End, token)) return false;
            return ReplaceText(token, replacement, window, e.Focus, false, true);
        }

        private static INPUT Key(int vk, char scan, uint flags)
        {
            INPUT i = new INPUT(); i.type = 1;
            i.ki.wVk = (ushort)vk; i.ki.wScan = scan;
            i.ki.dwFlags = flags;
            return i;
        }

        private static bool KeyHeld(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

        [StructLayout(LayoutKind.Sequential)]
        private struct GUITHREADINFO {
            public int cbSize; public uint flags;
            public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
            public RECT rcCaret;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int left, top, right, bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT { public uint type; public KEYBDINPUT ki; }

        [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr handle, StringBuilder name, int count);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong(IntPtr h, int index);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr h, uint message, IntPtr w, IntPtr l,
                                                         uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
        private static extern IntPtr SendMessageTimeoutText(IntPtr h, uint message, IntPtr w, StringBuilder text,
                                                             uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadKeyboardLayout(string layout, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern short VkKeyScanEx(char ch, IntPtr layout);
        [DllImport("user32.dll")]
        private static extern uint MapVirtualKeyEx(uint code, uint mapType, IntPtr layout);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ToUnicodeEx(uint vk, uint scan, byte[] keys, StringBuilder result, int size, uint flags, IntPtr layout);
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] private static extern short GetKeyState(int vk);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int id, KeyboardProc callback, IntPtr module, uint thread);
        [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr handle);
        [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr handle, int code, IntPtr msg, IntPtr data);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto)] private static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint n, INPUT[] inputs, int size);
    }
}

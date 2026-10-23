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
    using System.Threading;
    using System.Windows.Forms;
    using System.Drawing;

    public enum EditorTransactionState {
        PreflightRejected, NoInput, PartialInput, InputSentUnverified, Committed,
        UndoRejected, UndoSentUnverified, Restored
    }
    public sealed class EditorTransactionResult {
        public EditorTransactionState State { get; private set; }
        public int ExpectedInputEvents { get; private set; }
        public int SentInputEvents { get; private set; }
        public bool CanOfferUndo { get; private set; }
        public bool RequiresRecovery { get; private set; }
        public string Status { get; private set; }
        public EditorTransactionResult(EditorTransactionState state, int expected, int sent,
                                       bool canUndo, bool recovery, string status) {
            State=state; ExpectedInputEvents=expected; SentInputEvents=sent;
            CanOfferUndo=canUndo; RequiresRecovery=recovery; Status=status;
        }
    }
    public sealed class Engine : IDisposable
    {
        private const int WH_MOUSE_LL = 14, WM_LBUTTONDOWN = 0x0201, WM_RBUTTONDOWN = 0x0204, WM_MBUTTONDOWN = 0x0207;
        private const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;
        private const int VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0D, VK_SPACE = 0x20;
        private const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LEFT = 0x25, VK_RIGHT = 0x27;
        private const int VK_CAPITAL = 0x14, VK_ESCAPE = 0x1B, VK_F8 = 0x77;
        private const int VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_Z = 0x5A;
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
        private bool editorBridgeEnabled = false;
        private bool learnAccepted = false;
        private bool smartSuggestions = false;
        private bool keepUndoHistory = false;
        private Dictionary<string,string> applicationPolicies = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        public event Action<string> SuggestionIgnored;
        private DateTime lastTypedAt = DateTime.MinValue;
        private string lastHint = "";
        private int suggestionDelayMs = 650;
        private int suggestionCooldownMs = 5000;
        private readonly Dictionary<string, DateTime> hintShown = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> ignoredHints = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public sealed class UndoHistoryEntry {
            public DateTime WhenUtc { get; set; }
            public string Application { get; set; }
            public string Source { get; set; }
            public string Replacement { get; set; }
            public string EditorKind { get; set; }
            public string Status { get; set; }
        }
        private readonly List<string> recentCorrections = new List<string>();
        private readonly List<UndoHistoryEntry> historyDetails = new List<UndoHistoryEntry>();
        public string[] RecentCorrections { get { return recentCorrections.ToArray(); } }
        public UndoHistoryEntry[] RecentUndoDetails { get { return historyDetails.ToArray(); } }
        public void ClearRecentCorrections() { recentCorrections.Clear(); historyDetails.Clear(); }
        private UndoHistoryEntry Remember(string source, string target, IntPtr window, bool rich) {
            if (!keepUndoHistory) return null;
            string application = "unknown";
            try {
                uint pid; GetWindowThreadProcessId(window, out pid);
                if (pid > 0) application = Process.GetProcessById((int)pid).ProcessName;
            } catch { }
            UndoHistoryEntry record = new UndoHistoryEntry {
                WhenUtc = DateTime.UtcNow, Application = application,
                Source = source, Replacement = target,
                EditorKind = rich ? "UI Automation" : "Native Edit",
                Status = rich ? "Input sent; awaiting editor verification" : "Applied"
            };
            historyDetails.Insert(0, record);
            if (historyDetails.Count > 6) historyDetails.RemoveAt(6);
            recentCorrections.Insert(0, "[" + application + "] " + source + " → " + target);
            if (recentCorrections.Count > 6) recentCorrections.RemoveAt(6);
            return record;
        }
        private int bridgeSerial;
        private int bridgeBusy;
        private PreviewRequest pending;
        private UndoRequest lastUndo;
        private PreviewBubble bubble;
        private System.Windows.Forms.Timer bubbleTimer;
        private const int MaxText = 4096;
        private const int MaxToken = 64;
        private sealed class PreviewRequest {
            public IntPtr Window, Focus;
            public string Source, Replacement;
            public bool IsSelection;
            public bool Passive;
            public int SelectionStart, SelectionEnd;
            public DateTime Until;
            public EditorSnapshot Bridge;
        }
        private sealed class UndoRequest {
            public IntPtr Window, Focus;
            public string Source, Replacement;
            public bool HasTrailingSpace;
            public EditorSnapshot Bridge;
            public UndoHistoryEntry History;
            public DateTime Until;
        }
        private sealed class PreviewBubble : Form {
            readonly Label label;
            readonly Button apply, cancel, undo, ignore;
            public event Action ApplyClicked, CancelClicked, UndoClicked, IgnoreClicked;
            protected override bool ShowWithoutActivation { get { return true; } }
            protected override CreateParams CreateParams {
                get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x00000080; return p; }
            }
            public PreviewBubble() {
                FormBorderStyle = FormBorderStyle.None;
                ShowInTaskbar = false; TopMost = true; AutoScaleMode = AutoScaleMode.Dpi;
                BackColor = Color.FromArgb(28, 36, 51); Size = new Size(404, 126);
                label = new Label { ForeColor = Color.White,
                    Font = new Font("Segoe UI", 10.5f), Location = new Point(13, 10),
                    Size = new Size(376, 53), AutoEllipsis = true };
                Controls.Add(label);
                apply = ActionButton("ใช้คำนี้", 12);
                cancel = ActionButton("ยกเลิก", 145);
                undo = ActionButton("↶ ย้อนกลับ", 12);
                ignore = ActionButton("ไม่แนะนำอีก", 278);
                apply.Click += delegate { if (ApplyClicked != null) ApplyClicked(); };
                cancel.Click += delegate { if (CancelClicked != null) CancelClicked(); };
                undo.Click += delegate { if (UndoClicked != null) UndoClicked(); };
                ignore.Click += delegate { if (IgnoreClicked != null) IgnoreClicked(); };
            }
            private Button ActionButton(string title, int x) {
                Button button = new Button { Text = title, Location = new Point(x, 75),
                    Size = new Size(125, 35), FlatStyle = FlatStyle.Flat,
                    BackColor = Color.FromArgb(48, 69, 96), ForeColor = Color.White };
                button.FlatAppearance.BorderSize = 0; Controls.Add(button); return button;
            }
            public void PresentStatus(string message) {
                label.Text = message;
                apply.Visible = cancel.Visible = undo.Visible = ignore.Visible = false;
                Point pos = Cursor.Position;
                Rectangle work = Screen.FromPoint(pos).WorkingArea;
                Location = new Point(Math.Min(work.Right - Width, Math.Max(work.Left, pos.X + 12)),
                                     Math.Min(work.Bottom - Height, Math.Max(work.Top, pos.Y + 18)));
                if (!Visible) Show(); else { TopMost = true; Invalidate(); }
            }
            public void Present(string source, string corrected, bool isUndo, bool passive = false) {
                label.Text = source + "  →  " + corrected +
                    Environment.NewLine + (isUndo ? "F8 / คลิกเพื่อย้อนกลับ (8 วินาที)" :
                        passive ? "คำแนะนำ · คลิกใช้คำนี้ หรือพิมพ์ต่อเพื่อข้าม" :
                                  "Enter = ยืนยัน    Esc = ยกเลิก (6 วินาที)");
                apply.Visible = cancel.Visible = !isUndo;
                ignore.Visible = passive && !isUndo;
                undo.Visible = isUndo;
                Point pos = Cursor.Position;
                Rectangle work = Screen.FromPoint(pos).WorkingArea;
                Location = new Point(Math.Min(work.Right - Width, Math.Max(work.Left, pos.X + 12)),
                                     Math.Min(work.Bottom - Height, Math.Max(work.Top, pos.Y + 18)));
                if (!Visible) Show(); else { TopMost = true; Invalidate(); }
            }
            public void Dismiss() { if (Visible) Hide(); }
        }
        private string mode = "manual";
        private Dictionary<string, string> instant = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> words = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> excluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private DateTime statusUntil = DateTime.MinValue;
        public bool Installed { get { return hook != IntPtr.Zero; } }

        public static EditorTransactionResult EvaluateInputTransaction(int expectedEvents, int sentEvents, bool postconditionVerified) {
            if (expectedEvents <= 0 || sentEvents <= 0)
                return new EditorTransactionResult(EditorTransactionState.NoInput, expectedEvents, Math.Max(0,sentEvents),
                    false, false, "No input events accepted");
            if (sentEvents != expectedEvents)
                return new EditorTransactionResult(EditorTransactionState.PartialInput, expectedEvents, sentEvents,
                    false, true, "Partial input; inspect the editor before continuing");
            if (!postconditionVerified)
                return new EditorTransactionResult(EditorTransactionState.InputSentUnverified, expectedEvents, sentEvents,
                    false, true, "Input sent; editor result could not be verified");
            return new EditorTransactionResult(EditorTransactionState.Committed, expectedEvents, sentEvents,
                true, false, "Committed; editor content verified");
        }
        public static EditorTransactionResult EvaluateUndoTransaction(bool inputSent, bool restoredVerified) {
            if (!inputSent)
                return new EditorTransactionResult(EditorTransactionState.UndoRejected, 1, 0,
                    false, true, "Undo input was rejected; inspect the editor");
            if (!restoredVerified)
                return new EditorTransactionResult(EditorTransactionState.UndoSentUnverified, 1, 1,
                    false, true, "Undo sent; restoration could not be verified");
            return new EditorTransactionResult(EditorTransactionState.Restored, 1, 1,
                false, false, "Undo completed; editor content verified");
        }
        public static bool IsExpectedTextAfterReplacement(string original, string source, string replacement,
                                                          int start, int end, bool trailingSpace, string actual) {
            if (original == null || actual == null || string.IsNullOrEmpty(source) ||
                string.IsNullOrEmpty(replacement) || start < 0 || end < start || end > original.Length ||
                start > original.Length - source.Length || end - start != source.Length ||
                !string.Equals(original.Substring(start, source.Length), source, StringComparison.Ordinal))
                return false;
            string expected = original.Substring(0,start) + replacement +
                (trailingSpace ? " " : "") + original.Substring(end);
            return string.Equals(expected,actual,StringComparison.Ordinal);
        }

        public Engine() {
            proc = OnKeyboard; mouseProc = OnMouse;
            bubble = new PreviewBubble();
            // A hidden handle is required before STA workers can post BeginInvoke.
            IntPtr uiHandle = bubble.Handle;
            bubble.ApplyClicked += delegate { ApplyPreview(); };
            bubble.CancelClicked += delegate { CancelPreview(); token = ""; };
            bubble.IgnoreClicked += delegate { IgnorePendingSuggestion(); };
            bubble.UndoClicked += delegate { if (lastUndo != null) UndoLast(lastUndo.Window); };
            bubbleTimer = new System.Windows.Forms.Timer();
            bubbleTimer.Interval = 250;
            bubbleTimer.Tick += delegate {
                if (statusUntil != DateTime.MinValue && DateTime.UtcNow > statusUntil) {
                    statusUntil = DateTime.MinValue;
                    if (pending == null && lastUndo == null) bubble.Dismiss();
                }
                if (pending != null && DateTime.UtcNow > pending.Until) CancelPreview();
                if (lastUndo != null && DateTime.UtcNow > lastUndo.Until) {
                    lastUndo = null;
                    if (pending == null) bubble.Dismiss();
                }
                CheckSmartSuggestion();
            };
            bubbleTimer.Start();
        }

        public void Configure(string selectedMode, IDictionary<string, string> immediateWords,
                              IEnumerable<string> knownWords, IEnumerable<string> allowedApps,
                              IEnumerable<string> excludedApps) {
            Configure(selectedMode, immediateWords, knownWords, allowedApps, excludedApps, false, false, false, false, 650, 5000, null);
        }
        public void Configure(string selectedMode, IDictionary<string, string> immediateWords,
                              IEnumerable<string> knownWords, IEnumerable<string> allowedApps,
                              IEnumerable<string> excludedApps, bool enableEditorBridge, bool learnOnConfirm) {
            Configure(selectedMode, immediateWords, knownWords, allowedApps, excludedApps,
                      enableEditorBridge, learnOnConfirm, false, false, 650, 5000, null);
        }
        public void Configure(string selectedMode, IDictionary<string, string> immediateWords,
                              IEnumerable<string> knownWords, IEnumerable<string> allowedApps,
                              IEnumerable<string> excludedApps, bool enableEditorBridge, bool learnOnConfirm,
                              bool enableHints, bool enableHistory)
        {
            Configure(selectedMode, immediateWords, knownWords, allowedApps, excludedApps,
                      enableEditorBridge, learnOnConfirm, enableHints, enableHistory, 650, 5000, null);
        }
        public void Configure(string selectedMode, IDictionary<string, string> immediateWords,
                              IEnumerable<string> knownWords, IEnumerable<string> allowedApps,
                              IEnumerable<string> excludedApps, bool enableEditorBridge, bool learnOnConfirm,
                              bool enableHints, bool enableHistory, int delayMs, int cooldownMs,
                              IEnumerable<string> ignoredWords)
        {
            Configure(selectedMode, immediateWords, knownWords, allowedApps, excludedApps,
                      enableEditorBridge, learnOnConfirm, enableHints, enableHistory,
                      delayMs, cooldownMs, ignoredWords, null);
        }
        public void Configure(string selectedMode, IDictionary<string, string> immediateWords,
                              IEnumerable<string> knownWords, IEnumerable<string> allowedApps,
                              IEnumerable<string> excludedApps, bool enableEditorBridge, bool learnOnConfirm,
                              bool enableHints, bool enableHistory, int delayMs, int cooldownMs,
                              IEnumerable<string> ignoredWords, IDictionary<string,string> appRules)
        {
            string next = selectedMode == "auto" || selectedMode == "manual" ? selectedMode : "off";
            if (next != mode) { token = ""; Interlocked.Increment(ref bridgeSerial); CancelPreview(); lastUndo = null; }
            mode = next;
            editorBridgeEnabled = enableEditorBridge;
            learnAccepted = learnOnConfirm;
            smartSuggestions = enableHints;
            suggestionDelayMs = Math.Max(350, Math.Min(2000, delayMs));
            suggestionCooldownMs = Math.Max(500, Math.Min(120000, cooldownMs));
            ignoredHints = MakeSet(ignoredWords);
            applicationPolicies = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            if (appRules != null) foreach (KeyValuePair<string,string> entry in appRules) {
                if (string.IsNullOrWhiteSpace(entry.Key) || string.IsNullOrWhiteSpace(entry.Value)) continue;
                string key = entry.Key.Trim().ToLowerInvariant();
                if (!IsApplicationEligible(key, MakeSet(allowedApps), MakeSet(excludedApps))) continue;
                if (IsValidPolicy(entry.Value)) applicationPolicies[key] = entry.Value.Trim().ToLowerInvariant();
            }
            if (!enableHints || next == "off") { hintShown.Clear(); lastHint = ""; }
            keepUndoHistory = enableHistory;
            if (!enableHistory || next == "off") ClearRecentCorrections();
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
            token = ""; pending = null; lastUndo = null; ClearRecentCorrections(); hintShown.Clear();
            Interlocked.Increment(ref bridgeSerial);
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

        private void IgnorePendingSuggestion() {
            if (pending == null || !pending.Passive) return;
            string ignored = pending.Source;
            if (string.IsNullOrEmpty(ignored) || ignored.Length > MaxToken) return;
            ignoredHints.Add(ignored);
            CancelPreview();
            if (SuggestionIgnored != null) {
                try { SuggestionIgnored(ignored); } catch { }
            }
        }
        private void CancelPreview() {
            pending = null;
            if (lastUndo == null) bubble.Dismiss();
        }
        public static bool ShouldSuggest(string typed, bool enabled, bool ignored,
                                         int delayMs, double idleMs, double elapsedSincePreviousMs) {
            return enabled && !ignored && !string.IsNullOrEmpty(typed)
                && typed.Length >= 2 && typed.Length <= 64
                && idleMs >= Math.Max(350,Math.Min(2000,delayMs))
                && elapsedSincePreviousMs >= 500;
        }
        public static bool IsValidPolicy(string policy) {
            if (string.IsNullOrEmpty(policy)) return false;
            string[] flags = policy.Trim().ToLowerInvariant().Split(',');
            if (flags.Length != 2) return false;
            return (flags[0] == "inherit" || flags[0] == "manual" || flags[0] == "auto" || flags[0] == "off") &&
                   (flags[1] == "inherit" || flags[1] == "on" || flags[1] == "off");
        }
        public static string ResolveAppMode(string globalMode, string process, IDictionary<string,string> rules) {
            if (globalMode == "off") return "off"; // global safety switch always wins
            string rule;
            if (rules == null || string.IsNullOrEmpty(process) || !rules.TryGetValue(process, out rule) ||
                !IsValidPolicy(rule)) return globalMode;
            string requested = rule.Split(',')[0].Trim().ToLowerInvariant();
            return requested == "inherit" ? globalMode : requested;
        }
        public static bool ResolveAppHints(bool globalEnabled, string process, IDictionary<string,string> rules) {
            if (!globalEnabled) return false; // per-app setting never overrides global privacy choice
            string rule;
            if (rules == null || string.IsNullOrEmpty(process) || !rules.TryGetValue(process, out rule) ||
                !IsValidPolicy(rule)) return globalEnabled;
            return rule.Split(',')[1].Trim().ToLowerInvariant() != "off";
        }
        private void CheckSmartSuggestion() {
            // Passive hints never capture Enter or auto-edit text. Only show
            // suggestions for a verified native Edit field after typing stops.
            if (mode == "off" || pending != null || lastUndo != null ||
                token == lastHint || ignoredHints.Contains(token)) return;
            DateTime now = DateTime.UtcNow;
            DateTime previous;
            double elapsed = hintShown.TryGetValue(token, out previous) ?
                (now - previous).TotalMilliseconds : Double.MaxValue;
            if (!ShouldSuggest(token, smartSuggestions, ignoredHints.Contains(token),
                               suggestionDelayMs, (now - lastTypedAt).TotalMilliseconds,
                               elapsed) || elapsed < suggestionCooldownMs) return;
            IntPtr window = GetForegroundWindow();
            if (window == IntPtr.Zero || window != previousWindow) return;
            uint pid; GetWindowThreadProcessId(window, out pid);
            string processName;
            try { processName = Process.GetProcessById((int)pid).ProcessName; }
            catch { return; }
            if (!IsApplicationEligible(processName, allowed, excluded) ||
                ResolveAppMode(mode, processName, applicationPolicies) != "manual" ||
                !ResolveAppHints(smartSuggestions, processName, applicationPolicies)) return;
            string correction = ReplacementFor(token, false);
            if (correction == null) return;
            EditorState editor;
            if (!TryReadEditor(window, out editor) ||
                !IsUndoCandidate(editor.Text, editor.Start, editor.End, token)) return;
            if (hintShown.Count >= 128) hintShown.Clear();
            hintShown[token] = now;
            lastHint = token;
            ShowPreview(token, correction, window, editor.Focus, false,
                        editor.Start, editor.End, null, true);
        }

        private void ShowStatus(string message, int durationMs = 4500) {
            statusUntil = DateTime.UtcNow.AddMilliseconds(Math.Max(1500,Math.Min(8000,durationMs)));
            bubble.PresentStatus(message);
        }
        private bool ShowPreview(string source, string corrected, IntPtr window, IntPtr focus,
                                 bool selection, int start, int end, EditorSnapshot bridge = null, bool passive = false) {
            if (!CanCorrect(source, corrected, true, false, false)) return false;
            pending = new PreviewRequest { Source = source, Replacement = corrected,
                Window = window, Focus = focus, IsSelection = selection, Passive = passive,
                SelectionStart = start, SelectionEnd = end, Bridge = bridge,
                Until = DateTime.UtcNow.AddSeconds(6) };
            bubble.Present(source, corrected, false, passive);
            return true;
        }

        private bool QueueBridgeSelection(IntPtr window, string processName) {
            if (Interlocked.CompareExchange(ref bridgeBusy, 1, 0) != 0) return false;
            int serial = Interlocked.Increment(ref bridgeSerial);
            Thread worker = new Thread(delegate() {
                EditorSnapshot snapshot = null;
                string correction = null;
                try {
                    if (EditorBridge.TrySelected(window, processName, out snapshot))
                        correction = ReplacementFor(snapshot.SelectedText, true);
                } catch { }
                finally { Interlocked.Exchange(ref bridgeBusy, 0); }
                if (snapshot == null || correction == null) return;
                try {
                    bubble.BeginInvoke((MethodInvoker)delegate {
                        if (serial != bridgeSerial || mode == "off" ||
                            GetForegroundWindow() != window || !editorBridgeEnabled) return;
                        ShowPreview(snapshot.SelectedText, correction, window, IntPtr.Zero, true, -1, -1, snapshot);
                    });
                } catch { }
            });
            worker.IsBackground = true;
            worker.SetApartmentState(System.Threading.ApartmentState.STA);
            worker.Start();
            return true;
        }
        private static bool InjectBridgeSelection(string replacement) {
            List<INPUT> events = new List<INPUT>();
            foreach (char ch in replacement) {
                events.Add(Key(0, ch, KEYEVENTF_UNICODE));
                events.Add(Key(0, ch, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
            INPUT[] keys = events.ToArray();
            return keys.Length > 0 &&
                SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT))) == keys.Length;
        }
        private void ApplyBridgePreview(PreviewRequest p) {
            if (p == null || p.Bridge == null || Interlocked.CompareExchange(ref bridgeBusy,1,0) != 0) return;
            int serial = Interlocked.Increment(ref bridgeSerial);
            Thread worker = new Thread(delegate() {
                bool sent = false;
                bool verified = false;
                try {
                    if (DateTime.UtcNow <= p.Until && serial == bridgeSerial &&
                        EditorBridge.SameSelection(p.Window,p.Bridge) && GetForegroundWindow() == p.Window) {
                        sent = InjectBridgeSelection(p.Replacement);
                        if (sent) {
                            // Accessibility providers update asynchronously after SendInput.
                            // Verify the editor's actual caret text before offering native Undo.
                            Thread.Sleep(100);
                            verified = EditorBridge.MatchesCaretTail(p.Window,p.Bridge,p.Replacement);
                        }
                    }
                } catch { }
                finally { Interlocked.Exchange(ref bridgeBusy,0); }
                if (!sent) return;
                bool verifiedCopy = verified;
                try { bubble.BeginInvoke((MethodInvoker)delegate {
                    if (serial != bridgeSerial) return;
                    token = "";
                    lastUndo = verifiedCopy ? new UndoRequest { Window = p.Window, Focus = IntPtr.Zero,
                        Source = p.Source, Replacement = p.Replacement, Bridge = p.Bridge,
                        Until = DateTime.UtcNow.AddSeconds(8) } : null;
                    UndoHistoryEntry entry = Remember(p.Source,p.Replacement,p.Window,true);
                    if (entry != null) entry.Status = verifiedCopy ?
                        "Inserted and caret verified; Undo eligible" :
                        "Input sent; editor result not verified (Undo unavailable)";
                    if (lastUndo != null) {
                        lastUndo.History = entry;
                        bubble.Present(p.Source,p.Replacement,true);
                    } else bubble.Dismiss();
                    if (learnAccepted && verifiedCopy && CorrectionAccepted != null) {
                        try { CorrectionAccepted(p.Source,p.Replacement); } catch { }
                    }
                }); } catch { }
            });
            worker.IsBackground=true;
            worker.SetApartmentState(System.Threading.ApartmentState.STA);
            worker.Start();
        }
        private void UndoBridge(UndoRequest last) {
            if (last == null || last.Bridge == null || Interlocked.CompareExchange(ref bridgeBusy,1,0) != 0) return;
            int serial = Interlocked.Increment(ref bridgeSerial);
            Thread worker = new Thread(delegate() {
                try {
                    if (serial != bridgeSerial || GetForegroundWindow() != last.Window ||
                        !EditorBridge.MatchesCaretTail(last.Window,last.Bridge,last.Replacement)) return;
                    INPUT[] undo = new INPUT[] { Key(VK_CONTROL,(char)0,0), Key(VK_Z,(char)0,0),
                        Key(VK_Z,(char)0,KEYEVENTF_KEYUP), Key(VK_CONTROL,(char)0,KEYEVENTF_KEYUP) };
                    bool sent = SendInput((uint)undo.Length,undo,Marshal.SizeOf(typeof(INPUT))) == undo.Length;
                    bool restored = false;
                    if (sent) {
                        Thread.Sleep(100);
                        restored = EditorBridge.MatchesCaretTail(last.Window,last.Bridge,last.Source);
                    }
                    if (last.History != null)
                        last.History.Status = !sent ? "Native Ctrl+Z rejected" :
                            restored ? "Restored (UI Automation caret verified)" :
                                       "Native Ctrl+Z sent; restore not verified";
                } catch { }
                finally { Interlocked.Exchange(ref bridgeBusy,0); }
            });
            worker.IsBackground=true;
            worker.SetApartmentState(System.Threading.ApartmentState.STA);
            worker.Start();
        }
        private bool ApplyPreview() {
            PreviewRequest p = pending; pending = null;
            bubble.Dismiss();
            if (p == null || DateTime.UtcNow > p.Until || GetForegroundWindow() != p.Window) return false;
            if (p.Bridge != null) { ApplyBridgePreview(p); return true; }
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
        private bool ShowSelectionPreview(IntPtr window, string processName) {
            EditorState e;
            if (!TryReadEditor(window, out e)) {
                if (!EditorBridge.ShouldProbe(editorBridgeEnabled, processName, allowed, excluded)) return false;
                return QueueBridgeSelection(window, processName);
            }
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
        public event Action<string, string> CorrectionAccepted;
        private bool ReplaceText(string source, string replacement, IntPtr window, IntPtr focus,
                                 bool selection, bool trailingSpace = false, EditorSnapshot bridge = null) {
            if (GetForegroundWindow() != window) return false;
            List<INPUT> events = new List<INPUT>();
            if (!selection)
                for (int i = 0; i < source.Length; i++) {
                    events.Add(Key(VK_BACK, (char)0, 0)); events.Add(Key(VK_BACK, (char)0, KEYEVENTF_KEYUP));
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
                Replacement = replacement, HasTrailingSpace = trailingSpace, Bridge = bridge,
                Until = DateTime.UtcNow.AddSeconds(8) };
            bubble.Present(source, replacement, true);
            lastUndo.History = Remember(source,replacement,window,false);
            if (learnAccepted && !trailingSpace && CorrectionAccepted != null) {
                // Persist accepted words after returning from the global keyboard hook.
                string savedSource = source, savedReplacement = replacement;
                try { bubble.BeginInvoke((MethodInvoker)delegate {
                    if (CorrectionAccepted != null) {
                        try { CorrectionAccepted(savedSource, savedReplacement); } catch { }
                    }
                }); } catch { }
            }
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
            if (last.Bridge != null) {
                // UI Automation is cross-process: never query providers inside the keyboard hook.
                lastUndo = null; bubble.Dismiss(); token = "";
                UndoBridge(last);
                return true;
            }
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
                events.Add(Key(VK_LEFT, (char)0, 0)); events.Add(Key(VK_LEFT, (char)0, KEYEVENTF_KEYUP));
            }
            for (int i = 0; i < last.Replacement.Length; i++) {
                events.Add(Key(VK_BACK, (char)0, 0)); events.Add(Key(VK_BACK, (char)0, KEYEVENTF_KEYUP));
            }
            foreach (char c in last.Source) {
                events.Add(Key(0, c, KEYEVENTF_UNICODE));
                events.Add(Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
            if (last.HasTrailingSpace) {
                events.Add(Key(VK_RIGHT, (char)0, 0)); events.Add(Key(VK_RIGHT, (char)0, KEYEVENTF_KEYUP));
            }
            INPUT[] keys = events.ToArray();
            token = "";
            bool success = SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT))) == keys.Length;
            if (last.History != null) last.History.Status = success ? "Undo input sent" : "Undo input failed";
            return success;
        }

        private IntPtr OnMouse(int code, IntPtr message, IntPtr data)
        {
            if (code >= 0)
            {
                int msg = message.ToInt32();
                if (msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN || msg == WM_MBUTTONDOWN) {
                    // A non-activating preview button must not erase its own pending action.
                    if (!bubble.Visible || !bubble.Bounds.Contains(Cursor.Position)) {
                        token = ""; Interlocked.Increment(ref bridgeSerial); lastUndo = null; CancelPreview();
                    }
                }
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
                if (window != previousWindow) { token = ""; Interlocked.Increment(ref bridgeSerial); CancelPreview(); lastUndo = null; previousWindow = window; }
                uint pid;
                uint thread = GetWindowThreadProcessId(window, out pid);
                string processName;
                try { processName = Process.GetProcessById((int)pid).ProcessName; }
                catch { token = ""; return CallNextHookEx(hook, code, message, data); }
                if (!IsApplicationEligible(processName, allowed, excluded) ||
                    ResolveAppMode(mode, processName, applicationPolicies) == "off")
                { token = ""; CancelPreview(); lastUndo = null; return CallNextHookEx(hook, code, message, data); }
                string effectiveMode = ResolveAppMode(mode, processName, applicationPolicies);
                int vk = (int)entry.vkCode;
                bool ctrl = KeyHeld(VK_CONTROL), alt = KeyHeld(VK_MENU), shift = KeyHeld(VK_SHIFT);
                if (pending != null && DateTime.UtcNow > pending.Until) CancelPreview();
                if (pending != null) {
                    // A smart suggestion is passive: ordinary Enter, Esc and
                    // continued typing always reach the application.
                    bool passive = pending.Passive;
                    if (!passive && vk == VK_ESCAPE) { CancelPreview(); token = ""; return new IntPtr(1); }
                    if (!passive && vk == VK_RETURN && !ctrl && !alt && !shift) {
                        ApplyPreview(); return new IntPtr(1);
                    }
                    if (vk != VK_SHIFT && vk != VK_CONTROL && vk != VK_MENU && vk != VK_CAPITAL) {
                        Interlocked.Increment(ref bridgeSerial);
                        CancelPreview();
                        if (!passive) token = "";
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
                    if (ShowSelectionPreview(window, processName)) { token = ""; return new IntPtr(1); }
                }
                if ((shift && vk == VK_BACK && !ctrl && !alt) ||
                    (ctrl && alt && vk == (int)'R')) {
                    if (ShowTokenPreview(window)) return new IntPtr(1);
                    return CallNextHookEx(hook, code, message, data);
                }
                if (vk != VK_SHIFT && vk != VK_CONTROL && vk != VK_MENU && vk != VK_CAPITAL
                    && vk != VK_F8) {
                    Interlocked.Increment(ref bridgeSerial);
                    lastUndo = null; if (pending == null) bubble.Dismiss();
                }
                if (ctrl || alt || KeyHeld(VK_LWIN) || KeyHeld(VK_RWIN))
                { token = ""; return CallNextHookEx(hook, code, message, data); }
                if (vk == VK_BACK)
                {
                    if (token.Length > 0) token = token.Substring(0, token.Length - 1);
                }
                else if (vk == VK_SPACE || vk == VK_RETURN || vk == VK_TAB)
                {
                    if (effectiveMode == "auto" && vk == VK_SPACE) ReplaceToken(false, window);
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
                    lastTypedAt = DateTime.UtcNow;
                    if (token != lastHint) lastHint = "";
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
        [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint thread);
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

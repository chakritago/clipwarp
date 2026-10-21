// Optional Microsoft UI Automation adapter for modern Notepad, Word and VS Code.
// Read-only inspection: no clipboard operations, no ValuePattern.SetValue, no document-wide replacement.
// Bound to one foreground process, one UIA selection, and a short text budget.
namespace ClipwarpRightLang
{
    using System;
    using System.Diagnostics;
    using System.Reflection;
    using System.Runtime.InteropServices;

    public sealed class EditorSnapshot {
        public string ProcessName;
        public string Identity;
        public string SelectedText;
        public int ProcessId;
    }

    public static class EditorBridge {
        private const int Limit = 64;
        private static readonly Type ElementType = LoadElementType();
        private static readonly Type TextType = LoadType("System.Windows.Automation.TextPattern");
        private static readonly Type EndpointType = LoadType("System.Windows.Automation.Text.TextPatternRangeEndpoint");
        private static readonly Type TextUnitType = LoadType("System.Windows.Automation.Text.TextUnit");

        private static Type LoadType(string name) {
            // Microsoft splits UIA APIs across Client and Types assemblies.
            // Both are optional on PowerShell 7; unsupported runtimes fail closed.
            foreach (string assemblyName in new string[] { "UIAutomationClient", "UIAutomationTypes" }) {
                try {
                    Type resolved = Type.GetType(name + ", " + assemblyName, false);
                    if (resolved != null) return resolved;
                    Assembly library = Assembly.Load(assemblyName);
                    resolved = library.GetType(name, false);
                    if (resolved != null) return resolved;
                } catch { }
            }
            return null;
        }
        private static Type LoadElementType() { return LoadType("System.Windows.Automation.AutomationElement"); }
        public static bool Available { get { return ElementType != null && TextType != null; } }

        public static bool IsProfile(string proc) {
            return string.Equals(proc, "notepad", StringComparison.OrdinalIgnoreCase)
                || string.Equals(proc, "winword", StringComparison.OrdinalIgnoreCase)
                || string.Equals(proc, "code", StringComparison.OrdinalIgnoreCase)
                || string.Equals(proc, "code - insiders", StringComparison.OrdinalIgnoreCase)
                || string.Equals(proc, "vscodium", StringComparison.OrdinalIgnoreCase);
        }
        // A custom editor is never silently included; it must be an explicit
        // process-name allowlist entry and the user must enable the bridge.
        public static bool ShouldProbe(bool optedIn, string process, System.Collections.Generic.ICollection<string> allowed,
                                       System.Collections.Generic.ICollection<string> blocked) {
            return optedIn && Available && IsProfile(process)
                && Engine.IsApplicationEligible(process, allowed, blocked);
        }

        private static object ReadProperty(object instance, string name) {
            return instance.GetType().GetProperty(name).GetValue(instance, null);
        }
        private static object Call(object instance, string method, params object[] args) {
            return instance.GetType().GetMethod(method).Invoke(instance, args);
        }
        private static object Pattern(object focused) {
            object identifier = TextType.GetField("Pattern").GetValue(null);
            return focused.GetType().GetMethod("GetCurrentPattern").Invoke(focused, new object[]{ identifier });
        }

        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

        private static bool TryFocused(IntPtr expectedWindow, string processName, out object element, out object pattern, out string id) {
            element = null; pattern = null; id = null;
            if (!Available || expectedWindow == IntPtr.Zero || GetForegroundWindow() != expectedWindow) return false;
            uint pid;
            GetWindowThreadProcessId(expectedWindow, out pid);
            if (pid == 0) return false;
            try {
                using (Process proc = Process.GetProcessById((int)pid)) {
                    if (!string.Equals(proc.ProcessName, processName, StringComparison.OrdinalIgnoreCase)) return false;
                }
                element = ElementType.GetProperty("FocusedElement", BindingFlags.Static | BindingFlags.Public).GetValue(null, null);
                if (element == null) return false;
                object current = ReadProperty(element, "Current");
                if ((int)ReadProperty(current, "ProcessId") != (int)pid) return false;
                if ((bool)ReadProperty(current, "IsPassword")) return false;
                object focusState = ReadProperty(current, "HasKeyboardFocus");
                if (!(bool)focusState) return false;
                int[] runtime = (int[])Call(element, "GetRuntimeId");
                if (runtime == null || runtime.Length == 0) return false;
                id = ((int)pid).ToString() + ":" + string.Join(".", runtime);
                pattern = Pattern(element);
                return pattern != null;
            } catch { return false; }
        }

        public static bool TrySelected(IntPtr window, string processName, out EditorSnapshot snapshot) {
            snapshot = null;
            if (!IsProfile(processName)) return false;
            object element, pattern; string id;
            if (!TryFocused(window, processName, out element, out pattern, out id)) return false;
            try {
                Array ranges = (Array)Call(pattern, "GetSelection");
                if (ranges == null || ranges.Length != 1) return false;
                string value = (string)Call(ranges.GetValue(0), "GetText", Limit + 1);
                if (string.IsNullOrWhiteSpace(value) || value.Length < 2 || value.Length > Limit ||
                    value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0) return false;
                uint pid; GetWindowThreadProcessId(window, out pid);
                snapshot = new EditorSnapshot { ProcessName = processName, ProcessId = (int)pid,
                    Identity = id, SelectedText = value };
                return true;
            } catch { return false; }
        }

        public static bool SameSelection(IntPtr window, EditorSnapshot prior) {
            if (prior == null) return false;
            EditorSnapshot current;
            return TrySelected(window, prior.ProcessName, out current)
                && prior.ProcessId == current.ProcessId && prior.Identity == current.Identity
                && string.Equals(prior.SelectedText, current.SelectedText, StringComparison.Ordinal);
        }

        // GetSelection returns a degenerate caret range after insertion in compliant
        // TextPattern providers; never guess when provider lacks character traversal.
        public static bool MatchesCaretTail(IntPtr window, EditorSnapshot prior, string replacement) {
            if (prior == null || !Available || string.IsNullOrEmpty(replacement) || replacement.Length > 128) return false;
            object element, pattern; string id;
            if (!TryFocused(window, prior.ProcessName, out element, out pattern, out id)
                || prior.Identity != id) return false;
            try {
                Array ranges = (Array)Call(pattern, "GetSelection");
                if (ranges == null || ranges.Length != 1) return false;
                object range = ranges.GetValue(0);
                if (!string.IsNullOrEmpty((string)Call(range, "GetText", 1))) return false;
                object copy = Call(range, "Clone");
                object start = Enum.Parse(EndpointType, "Start");
                object unit = Enum.Parse(TextUnitType, "Character");
                // Move a bounded number of characters backwards from the caret.
                // Some providers do not support character movement; fail closed.
                object[] arguments = new object[]{start, unit, -replacement.Length};
                MethodInfo move = copy.GetType().GetMethod("MoveEndpointByUnit");
                int moved = (int)move.Invoke(copy, arguments);
                if (moved != -replacement.Length) return false;
                string actual = (string)Call(copy, "GetText", replacement.Length + 1);
                return string.Equals(actual, replacement, StringComparison.Ordinal);
            } catch { return false; }
        }
    }
}

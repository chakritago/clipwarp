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
        public string StyleFingerprint;
        public string BeforeContext;
        public string AfterContext;
    }

    public static class EditorBridge {
        private const int Limit = 64;
        private static readonly Type ElementType = LoadElementType();
        private static readonly Type TextType = LoadType("System.Windows.Automation.TextPattern");
        private static readonly Type EndpointType = LoadType("System.Windows.Automation.Text.TextPatternRangeEndpoint");
        private static readonly Type TextUnitType = LoadType("System.Windows.Automation.Text.TextUnit");
        private static readonly Type WalkerType = LoadType("System.Windows.Automation.TreeWalker");
        private const int MaxAncestors = 4;
        private const int ContextLimit = 12;

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
            if (focused == null || TextType == null) return null;
            object identifier = TextType.GetField("Pattern").GetValue(null);
            // Unsupported TextPattern is expected with rich editors and must not throw.
            object[] args = new object[] { identifier, null };
            try {
                bool ok = (bool)focused.GetType().GetMethod("TryGetCurrentPattern").Invoke(focused, args);
                return ok ? args[1] : null;
            } catch { return null; }
        }

        // Some recent Word/Notepad/VS Code providers expose TextPattern on a
        // document ancestor rather than on the keyboard-focused child.
        private static object ParentOf(object element) {
            if (element == null || WalkerType == null) return null;
            try {
                object walker = WalkerType.GetProperty("ControlViewWalker",
                    BindingFlags.Static | BindingFlags.Public).GetValue(null, null);
                return Call(walker, "GetParent", element);
            } catch { return null; }
        }
        private static bool ValidNode(object element, int pid, bool mustHaveFocus) {
            if (element == null) return false;
            object state = ReadProperty(element, "Current");
            if ((int)ReadProperty(state,"ProcessId") != pid) return false;
            if ((bool)ReadProperty(state,"IsPassword")) return false;
            if (mustHaveFocus && !(bool)ReadProperty(state,"HasKeyboardFocus")) return false;
            return true;
        }
        public static bool IsSingleLineSelection(string value) {
            return !string.IsNullOrWhiteSpace(value) && value.Length >= 2 && value.Length <= Limit
                && value.IndexOf('\r') < 0 && value.IndexOf('\n') < 0
                && value.IndexOf('\0') < 0;
        }

        private static object StaticValue(Type type, string name) {
            if (type == null) return null;
            FieldInfo field = type.GetField(name, BindingFlags.Public | BindingFlags.Static);
            if (field != null) return field.GetValue(null);
            PropertyInfo property = type.GetProperty(name, BindingFlags.Public | BindingFlags.Static);
            return property == null ? null : property.GetValue(null, null);
        }
        // Inspect formatting BEFORE editing Word; refuse selections whose style
        // could not be established reliably. This does not promise identical
        // formatting of inserted text: only the selected range is replaced.
        // Re-read the fingerprint before insertion to detect style changes.
        private static readonly string[] WordStyleAttributes = new string[] {
            "FontNameAttribute", "FontSizeAttribute", "FontWeightAttribute",
            "IsItalicAttribute", "UnderlineStyleAttribute", "StrikethroughStyleAttribute",
            "ForegroundColorAttribute", "BackgroundColorAttribute",
            "IsSuperscriptAttribute", "IsSubscriptAttribute"
        };
        public static bool IsWordStyleSafe(bool isWord, bool allAttributesKnown,
                                           bool mixedFormatting, bool richObject) {
            return !isWord || (allAttributesKnown && !mixedFormatting && !richObject);
        }
        private static bool TryWordStyleFingerprint(object textRange, string processName, out string fingerprint) {
            fingerprint = null;
            if (!string.Equals(processName, "winword", StringComparison.OrdinalIgnoreCase))
                return true;
            try {
                // Reflect the UIA sentinels from either their public field or property.
                object mixed = StaticValue(TextType, "MixedAttributeValue");
                object notSupported = StaticValue(ElementType, "NotSupported");
                if (mixed == null || notSupported == null) return false;
                System.Text.StringBuilder result = new System.Text.StringBuilder();
                foreach (string field in WordStyleAttributes) {
                    FieldInfo info = TextType.GetField(field);
                    if (info == null) return false;
                    object attr = info.GetValue(null);
                    object value = Call(textRange, "GetAttributeValue", attr);
                    if (value == null || Object.ReferenceEquals(value, mixed) ||
                        Object.ReferenceEquals(value, notSupported)) return false;
                    result.Append(field).Append('=').Append(value.ToString()).Append(';');
                }
                string selectedText = (string)Call(textRange, "GetText", Limit + 1);
                // Embedded object replacement (U+FFFC) must never be edited.
                if (string.IsNullOrEmpty(selectedText) || selectedText.IndexOf('\uFFFC') >= 0) return false;
                fingerprint = result.ToString();
                return fingerprint.Length > 0;
            } catch { return false; }
        }

        // Require the accessibility provider to expose stable text immediately
        // before/after the selection. This catches duplicate-word ambiguity,
        // cursor movement and same-text replacements at another document position.
        // Providers lacking endpoint navigation fail closed; never scrape or
        // fall back to the system clipboard.
        private static bool TrySelectionContext(object range, out string before, out string after) {
            before = null; after = null;
            if (range == null || EndpointType == null || TextUnitType == null) return false;
            try {
                object start = Enum.Parse(EndpointType, "Start");
                object end = Enum.Parse(EndpointType, "End");
                object unit = Enum.Parse(TextUnitType, "Character");
                object left = Call(range, "Clone");
                Call(left, "MoveEndpointByRange", end, range, start);
                Call(left, "MoveEndpointByUnit", start, unit, -ContextLimit);
                object right = Call(range, "Clone");
                Call(right, "MoveEndpointByRange", start, range, end);
                Call(right, "MoveEndpointByUnit", end, unit, ContextLimit);
                before = (string)Call(left, "GetText", ContextLimit + 1);
                after = (string)Call(right, "GetText", ContextLimit + 1);
                return before != null && after != null &&
                    before.Length <= ContextLimit && after.Length <= ContextLimit;
            } catch { return false; }
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
                object focused = ElementType.GetProperty("FocusedElement",
                    BindingFlags.Static | BindingFlags.Public).GetValue(null, null);
                if (!ValidNode(focused, (int)pid, true)) return false;
                object candidate = focused;
                for (int depth=0; depth<=MaxAncestors && candidate!=null; depth++) {
                    if (!ValidNode(candidate,(int)pid,depth==0)) return false;
                    pattern = Pattern(candidate);
                    if (pattern != null) {
                        int[] runtime = (int[])Call(candidate,"GetRuntimeId");
                        if (runtime == null || runtime.Length == 0) return false;
                        id = ((int)pid).ToString() + ":" + string.Join(".",runtime);
                        element = candidate;
                        return true;
                    }
                    candidate = ParentOf(candidate);
                }
                return false;
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
                if (!IsSingleLineSelection(value)) return false;
                string styleFingerprint;
                if (!TryWordStyleFingerprint(ranges.GetValue(0), processName, out styleFingerprint)) return false;
                string before, after;
                if (!TrySelectionContext(ranges.GetValue(0), out before, out after)) return false;
                uint pid; GetWindowThreadProcessId(window, out pid);
                snapshot = new EditorSnapshot { ProcessName = processName, ProcessId = (int)pid,
                    Identity = id, SelectedText = value, StyleFingerprint = styleFingerprint,
                    BeforeContext = before, AfterContext = after };
                return true;
            } catch { return false; }
        }

        public static bool SameSelection(IntPtr window, EditorSnapshot prior) {
            if (prior == null) return false;
            EditorSnapshot current;
            return TrySelected(window, prior.ProcessName, out current)
                && prior.ProcessId == current.ProcessId && prior.Identity == current.Identity
                && string.Equals(prior.SelectedText, current.SelectedText, StringComparison.Ordinal)
                && string.Equals(prior.StyleFingerprint, current.StyleFingerprint, StringComparison.Ordinal)
                && string.Equals(prior.BeforeContext, current.BeforeContext, StringComparison.Ordinal)
                && string.Equals(prior.AfterContext, current.AfterContext, StringComparison.Ordinal);
        }

        // GetSelection returns a degenerate caret range after insertion in compliant
        // TextPattern providers; never guess when provider lacks character traversal.
        public static bool MatchesCaretTail(IntPtr window, EditorSnapshot prior, string replacement) {
            if(prior==null || !Available || EndpointType==null || TextUnitType==null ||
               string.IsNullOrEmpty(replacement) || replacement.Length>128 ||
               prior.BeforeContext==null || prior.AfterContext==null) return false;
            object element,pattern; string id;
            if(!TryFocused(window,prior.ProcessName,out element,out pattern,out id) || prior.Identity!=id) return false;
            try {
                Array ranges=(Array)Call(pattern,"GetSelection");
                if(ranges==null || ranges.Length!=1) return false;
                object range=ranges.GetValue(0);
                if(!string.IsNullOrEmpty((string)Call(range,"GetText",1))) return false;
                object start=Enum.Parse(EndpointType,"Start");
                object end=Enum.Parse(EndpointType,"End");
                object unit=Enum.Parse(TextUnitType,"Character");
                // Verify replacement AND its original prefix. Matching the word
                // alone can accidentally validate a duplicate occurrence nearby.
                int prefixLength=prior.BeforeContext.Length;
                int backLength=prefixLength+replacement.Length;
                object left=Call(range,"Clone");
                MethodInfo move=left.GetType().GetMethod("MoveEndpointByUnit");
                int moved=(int)move.Invoke(left,new object[]{start,unit,-backLength});
                if(moved!=-backLength) return false;
                string actual=(string)Call(left,"GetText",backLength+1);
                if(!string.Equals(actual,prior.BeforeContext+replacement,StringComparison.Ordinal)) return false;
                // Also require the original following context at the caret.
                int suffixLength=prior.AfterContext.Length;
                if(suffixLength>0) {
                    object right=Call(range,"Clone");
                    int movedRight=(int)right.GetType().GetMethod("MoveEndpointByUnit")
                        .Invoke(right,new object[]{end,unit,suffixLength});
                    if(movedRight!=suffixLength) return false;
                    string after=(string)Call(right,"GetText",suffixLength+1);
                    if(!string.Equals(after,prior.AfterContext,StringComparison.Ordinal)) return false;
                }
                return true;
            } catch { return false; }
        }
    }
}

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
    public sealed class Engine : IDisposable
    {
        private const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;
        private const int VK_BACK = 0x08, VK_TAB = 0x09, VK_RETURN = 0x0D, VK_SPACE = 0x20;
        private const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12;
        private const int VK_CAPITAL = 0x14, VK_LWIN = 0x5B, VK_RWIN = 0x5C;
        private const uint KEYEVENTF_KEYUP = 2, KEYEVENTF_UNICODE = 4;
        private const uint LLKHF_INJECTED = 0x10;
        private delegate IntPtr KeyboardProc(int code, IntPtr message, IntPtr data);
        private readonly KeyboardProc proc;
        private IntPtr hook;
        private IntPtr previousWindow;
        private string token = "";
        private string mode = "manual";
        private Dictionary<string, string> instant = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> words = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private HashSet<string> excluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly IntPtr en = LoadKeyboardLayout("00000409", 0);
        private readonly IntPtr th = LoadKeyboardLayout("0000041E", 0);
        public bool Installed { get { return hook != IntPtr.Zero; } }

        public Engine() { proc = OnKeyboard; }

        public void Configure(string selectedMode, IDictionary<string, string> immediateWords,
                              IEnumerable<string> knownWords, IEnumerable<string> allowedApps,
                              IEnumerable<string> excludedApps)
        {
            string next = selectedMode == "auto" || selectedMode == "manual" ? selectedMode : "off";
            if (next != mode) token = "";
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
            if (hook == IntPtr.Zero) hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        }

        public void Dispose()
        {
            if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
            token = "";
            GC.KeepAlive(proc);
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

        private IntPtr OnKeyboard(int code, IntPtr message, IntPtr data)
        {
            if (code < 0 || (message.ToInt32() != WM_KEYDOWN && message.ToInt32() != WM_SYSKEYDOWN))
                return CallNextHookEx(hook, code, message, data);
            KBDLLHOOKSTRUCT entry = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(data, typeof(KBDLLHOOKSTRUCT));
            if ((entry.flags & LLKHF_INJECTED) != 0) return CallNextHookEx(hook, code, message, data);
            try
            {
                if (mode == "off") { token = ""; return CallNextHookEx(hook, code, message, data); }
                IntPtr window = GetForegroundWindow();
                if (window != previousWindow) { token = ""; previousWindow = window; }
                uint pid;
                uint thread = GetWindowThreadProcessId(window, out pid);
                string processName;
                try { processName = Process.GetProcessById((int)pid).ProcessName; }
                catch { token = ""; return CallNextHookEx(hook, code, message, data); }
                if (!allowed.Contains(processName) || excluded.Contains(processName))
                { token = ""; return CallNextHookEx(hook, code, message, data); }
                int vk = (int)entry.vkCode;
                bool ctrl = KeyHeld(VK_CONTROL), alt = KeyHeld(VK_MENU), shift = KeyHeld(VK_SHIFT);
                if (ctrl && vk == VK_CAPITAL && !alt)
                {
                    mode = mode == "auto" ? "manual" : "auto";
                    token = "";
                    ModeToggled?.Invoke(mode);
                    return new IntPtr(1);
                }
                if ((shift && vk == VK_BACK && !ctrl && !alt) ||
                    (ctrl && alt && vk == (int)'R'))
                {
                    if (ReplaceToken(true)) return new IntPtr(1);
                    return CallNextHookEx(hook, code, message, data);
                }
                if (ctrl || alt || KeyHeld(VK_LWIN) || KeyHeld(VK_RWIN))
                { token = ""; return CallNextHookEx(hook, code, message, data); }
                if (vk == VK_BACK)
                {
                    if (token.Length > 0) token = token.Substring(0, token.Length - 1);
                }
                else if (vk == VK_SPACE || vk == VK_RETURN || vk == VK_TAB)
                {
                    if (mode == "auto" && vk == VK_SPACE) ReplaceToken(false);
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

        private bool ReplaceToken(bool forced)
        {
            if (token.Length < 2 || token.Length > 64) return false;
            string replacement;
            if (!instant.TryGetValue(token, out replacement))
            {
                replacement = ConvertLayout(token);
                if (replacement == null || (!forced && !words.Contains(replacement))) return false;
            }
            if (replacement == token || string.IsNullOrEmpty(replacement)) return false;
            List<INPUT> events = new List<INPUT>();
            for (int i = 0; i < token.Length; i++) { events.Add(Key(VK_BACK, 0, 0)); events.Add(Key(VK_BACK, 0, KEYEVENTF_KEYUP)); }
            foreach (char ch in replacement)
            {
                events.Add(Key(0, ch, KEYEVENTF_UNICODE));
                events.Add(Key(0, ch, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
            INPUT[] sequence = events.ToArray();
            uint sent = SendInput((uint)sequence.Length, sequence, Marshal.SizeOf(typeof(INPUT)));
            if (sent != sequence.Length) { token = ""; return false; }
            token = "";
            return true;
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
        private struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT { public uint type; public KEYBDINPUT ki; }

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

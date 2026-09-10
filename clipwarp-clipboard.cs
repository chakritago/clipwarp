// Clipboard publication is compare-and-set under the native clipboard lock.
// All memory is prepared before opening/emptying the clipboard. No OLE retry
// can later overwrite a newer copy. This class does not access the clipboard
// until Publish is explicitly called.
namespace ClipwarpTransport {
    using System;
    using System.IO;
    using System.Text;
    using System.Drawing;
    using System.Windows.Forms;
    using System.Collections.Generic;
    using System.Runtime.InteropServices;
    public static class ClipboardWriter {
        [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool CloseClipboard();
        [DllImport("user32.dll")] static extern bool EmptyClipboard();
        [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr memory);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr memory);
        [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr memory);
        public static bool SequenceMatches(uint expected, uint actual) { return expected != 0 && expected == actual; }
        public static string Marker(IDataObject data) {
            if (data == null || !data.GetDataPresent("ClipwarpManaged")) return null;
            object value = data.GetData("ClipwarpManaged");
            string text = value as string;
            if (text != null) return text;
            MemoryStream stream = value as MemoryStream;
            return stream == null ? null : Encoding.Unicode.GetString(stream.ToArray()).TrimEnd('\0');
        }
        public static Dictionary<uint, byte[]> Prepare(IDataObject data, Func<string, uint> register) {
            var formats = new Dictionary<uint, byte[]>();
            string marker = Marker(data);
            if (marker != null) formats.Add(register("ClipwarpManaged"), Encoding.Unicode.GetBytes(marker + "\0"));
            if (data.GetDataPresent(DataFormats.UnicodeText)) formats.Add(13, Encoding.Unicode.GetBytes((string)data.GetData(DataFormats.UnicodeText) + "\0"));
            MemoryStream png = data.GetData("PNG") as MemoryStream;
            if (png != null) formats.Add(register("PNG"), png.ToArray());
            Image image = data.GetData(DataFormats.Bitmap) as Image;
            if (image != null) {
                using (var stream = new MemoryStream()) {
                    image.Save(stream, System.Drawing.Imaging.ImageFormat.Bmp);
                    byte[] bmp = stream.ToArray();
                    byte[] dib = new byte[bmp.Length - 14];
                    Array.Copy(bmp,14,dib,0,dib.Length);
                    formats.Add(8,dib);
                }
            }
            string[] files = data.GetData(DataFormats.FileDrop) as string[];
            if (files != null && files.Length > 0) {
                byte[] names = Encoding.Unicode.GetBytes(string.Join("\0",files) + "\0\0");
                byte[] drop = new byte[20+names.Length];
                drop[0]=20; drop[16]=1; // DROPFILES: pFiles=20, fWide=TRUE
                Array.Copy(names,0,drop,20,names.Length);
                formats.Add(15,drop);
            }
            return formats;
        }
        public static uint Publish(IDataObject data, uint expected) {
            return PublishPrepared(Prepare(data, RegisterClipboardFormat), expected, null);
        }
        public static Dictionary<uint, byte[]> PrepareNative(IDataObject data) { return Prepare(data, RegisterClipboardFormat); }
        // The predicate must be side-effect free; it is checked while the native clipboard lock is held.
        public static uint PublishPrepared(Dictionary<uint, byte[]> formats, uint expected, Func<bool> targetIsCurrent) {
            if (formats.Count == 0) throw new InvalidOperationException("Empty publication");
            var memory = new Dictionary<uint, IntPtr>();
            try {
                foreach (var item in formats) {
                    if (item.Key == 0) throw new InvalidOperationException("Format registration failed");
                    IntPtr block = GlobalAlloc(0x42, new UIntPtr((uint)item.Value.Length));
                    if (block == IntPtr.Zero) throw new OutOfMemoryException();
                    memory.Add(item.Key, block);
                    IntPtr pointer = GlobalLock(block);
                    if (pointer == IntPtr.Zero) throw new OutOfMemoryException();
                    try { Marshal.Copy(item.Value,0,pointer,item.Value.Length); }
                    finally { GlobalUnlock(block); }
                }
                // A real HWND is required by EmptyClipboard/SetClipboardData.
                var owner = new NativeWindow();
                owner.CreateHandle(new CreateParams());
                try {
                    if (!OpenClipboard(owner.Handle)) throw new InvalidOperationException("Clipboard busy");
                    try {
                        if (!SequenceMatches(expected,GetClipboardSequenceNumber())) throw new InvalidOperationException("clipboard-changed");
                        if (targetIsCurrent != null && !targetIsCurrent()) throw new InvalidOperationException("target-changed");
                        if (!EmptyClipboard()) throw new InvalidOperationException("EmptyClipboard failed");
                        foreach (uint format in new List<uint>(memory.Keys)) {
                            if (SetClipboardData(format,memory[format]) == IntPtr.Zero) throw new InvalidOperationException("SetClipboardData failed");
                            memory[format]=IntPtr.Zero; // ownership transferred to Windows
                        }
                        return GetClipboardSequenceNumber();
                    } finally { CloseClipboard(); }
                } finally { owner.DestroyHandle(); }
            } finally { foreach (IntPtr block in memory.Values) if (block != IntPtr.Zero) GlobalFree(block); }
        }
    }
}

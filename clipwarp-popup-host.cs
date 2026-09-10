// Shared popup transport protocol and mailbox for warm popup host
namespace ClipwarpPopupHost {
using System;
using System.IO;
using System.Text;
using System.Threading;

    public sealed class PopupRequest {
        public long RequestId { get; set; }
        public string Text { get; set; }
        public uint ExpectedSequence { get; set; }
        public int PointerX { get; set; }
        public int PointerY { get; set; }
        public bool HasPointer { get; set; }

        public byte[] Serialize() {
            byte[] textBytes = Encoding.UTF8.GetBytes(Text ?? string.Empty);
            if (textBytes.Length > 1024 * 1024) throw new InvalidOperationException("Payload exceeds 1 MiB limit");
            using (var ms = new MemoryStream()) {
                using (var bw = new BinaryWriter(ms, Encoding.UTF8, true)) {
                    bw.Write((byte)0x43); // 'C'
                    bw.Write((byte)0x57); // 'W'
                    bw.Write((byte)1);    // Version
                    bw.Write(RequestId);
                    bw.Write(ExpectedSequence);
                    bw.Write(PointerX);
                    bw.Write(PointerY);
                    bw.Write(HasPointer);
                    bw.Write(textBytes.Length);
                    bw.Write(textBytes);
                }
                return ms.ToArray();
            }
        }

        public static PopupRequest Deserialize(Stream stream) {
            using (var br = new BinaryReader(stream, Encoding.UTF8, true)) {
                byte m1 = br.ReadByte();
                byte m2 = br.ReadByte();
                if (m1 != 0x43 || m2 != 0x57) throw new InvalidDataException("Invalid magic bytes in popup request");
                byte ver = br.ReadByte();
                if (ver != 1) throw new InvalidDataException("Unsupported protocol version: " + ver);
                var req = new PopupRequest();
                req.RequestId = br.ReadInt64();
                req.ExpectedSequence = br.ReadUInt32();
                req.PointerX = br.ReadInt32();
                req.PointerY = br.ReadInt32();
                req.HasPointer = br.ReadBoolean();
                int len = br.ReadInt32();
                if (len < 0 || len > 1024 * 1024) throw new InvalidDataException("Invalid payload length: " + len);
                byte[] raw = new byte[len];
                int read = 0;
                while (read < len) {
                    int n = br.Read(raw, read, len - read);
                    if (n <= 0) throw new EndOfStreamException("Stream ended before reading full payload");
                    read += n;
                }
                req.Text = Encoding.UTF8.GetString(raw);
                return req;
            }
        }
    }

    public sealed class PopupMailbox {
        private readonly object sync = new object();
        private PopupRequest latest;
        private long highestSeenId;

        public void Post(PopupRequest req) {
            if (req == null) return;
            lock (sync) {
                if (req.RequestId >= highestSeenId) {
                    highestSeenId = req.RequestId;
                    latest = req;
                }
            }
        }

        public PopupRequest TakeLatest() {
            lock (sync) {
                var item = latest;
                latest = null;
                return item;
            }
        }

        public PopupRequest PeekLatest() {
            lock (sync) {
                return latest;
            }
        }
    }
}

// Shared bounded image preparation. No clipboard, filesystem writes or browser side effects.
namespace ClipwarpImages {
    using System;
    using System.IO;
    using System.Drawing;
    using System.Drawing.Imaging;
    using System.Runtime.InteropServices;
    using System.Windows.Forms;

    public sealed class ImageLimits {
        public long MaxSourceBytes = 33554432;
        public int MaxDimension = 16384;
        public int MaxWidth = 16384;
        public int MaxHeight = 16384;
        public long MaxPixels = 40000000;
        public long MaxDecodedBytes = 160000000;
        public void Validate() {
            if (MaxSourceBytes < 1024 || MaxSourceBytes > 268435456 || MaxDimension < 1 || MaxDimension > 32768 ||
                MaxWidth < 1 || MaxWidth > 32768 || MaxHeight < 1 || MaxHeight > 32768 ||
                MaxPixels < 1 || MaxPixels > 100000000 || MaxDecodedBytes < 4 || MaxDecodedBytes > 400000000)
                throw new ArgumentOutOfRangeException("limits", "Invalid image resource limits");
        }
        public void CheckDimensions(int width, int height) {
            Validate();
            if (width < 1 || height < 1 || width > MaxDimension || height > MaxDimension || width > MaxWidth || height > MaxHeight ||
                checked((long)width * height) > MaxPixels || checked((long)width * height * 4) > MaxDecodedBytes)
                throw new InvalidDataException("Image dimensions exceed resource limits");
        }
    }

    // Owns only immutable encoded bytes; each caller receives independent disposable objects.
    public sealed class ImagePayload : IDisposable {
        private byte[] png;
        public int Width { get; private set; }
        public int Height { get; private set; }
        public long ByteLength { get { return png == null ? 0 : png.LongLength; } }
        internal ImagePayload(byte[] bytes, int width, int height) { png = bytes; Width = width; Height = height; }
        public byte[] GetPngBytes() { if (png == null) throw new ObjectDisposedException("ImagePayload"); return (byte[])png.Clone(); }
        public Bitmap CreateBitmap() {
            if (png == null) throw new ObjectDisposedException("ImagePayload");
            using (var stream = new MemoryStream(png, false))
            using (var image = Image.FromStream(stream, true, true)) return new Bitmap(image);
        }
        public void Dispose() { png = null; }
    }

    public static class ImageHelper {
        static readonly byte[] Signature = {137,80,78,71,13,10,26,10};
        static uint BE(byte[] b, int p) { return ((uint)b[p] << 24) | ((uint)b[p+1] << 16) | ((uint)b[p+2] << 8) | b[p+3]; }
        public static bool HasPngSignature(byte[] bytes) {
            if (bytes == null || bytes.Length < 8) return false;
            for (int i=0;i<8;i++) if (bytes[i] != Signature[i]) return false;
            return true;
        }
        static void CheckSource(byte[] bytes, ImageLimits limits) {
            if (limits == null) throw new ArgumentNullException("limits");
            limits.Validate();
            if (bytes == null || bytes.Length == 0 || bytes.LongLength > limits.MaxSourceBytes) throw new InvalidDataException("Image source exceeds resource limits or is empty");
        }
        public static ImagePayload FromFile(string path, ImageLimits limits) {
            limits.Validate();
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                if (file.Length < 1 || file.Length > limits.MaxSourceBytes) throw new InvalidDataException("Image source exceeds resource limits");
                byte[] bytes = new byte[checked((int)file.Length)];
                int read=0;
                while (read < bytes.Length) { int n=file.Read(bytes,read,bytes.Length-read); if (n==0) throw new EndOfStreamException(); read+=n; }
                return FromBytes(bytes, limits);
            }
        }
        public static ImagePayload FromBytes(byte[] bytes, ImageLimits limits) {
            CheckSource(bytes, limits);
            if (HasPngSignature(bytes)) {
                if (bytes.Length < 33 || BE(bytes,8) != 13 || BE(bytes,12) != 0x49484452) throw new InvalidDataException("Invalid PNG IHDR");
                uint w=BE(bytes,16), h=BE(bytes,20);
                if (w > int.MaxValue || h > int.MaxValue) throw new InvalidDataException("Invalid PNG dimensions");
                limits.CheckDimensions((int)w,(int)h);
            }
            try {
                using (var stream = new MemoryStream(bytes, false))
                using (var image = Image.FromStream(stream, true, false)) {
                    limits.CheckDimensions(image.Width,image.Height);
                    // GIF remains the first frame; unsupported installed codecs (including WebP) fail explicitly.
                    return FromImage(image,limits);
                }
            } catch (ArgumentException ex) { throw new InvalidDataException("Unsupported or invalid image encoding (WebP requires an installed decoder)",ex); }
        }
        public static ImagePayload FromImage(Image image, ImageLimits limits) {
            limits.CheckDimensions(image.Width,image.Height);
            using (var bitmap = new Bitmap(image.Width,image.Height,PixelFormat.Format32bppArgb)) {
                using (var graphics=Graphics.FromImage(bitmap)) {
                    graphics.CompositingMode=System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                    graphics.DrawImage(image,new Rectangle(0,0,image.Width,image.Height));
                }
                using (var stream = new MemoryStream()) {
                    bitmap.Save(stream,ImageFormat.Png);
                    if (stream.Length > limits.MaxSourceBytes) throw new InvalidDataException("Encoded PNG exceeds resource limits");
                    return new ImagePayload(stream.ToArray(),image.Width,image.Height);
                }
            }
        }
        public static ImagePayload FromDib(byte[] dib, ImageLimits limits) {
            CheckSource(dib,limits);
            if (dib.Length < 40) throw new InvalidDataException("Truncated DIB header");
            uint header=BitConverter.ToUInt32(dib,0);
            if (header != 40 && header != 52 && header != 56 && header != 108 && header != 124) throw new InvalidDataException("Unsupported DIB header");
            if (header > dib.Length) throw new InvalidDataException("Truncated DIB header");
            int width=BitConverter.ToInt32(dib,4), signedHeight=BitConverter.ToInt32(dib,8);
            if (signedHeight == int.MinValue) throw new InvalidDataException("Invalid DIB height");
            int height=Math.Abs(signedHeight);
            limits.CheckDimensions(width,height);
            ushort planes=BitConverter.ToUInt16(dib,12), bits=BitConverter.ToUInt16(dib,14);
            uint compression=BitConverter.ToUInt32(dib,16), colors=BitConverter.ToUInt32(dib,32);
            if (planes != 1 || (bits != 1 && bits != 4 && bits != 8 && bits != 16 && bits != 24 && bits != 32) ||
                (compression != 0 && compression != 3 && compression != 6) || (compression != 0 && bits != 16 && bits != 32))
                throw new InvalidDataException("Unsupported DIB encoding");
            long palette=colors == 0 && bits <= 8 ? 1L << bits : colors;
            if ((bits <= 8 && palette > (1L << bits)) || palette > 256) throw new InvalidDataException("Invalid DIB palette");
            long masks=header == 40 && compression != 0 ? (compression == 6 ? 16 : 12) : 0;
            long offset=checked((long)header + masks + palette*4);
            long stride=checked((((long)width*bits+31)/32)*4);
            long pixelBytes=checked(stride*height);
            if (pixelBytes > limits.MaxDecodedBytes || offset > dib.Length || pixelBytes > dib.LongLength-offset) throw new InvalidDataException("Truncated or excessive DIB pixels");
            uint declared=BitConverter.ToUInt32(dib,20);
            if (declared != 0 && (declared < pixelBytes || declared > dib.LongLength-offset)) throw new InvalidDataException("Invalid DIB image size");
            if (header == 124 && (BitConverter.ToUInt32(dib,112) != 0 || BitConverter.ToUInt32(dib,116) != 0))
                throw new InvalidDataException("Embedded DIB profiles are not supported");
            uint red=bits == 16 ? 0x7c00u : 0xff0000u, green=bits == 16 ? 0x3e0u : 0xff00u, blue=bits == 16 ? 0x1fu : 0xffu, alpha=0;
            if (compression != 0) {
                if (header < 52 && header != 40) throw new InvalidDataException("Missing DIB masks");
                red=BitConverter.ToUInt32(dib,40); green=BitConverter.ToUInt32(dib,44); blue=BitConverter.ToUInt32(dib,48);
                if (header >= 56 || compression == 6) {
                    if (header == 52) throw new InvalidDataException("Missing alpha mask");
                    alpha=BitConverter.ToUInt32(dib,52);
                }
                ValidateMask(red,bits); ValidateMask(green,bits); ValidateMask(blue,bits);
                if (alpha != 0) ValidateMask(alpha,bits);
                if ((red&green)!=0 || (red&blue)!=0 || (green&blue)!=0 || (alpha&(red|green|blue))!=0) throw new InvalidDataException("Overlapping DIB masks");
            }
            using (var bitmap=new Bitmap(width,height,PixelFormat.Format32bppArgb)) {
                BitmapData locked=bitmap.LockBits(new Rectangle(0,0,width,height),ImageLockMode.WriteOnly,PixelFormat.Format32bppArgb);
                try {
                    byte[] row=new byte[checked(width*4)];
                    for (int y=0;y<height;y++) {
                        int p=checked((int)(offset+(signedHeight>0 ? height-1-y : y)*stride));
                        for (int x=0;x<width;x++) {
                            int dest=x*4; row[dest+3]=255;
                            if (bits <= 8) {
                                int index=bits==8 ? dib[p+x] : bits==4 ? ((dib[p+x/2] >> ((1-x%2)*4))&15) : ((dib[p+x/8] >> (7-x%8))&1);
                                if (index >= palette) throw new InvalidDataException("DIB palette index out of range");
                                int entry=checked((int)(header+masks+index*4));
                                row[dest]=dib[entry]; row[dest+1]=dib[entry+1]; row[dest+2]=dib[entry+2];
                            } else if (bits==24) { row[dest]=dib[p+x*3]; row[dest+1]=dib[p+x*3+1]; row[dest+2]=dib[p+x*3+2]; }
                            else {
                                uint value=bits==16 ? BitConverter.ToUInt16(dib,p+x*2) : BitConverter.ToUInt32(dib,p+x*4);
                                row[dest]=Channel(value,blue); row[dest+1]=Channel(value,green); row[dest+2]=Channel(value,red);
                                if (alpha!=0) row[dest+3]=Channel(value,alpha);
                            }
                        }
                        Marshal.Copy(row,0,IntPtr.Add(locked.Scan0,checked(y*locked.Stride)),row.Length);
                    }
                } finally { bitmap.UnlockBits(locked); }
                return FromImage(bitmap,limits);
            }
        }
        static void ValidateMask(uint mask,int bits) {
            if (mask==0 || (bits<32 && (mask>>bits)!=0)) throw new InvalidDataException("Invalid DIB mask");
            while ((mask&1)==0) mask>>=1;
            if ((mask & (mask+1)) != 0) throw new InvalidDataException("Noncontiguous DIB mask");
        }
        static byte Channel(uint value,uint mask) {
            int shift=0; while ((mask&1)==0) { mask>>=1; shift++; }
            return (byte)(((ulong)((value>>shift)&mask)*255 + mask/2)/mask);
        }
    }
}

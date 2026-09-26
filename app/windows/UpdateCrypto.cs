using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Backgrounds
{
    /// Update verification, kept free of app dependencies so it can be tested on its own.
    public static class UpdateCrypto
    {
        /// Throws unless `data` has the expected SHA-256 and the feed entry's signature is valid for this key.
        public static void Verify(byte[] data, string platform, string version, string sha256, string signature, string publicKey)
        {
            string actual;
            using (var sha = SHA256.Create()) actual = BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
            if (!string.Equals(actual, sha256, StringComparison.OrdinalIgnoreCase)) throw new Exception("the download is damaged (checksum mismatch)");
            byte[] key = Convert.FromBase64String(publicKey), sig = Convert.FromBase64String(signature ?? "");
            if (key.Length != 64 || sig.Length != 64) throw new Exception("the update's signature is missing or malformed");
            var p = new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = key.Take(32).ToArray(), Y = key.Skip(32).ToArray() },
            };
            using (var ec = ECDsa.Create(p))
            {
                byte[] msg = Encoding.UTF8.GetBytes("backgrounds-update\n" + platform + "\n" + version + "\n" + actual);
                if (!ec.VerifyData(msg, sig, HashAlgorithmName.SHA256)) throw new Exception("the update's signature is not valid");
            }
        }

        /// Compares dotted versions numerically ("1.10.0" > "1.9.2").
        public static int Compare(string a, string b)
        {
            int[] pa = Parse(a), pb = Parse(b);
            for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
            {
                int x = i < pa.Length ? pa[i] : 0, y = i < pb.Length ? pb[i] : 0;
                if (x != y) return x.CompareTo(y);
            }
            return 0;
        }
        static int[] Parse(string v) => (v ?? "").Split('-', '+')[0].Split('.').Select(x => int.TryParse(x, out int n) ? n : 0).ToArray();
    }
}

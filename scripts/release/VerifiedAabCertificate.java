import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Path;
import java.security.CodeSigner;
import java.security.MessageDigest;
import java.security.cert.Certificate;
import java.util.HexFormat;
import java.util.Locale;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

final class VerifiedAabCertificate {
  private static boolean isSignatureMetadata(String name) {
    String upper = name.toUpperCase(Locale.ROOT);
    if (!upper.startsWith("META-INF/")) {
      return false;
    }
    String file = upper.substring("META-INF/".length());
    if (file.contains("/")) {
      return false;
    }
    if (file.equals("MANIFEST.MF") || file.endsWith(".SF") || file.endsWith(".RSA")
        || file.endsWith(".DSA") || file.endsWith(".EC")) {
      return true;
    }
    if (!file.startsWith("SIG-")) {
      return false;
    }
    // JDK 17 only reserves SIG-* entries without an extension or with
    // a one-to-three-character ASCII alphanumeric extension.
    int dot = file.lastIndexOf('.');
    return dot < 0 || file.substring(dot + 1).matches("[A-Z0-9]{1,3}");
  }

  public static void main(String[] args) throws Exception {
    Certificate signer = null;
    try (JarFile bundle = new JarFile(Path.of(args[0]).toFile(), true)) {
      var entries = bundle.entries();
      while (entries.hasMoreElements()) {
        JarEntry entry = entries.nextElement();
        if (entry.isDirectory() || isSignatureMetadata(entry.getName())) {
          continue;
        }
        // The JDK verifies the entry digest when the complete payload is read.
        try (InputStream input = bundle.getInputStream(entry)) {
          input.transferTo(OutputStream.nullOutputStream());
        }
        CodeSigner[] signers = entry.getCodeSigners();
        if (signers == null || signers.length != 1) {
          throw new SecurityException("AAB payload entry needs exactly one verified signer");
        }
        Certificate leaf = signers[0].getSignerCertPath().getCertificates().get(0);
        if (signer != null && !signer.equals(leaf)) {
          throw new SecurityException("AAB payload entries have mixed signers");
        }
        signer = leaf;
      }
    }
    if (signer == null) {
      throw new SecurityException("AAB has no signed payload");
    }
    byte[] hash = MessageDigest.getInstance("SHA-256").digest(signer.getEncoded());
    System.out.println(HexFormat.of().formatHex(hash));
  }
}

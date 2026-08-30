using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Translator.Core.Loading;

namespace Translator.Core.IO;

internal sealed record AssemblyBlob(string FileName, string Symbol, ReadOnlyMemory<byte> Data, string Comment);

internal static class AssemblyBlobWriter
{
    public static void Write(
        string assemblyPath,
        string blobDirectory,
        string blobReferenceDirectory,
        IReadOnlyList<AssemblyBlob> blobs,
        params string[] headerLines)
    {
        Directory.CreateDirectory(blobDirectory);
        var expectedFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var assembly = new StringBuilder();
        foreach (var header in headerLines) assembly.AppendLine(header);
        // PE/COFF (Windows), ELF (Linux) and Mach-O (macOS) each spell a read-only data section
        // differently in GNU-as-compatible syntax - COFF section flags ("dr" = data, read-only),
        // an ELF section needing an allocatable-only flag plus an explicit @progbits type, or a
        // Mach-O segment/section pair (__TEXT,__const is what clang itself emits for `const`
        // globals). The build always targets whichever platform the translator itself runs on
        // (there is no cross-compilation support), so that's what this picks the section syntax
        // from.
        assembly.AppendLine(OperatingSystem.IsWindows()
            ? ".section .rdata,\"dr\""
            : OperatingSystem.IsMacOS()
                ? ".section __TEXT,__const"
                : ".section .rodata,\"a\",@progbits");
        assembly.AppendLine();

        foreach (var blob in blobs)
        {
            var blobPath = Path.Combine(blobDirectory, blob.FileName);
            expectedFiles.Add(Path.GetFullPath(blobPath));
            FileOutput.WriteBytesIfChanged(blobPath, blob.Data.Span);
            var hash = ChecksumUtilities.Sha256Hex(blob.Data.Span);
            // Darwin's C/C++ compiler prepends an underscore to every extern "C" global's link
            // name (the classic Mach-O convention, inherited from the original 32-bit PowerPC/68k
            // toolchains); the assembler does not do this automatically for a plain label, so the
            // symbol text written into hand-assembled output must carry the underscore itself on
            // macOS to match what the C++ side (a normal `extern "C" ... blob.Symbol;`
            // declaration) actually links against. ELF and PE/COFF need no such prefix.
            var symbolName = OperatingSystem.IsMacOS() ? "_" + blob.Symbol : blob.Symbol;
            assembly.AppendLine($"// {blob.Comment}; sha256={hash}");
            assembly.AppendLine(".p2align 4");
            assembly.AppendLine($".globl {symbolName}");
            assembly.AppendLine($"{symbolName}:");
            var referencePath = Path.Combine(blobReferenceDirectory, blob.FileName);
            assembly.AppendLine($".incbin \"{SanitizeAssemblyPath(referencePath)}\"");
            assembly.AppendLine();
        }

        foreach (var stalePath in Directory.EnumerateFiles(blobDirectory, "*.bin"))
        {
            if (!expectedFiles.Contains(Path.GetFullPath(stalePath))) File.Delete(stalePath);
        }
        if (!OperatingSystem.IsWindows() && !OperatingSystem.IsMacOS())
        {
            // Absence of a .note.GNU-stack section makes the linker assume the oldest, most
            // conservative default for this object (an executable stack) and warn about it; this
            // file has no code needing one, so mark it explicitly like every other GNU-as ELF
            // object linked into the binary already does (the norm on modern toolchains, just not
            // producible without an explicit section since this file is hand-assembled, not
            // compiler-emitted). ELF-only convention - Mach-O has no equivalent note section and
            // ld64 doesn't warn about executable-stack defaults the way GNU ld does.
            assembly.AppendLine(".section .note.GNU-stack,\"\",@progbits");
        }
        FileOutput.WriteTextIfChanged(assemblyPath, assembly.ToString());
    }

    private static string SanitizeAssemblyPath(string path) => Path.GetFullPath(path).Replace('\\', '/');
}

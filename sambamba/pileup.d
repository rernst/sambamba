/*
    This file is part of Sambamba.
    Copyright (C) 2012-2015    Artem Tarasov <lomereiter@gmail.com>

    Sambamba is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Sambamba is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

*/
/** module for executing samtools mpileup in parallel using named pipes,
 *  after chunking a file
 */

module sambamba.pileup;

import sambamba.utils.common.bed;
import sambamba.utils.common.tmpdir;
import sambamba.utils.common.overwrite;
import utils.lz4;

import bio.bam.multireader;
import bio.bam.reader;
import bio.bam.writer;
import bio.bam.pileup;

import bio.core.utils.format : write;
import bio.core.utils.roundbuf;

import std.process;
import std.stdio;
import std.parallelism;
import std.file : rmdirRecurse;
import std.algorithm;
import std.array;
import std.getopt;
import std.string : strip, indexOf, toStringz;
import std.c.stdlib;
import std.typecons;
import std.stream;
import std.range;
import std.algorithm;
import std.path;
import std.traits;
import std.typecons;
import std.conv;

import core.thread;
import core.sync.mutex, core.sync.condition;
import core.sys.posix.sys.stat;
import core.sys.posix.stdio : fopen;
import core.stdc.errno;

extern(C) char* mkdtemp(char* template_);
extern(C) int mkfifo(immutable(char)* fn, int mode);

string samtoolsBin     = null;  // cached path to samtools binary
string samtoolsVersion = null;
string bcftoolsBin     = null;
string bcftoolsVersion = null;

// Return path to samtools after testing whether it exists and supports mpileup
auto samtoolsInfo()
{
  if (samtoolsBin == null) {
    auto paths = environment["PATH"].split(":");
    auto a = array(filter!(path => std.file.exists(path ~ "/samtools"))(paths));
    if (a.length == 0)
      throw new Exception("failed to locate samtools executable in PATH");
    samtoolsBin = a[0] ~ "/samtools";
    // we found the path, now test the binary
    auto samtools = execute([samtoolsBin]);
    if (samtools.status != 1)
      throw new Exception("samtools failed: ", samtools.output);
    samtoolsVersion = samtools.output.split("\n")[2];
    if (samtoolsVersion.startsWith("Version: 0."))
      throw new Exception("versions 0.* of samtools/bcftools are unsupported");
  }
  return [samtoolsBin, samtoolsVersion];
}

auto samtoolsPath() { return samtoolsInfo()[0]; }

auto bcftoolsPath()
{
  if (bcftoolsBin == null) {
    auto paths = environment["PATH"].split(":");
    auto a = array(filter!(path => std.file.exists(path ~ "/bcftools"))(paths));
    if (a.length == 0)
      throw new Exception("failed to locate bcftools executable in PATH");
    bcftoolsBin = a[0] ~ "/bcftools";
    // we found the path, now test the binary
    auto bcftools = execute([bcftoolsBin]);
    if (bcftools.status != 1)
      throw new Exception("bcftools failed: ", bcftools.output);
    bcftoolsVersion = bcftools.output.split("\n")[2];
    if (bcftoolsVersion.startsWith("Version: 0."))
      throw new Exception("versions 0.* of samtools/bcftools are unsupported");
  }
  return [bcftoolsBin, bcftoolsVersion];
}

void makeFifo(string filename) {
    auto s = toStringz(filename);
    int ret = mkfifo(s, octal!"666");
    if (ret == -1) {
        stderr.writeln(errno);
        throw new Exception("failed to create named pipe " ~ filename);
    }
}

struct BedRecord {
    string reference;
    ulong start;
    ulong end;

    void toString(scope void delegate(const(char)[]) dg) const {
        dg.write(reference);
        dg.write('\t');
        dg.write(start);
        dg.write('\t');
        dg.write(end);
    }
}

struct ForkData(C) {
    MultiBamReader bam;
    TaskPool task_pool;
    C chunk;
    string filename;

    void toString(scope void delegate(const(char)[]) dg) const {
        dg.write(filename);
        dg.write('\n');
        dg.write(bam.reference_sequences[chunk.ref_id].name);
        dg.write('\n');
        dg.write(chunk.start_position);
        dg.write('\n');
        dg.write(chunk.end_position);
    }

    const(BedRecord) bed() @property const {
        return BedRecord(bam.reference_sequences[chunk.ref_id].name,
                         chunk.start_position + 1,
                         chunk.end_position);
    }
}

struct MArray(T) { T[] data; T* ptr; }

MArray!char data;

__gshared string this_app;

private {
    struct Recipe {
        string strip_header_cmd;
        string compression_cmd;
        void function (ubyte[] data, std.stdio.File output_file) decompressionFunc;
    }

    void dump(ubyte[] data, std.stdio.File output_file) {
        output_file.rawWrite(data);
    }

    void lz4decompress(ubyte[] data, std.stdio.File output_file) {
        lz4decompressor.decompress(new MemoryStream(data), output_file);
    }

    __gshared Recipe[FileFormat] recipes;
    __gshared LZ4Decompressor lz4decompressor;
}

// TODO: fix bcftoolsCommand and samtoolsCommand in the header
void init() {
    lz4decompressor = new LZ4Decompressor();

    recipes[FileFormat.pileup] =          Recipe(this_app~" strip_bcf_header --vcf",
                                                 this_app~" lz4compress",
                                                 &lz4decompress);
    recipes[FileFormat.BCF] =             Recipe(this_app~" strip_bcf_header --bcf",
                                                 null,
                                                 &dump);
    recipes[FileFormat.uncompressedBCF] = Recipe(this_app~" strip_bcf_header --ubcf",
                                                 this_app~" lz4compress",
                                                 &lz4decompress);
    recipes[FileFormat.VCF] =             Recipe(this_app~" strip_bcf_header --vcf",
                                                 this_app~" lz4compress",
                                                 &lz4decompress);
}

string makeInputCmdLine(string input_cmd, FileFormat input_format, bool strip_header) {
    auto recipe = recipes[input_format];
    string cmd = input_cmd;
    if (strip_header && recipe.strip_header_cmd !is null)
        cmd ~= "| " ~ recipe.strip_header_cmd;
    if (recipe.compression_cmd !is null)
        cmd ~= "| " ~ recipe.compression_cmd;
    return cmd;
}

void decompressIntoFile(char[] data, FileFormat input_format,
                        std.stdio.File output_file) {
    recipes[input_format].decompressionFunc(cast(ubyte[])data, output_file);
}

struct Args {
    string[] samtools_args;
    string[] bcftools_args;
    FileFormat input_format;

    this(string[] samtools_args_, string[] bcftools_args_) {
        samtools_args = unbundle(samtools_args_);
        bcftools_args = unbundle(bcftools_args_, "O"); // keep -Ov|-Ob|...
        auto samtools_output_fmt = fixSamtoolsArgs(samtools_args, !bcftools_args.empty);
        auto bcftools_output_fmt = fixBcftoolsArgs(bcftools_args);

        input_format = samtools_output_fmt;
        if (bcftools_args.length > 0)
            input_format = bcftools_output_fmt;
    }

    string makeCommandLine(string filename) {
        auto samtools_cmd = ([samtoolsPath(), "mpileup", filename,
                "-l", filename ~ ".bed"] ~ samtools_args).join(" ");
        string cmd = samtools_cmd;
        if (bcftools_args.length > 0) {
            auto bcftools_cmd = bcftoolsPath()[0] ~ " " ~ bcftools_args.join(" ");
            cmd = samtools_cmd ~ " | " ~ bcftools_cmd;
        }

        bool strip_header = !filename.endsWith("/1");
        return makeInputCmdLine(cmd, input_format, strip_header);
    }
}

MArray!char runSamtools(string filename, Args args, std.stream.File output_stream)
{
    auto cmd = args.makeCommandLine(filename);
    stderr.writeln("[executing] ", cmd);
    auto pp = pipeShell(cmd, Redirect.stdout);
    scope(exit) pp.pid.wait();

    size_t capa = 1_024_576;
    size_t used = 0;
    char* result = cast(char*)std.c.stdlib.malloc(capa);

    char[4096] buffer = void;
    while (true) {
        auto buf = pp.stdout.rawRead(buffer[]);
        if (buf.length == 0)
            break;
        if (used + buf.length > capa) {
            capa = max(capa * 2, used + buf.length);
            result = cast(char*)std.c.stdlib.realloc(cast(void*)result, capa);
        }
        result[used .. used + buf.length] = buf[];
        used += buf.length;
    }

    output_stream.close();

    auto output = result[0 .. used];
    auto arr = MArray!char(output, result);
    return arr;
}

enum FileFormat {
    pileup,
    BCF,
    uncompressedBCF,
    VCF,
    gzippedVCF
}

string[] unbundle(string[] args, string exclude="") {
    import std.ascii : isAlpha;
    import std.format : text;
    import std.algorithm : count;
    string[] unbundled;
    foreach (a; args) {
        if (a.length >= 2 && a[0] == '-' && exclude.count(a[1]) == 0) {
            string[] expanded;
            foreach (j, dchar c; a[1 .. $])
            {
                if (!isAlpha(c)) {
                    expanded ~= a[j + 1 .. $];
                    break;
                }
                expanded ~= text('-', c);
            }
            unbundled ~= expanded;
        } else {
            unbundled ~= a;
        }
    }
    return unbundled;
}

// input: unbundled samtools arguments
// output: detected output format
FileFormat fixSamtoolsArgs(ref string[] args, bool use_caller) {
    bool vcf = false;
    bool bcf = false;
    bool uncompressed = false;
    bool[] keep;
    foreach (i; 0 .. args.length) {
        if (args[i] == "-o") {
            throw new Exception("-o argument of samtools is disallowed, use --output-filename argument of sambamba mpileup");
        }
        if (args[i] == "-g") {
            bcf = true; keep ~= true;
        } else if (args[i] == "-v") {
            vcf = true; keep ~= !use_caller;
        } else if (args[i] == "-u") {
            uncompressed = true; keep ~= !use_caller;
        } else {
            keep ~= true;
        }
    }

    string[] fixed_args;
    foreach (i; 0 .. args.length) {
        if (keep[i])
            fixed_args ~= args[i];
    }

    bool fixes_applied;
    if (vcf && use_caller) {
        fixed_args ~= ["-g", "-u"];
        fixes_applied = true;
    } else if (bcf && use_caller) {
        fixed_args ~= "-u";
        fixes_applied = true;
    }

    args = fixed_args;

    if (fixes_applied && use_caller) {
        stderr.writeln("NOTE: changed samtools output format to uncompressed BCF for better performance (-gu)");
    }

    if (bcf && vcf) {
        throw new Exception("samtools can't be asked for both -g and -v");
    } else if (bcf && uncompressed) {
        return FileFormat.uncompressedBCF;
    } else if (bcf && !uncompressed) {
        return FileFormat.BCF;
    } else if (vcf && uncompressed) {
        return FileFormat.VCF;
    } else if (vcf && !uncompressed) {
        // TODO
        throw new Exception("compressed VCF is not supported, please use bgzip and uncompressed VCF");
    } else {
        return FileFormat.pileup;
    }
}

// input: unbundled bcftools arguments
// output: detected output format
FileFormat fixBcftoolsArgs(ref string[] args) {
    FileFormat fmt = FileFormat.VCF;
    bool[] keep;
    foreach (i; 0 .. args.length) {
        if (args[i] == "-o") {
            throw new Exception("-o argument of bcftools is disallowed, use --output-filename argument of sambamba mpileup");
        }
        if (args[i] == "-Ov") {
            fmt = FileFormat.VCF; keep ~= true;
        } else if (args[i] == "-Oz") {
            // TODO
            throw new Exception("compressed VCF is not supported, please use bgzip and uncompressed VCF");
            fmt = FileFormat.gzippedVCF; keep ~= false;
        } else if (args[i] == "-Ob") {
            fmt = FileFormat.BCF; keep ~= true;
        } else if (args[i] == "-Ou") {
            fmt = FileFormat.uncompressedBCF; keep ~= true;
        } else {
            keep ~= true;
        }
    }

    string[] fixed_args;
    foreach (i; 0 .. args.length) {
        if (keep[i])
            fixed_args ~= args[i];
    }

    args = fixed_args;
    return fmt;
}

class ChunkDispatcher(ChunkRange) {
    private string tmp_dir_;
    private ChunkRange chunks_;
    private MultiBamReader bam_;
    private size_t num_, curr_num_ = 1;
    private Mutex mutex_;

    Mutex dump_mutex;
    Condition dump_condition;

    alias ElementType!(Unqual!(ChunkRange)) Chunk;

    this(string tmp_dir, ChunkRange chunks, MultiBamReader bam) {
        tmp_dir_ = tmp_dir;
        chunks_ = chunks;
        bam_ = bam;
        num_ = 0;
        mutex_ = new Mutex();

        dump_mutex = new Mutex();
        dump_condition = new Condition(dump_mutex);
    }

    Nullable!(Tuple!(Chunk, string, size_t)) nextChunk() {
        mutex_.lock();
        scope(exit) mutex_.unlock();

        typeof(return) chunk;
        if (chunks_.empty)
            return chunk;
        ++num_;

        auto filename = buildPath(tmp_dir_, num_.to!string());
        chunk = tuple(chunks_.front, filename, num_);
        chunks_.popFront();

        auto ref_name = bam_.reference_sequences[chunk[0].ref_id].name;
        auto start = chunk[0].start_position + 1;
        auto end = chunk[0].end_position;

        auto bed = BedRecord(ref_name, start - 1, end);
        auto f = std.stdio.File(filename ~ ".bed", "w");
        f.writeln(bed);
        f.close();

        return chunk;
    }

    bool tryDump(size_t num, char[] data, FileFormat fmt, std.stdio.File output_file) {
        bool result;
        synchronized (dump_mutex) {
            result = num == curr_num_;
            if (result) {
                decompressIntoFile(data, fmt, output_file);
                ++curr_num_;
                dump_condition.notifyAll();
            }
        }

        return result;
    }
}

void worker(Dispatcher)(Dispatcher d,
                        MultiBamReader bam,
                        TaskPool task_pool,
                        Args args,
                        std.stdio.File output_file) {
    while (true) {
        auto result = d.nextChunk();
        if (result.isNull)
            return;

        auto chunk = result[0];
        auto filename = result[1];
        auto num = result[2];
        makeFifo(filename);

        auto writing_thread = new Thread(() {
            import core.sys.posix.fcntl : open, O_WRONLY, O_NONBLOCK;
            import core.sys.posix.unistd : close;
            int hFile = -1;
            // wait until the reader opens the FIFO
            while (hFile == -1) {
                Thread.sleep(dur!"msecs"(50));
                hFile = core.sys.posix.fcntl.open(toStringz(filename),
                                                  O_WRONLY | O_NONBLOCK,
                                                  octal!644);
                if (hFile != -1) {
                    // once it's deduced that the reader opened the FIFO,
                    // reopen the file in blocking mode
                    core.sys.posix.unistd.close(hFile);
                    hFile = core.sys.posix.fcntl.open(toStringz(filename),
                                                      O_WRONLY, octal!644);
                }
            }
            stderr.writeln("[opened FIFO for writing] ", filename);
            auto output_stream = new std.stream.File(hFile, FileMode.Out);
            auto writer = new BamWriter(output_stream, 0, task_pool);
            writer.writeSamHeader(bam.header);
            writer.writeReferenceSequenceInfo(bam.reference_sequences);
            foreach (read; chunk.reads)
                writer.writeRecord(read);
            writer.finish();
            core.sys.posix.unistd.close(hFile);
            stderr.writeln("[closed FIFO] ", filename);
            });

        auto cmd = args.makeCommandLine(filename);
        stderr.writeln("[executing] ", cmd);
        auto pp = pipeShell(cmd, Redirect.stdout);

        writing_thread.start();
        scope(exit) pp.pid.wait();

        size_t capa = 1_024_576;
        size_t used = 0;
        char* output = cast(char*)std.c.stdlib.malloc(capa);

        char[4096] buffer = void;
        while (true) {
            auto buf = pp.stdout.rawRead(buffer[]);
            if (buf.length == 0)
                break;
            if (used + buf.length > capa) {
                capa = max(capa * 2, used + buf.length);
                output = cast(char*)std.c.stdlib.realloc(cast(void*)output, capa);
            }
            output[used .. used + buf.length] = buf[];
            used += buf.length;
        }

        writing_thread.join();

        synchronized (d.dump_mutex) {
            while (!d.tryDump(num, output[0 .. used], args.input_format, output_file))
                d.dump_condition.wait();
        }
        std.c.stdlib.free(output);
    }
}

auto chunkDispatcher(ChunkRange)(string tmp_dir, ChunkRange chunks,
                                 MultiBamReader bam) {
    return new ChunkDispatcher!ChunkRange(tmp_dir, chunks, bam);
}

void printUsage() {
    stderr.writeln("usage: sambamba-pileup [options] input.bam [input2.bam [...]]");
    stderr.writeln("                       [--samtools <samtools mpileup args>]");
    stderr.writeln("                       [--bcftools <bcftools call args>]");
    stderr.writeln();
    stderr.writeln("This subcommand relies on external tools and acts as a multi-core implementation of samtools and bcftools.");
    stderr.writeln("Therefore, the following tools should be present in $PATH:");
    stderr.writeln("    * samtools");
    stderr.writeln("    * bcftools (when used)");
    stderr.writeln();
    stderr.writeln("If --samtools is skipped, samtools mpileup is called with default arguments");
    stderr.writeln("If --bcftools is used without parameters, samtools is called with");
    stderr.writeln("     switch '-gu' and bcftools is called as 'bcftools view -'");
    stderr.writeln("If --bcftools is skipped, bcftools is not called");
    stderr.writeln();
    stderr.writeln("Sambamba splits input BAM files into chunks and feeds them");
    stderr.writeln("to samtools mpileup and, optionally, bcftools in parallel.");
    stderr.writeln("The chunks are slightly overlapping so that variant calling");
    stderr.writeln("should not be impacted by these manipulations. The obtained results");
    stderr.writeln("from the multiple processes are combined as ordered output.");
    stderr.writeln();
    stderr.writeln("Sambamba options:");
//    stderr.writeln("         -F, --filter=FILTER");
//    stderr.writeln("                    set custom filter for alignments");
    stderr.writeln("         -L, --regions=FILENAME");
    stderr.writeln("                    provide BED file with regions");
    stderr.writeln("                    (no need to duplicate it in samtools args);");
    stderr.writeln("                    all input files must be indexed");
    stderr.writeln("         -o, --output-filename=<STDOUT>");
    stderr.writeln("                    specify output filename");
    stderr.writeln("         --tmpdir=TMPDIR");
    stderr.writeln("                    directory for temporary files");
    stderr.writeln("         -t, --nthreads=NTHREADS");
    stderr.writeln("                    maximum number of threads to use");
    stderr.writeln("         -b, --buffer-size=64_000_000");
    stderr.writeln("                    chunk size (in bytes)");
}

version(standalone) {
    int main(string[] args) {
       return pileup_main(args);
    }
}

string output_filename = null;

int pileup_main(string[] args) {
    this_app = args[0];
    init();

    auto bcftools_args = find(args, "--bcftools");
    auto args1 = (bcftools_args.length>0 ? args[0 .. $-bcftools_args.length] : args );
    auto samtools_args = find(args1, "--samtools");
    auto own_args = (samtools_args.length>0 ? args1[0 .. $-samtools_args.length] : args1 );

    if (!samtools_args.empty) {
        samtools_args.popFront();
    } else {
        samtools_args = [];
    }

    if (!bcftools_args.empty) {
        bcftools_args.popFront(); // remove the switch --bcftools
    }

    string bed_filename;
    //string query;
    uint n_threads = defaultPoolThreads;
    std.stdio.File output_file = stdout;
    size_t buffer_size = 64_000_000;

    string tmp_dir_prefix = defaultTmpDir();

    try {
        getopt(own_args,
               std.getopt.config.caseSensitive,
               "regions|L",         &bed_filename,
               //"filter|F",          &query,
               "output-filename|o", &output_filename,
               "tmpdir",            &tmp_dir_prefix,
               "nthreads|t",        &n_threads,
               "buffer-size|b",     &buffer_size);

        if (own_args.length < 2) {
            printUsage();
            return 0;
        }

        stderr.writeln("samtools mpileup options: ",samtools_args.join(" "));
        if (bcftools_args.length>0)
            stderr.writeln("bcftools options: ", bcftools_args.join(" "));

        if (output_filename != null) {
            foreach (filename; own_args[1 .. $])
                protectFromOverwrite(filename, output_filename);
            output_file = std.stdio.File(output_filename, "w+");
        }

        defaultPoolThreads = n_threads;
        auto bam = new MultiBamReader(own_args[1 .. $]);

        char[] buf = tmp_dir_prefix ~ "/sambamba-fork-XXXXXX\0".dup;
        mkdtemp(buf.ptr);

        string tmp_dir = to!string(buf.ptr);
        scope(exit) rmdirRecurse(tmp_dir);

        auto bundled_args = Args(samtools_args, bcftools_args);

        InputRange!BamRead reads;
        if (bed_filename is null) {
            reads = inputRangeObject(bam.reads().map!`a.read`);
        } else {
            auto regions = parseBed(bed_filename, bam);
            reads = inputRangeObject(bam.getReadsOverlapping(regions).map!`a.read`);
        }

        auto chunks = reads.pileupChunks(false, buffer_size);
        auto dispatcher = chunkDispatcher(tmp_dir, chunks, bam);

        auto threads = new ThreadGroup();

        scope (exit) {
            threads.joinAll();
            output_file.close();
        }

        foreach (i; 0 .. max(1, n_threads))
            threads.create(() { worker(dispatcher, bam, taskPool, bundled_args,
                                       output_file); });

        return 0;

    } catch (Exception e) {
        stderr.writeln("sambamba-pileup: ", e.msg);

        version(development) {
            throw e;
        }

        return 1;
    }

    return 0;
}

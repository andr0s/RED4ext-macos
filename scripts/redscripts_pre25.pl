#!/usr/bin/perl
# redscripts_pre25.pl IN OUT
#
# Writes the game's script bundle (r6/cache/final.redscripts) in the layout the redscript compiler that ships with the
# macOS game (engine/tools/scc) can read.
#
# Since patch 2.5 the game sets header flag 0x2 and puts a 7th table header after the regular 104-byte header; it
# describes an extra table with one 12-byte record per definition (redscript 0.5.32, "support script bundles from game
# patch 2.5", reads past it and does not write it). The scc bundled with the macOS game predates that and cannot read
# such a bundle. This removes the 7th table header and moves every absolute offset (the six table headers and the
# definition body offsets) back by its 12 bytes. The extra table stays where it is, unreferenced: tables and
# definition bodies are found by their offsets. The definitions table's CRC32 is recomputed.
#
# A bundle without flag 0x2 is copied unchanged. Exit 0 on success, 1 on an unexpected layout (nothing is written).
use strict;
use warnings;
use Compress::Zlib qw(crc32);

my ($in, $out) = @ARGV;
die "usage: $0 IN OUT\n" unless defined $out;

my $b = do {
    open(my $fh, '<:raw', $in) or die "cannot read $in: $!\n";
    local $/;
    <$fh>;
};
my $len = length($b);
die "$in: too short for a script bundle\n" if $len < 104;
my ($magic, $version, $flags) = unpack('V3', $b);
die "$in: not a script bundle\n" unless $magic == 0x53444552;
die "$in: unknown script bundle version $version\n" unless $version == 14;

my $result;
if (!($flags & 0x2)) {
    $result = $b;
} else {
    die "$in: truncated header\n" if $len < 116;
    my $header = substr($b, 0, 104);
    substr($header, 8, 4) = pack('V', $flags & ~0x2);
    my @tables;
    for my $i (0 .. 5) {
        my ($offset, $count, $hash) = unpack('V3', substr($header, 32 + $i * 12, 12));
        die "$in: table $i starts inside the header\n" if $offset < 116 || $offset > $len;
        substr($header, 32 + $i * 12, 4) = pack('V', $offset - 12);
        push @tables, [$offset - 12, $count];
    }
    $result = $header . substr($b, 116);

    # Definitions (table 4): 20-byte headers {name, parent, offset, size, type, 3 bytes}, body offset at +8.
    my ($defs, $count) = @{$tables[4]};
    die "$in: definitions table out of range\n" if $defs + $count * 20 > length($result);
    for my $i (0 .. $count - 1) {
        my $at = $defs + $i * 20 + 8;
        my ($offset, $size) = unpack('V2', substr($result, $at, 8));
        next if $offset == 0;
        die "$in: definition $i body out of range\n" if $offset < 116 || $offset - 12 + $size > length($result);
        substr($result, $at, 4) = pack('V', $offset - 12);
    }
    substr($result, 32 + 4 * 12 + 8, 4) = pack('V', crc32(substr($result, $defs, $count * 20)));
}

my $tmp = "$out.tmp$$";
open(my $oh, '>:raw', $tmp) or die "cannot write $tmp: $!\n";
print {$oh} $result or die "cannot write $tmp: $!\n";
close($oh) or die "cannot write $tmp: $!\n";
rename($tmp, $out) or die "cannot rename $tmp to $out: $!\n";
exit 0;

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::RecursiveCopy;
use PostgreSQL::Test::Utils;
use Test::More;
use Data::Dumper;

my $node = PostgreSQL::Test::Cluster->new('main');

# Create a data directory with initdb
$node->init;

$node->append_conf(
    'postgresql.conf', 
    q{
        wal_level = 'replica'
        archive_mode = 'on'
        archive_library = 'waldiff'
        waldiff.waldiff_dir = 'waldiff'
        shared_preload_libraries = 'waldiff'
    }
); # TODO need shared_preload_libraries only for rmgr?

# Start the PostgreSQL server
$node->start;

# Setup
$node->safe_psql('postgres', 'CREATE EXTENSION waldiff');

# Create table wich contain WALDIFFWriterState struct, because we
# need to pass it through processes
$node->safe_psql(
        'postgres', 
        "CREATE TABLE writer_state (
        id INTEGER PRIMARY KEY,

        fd INTEGER,
        segno bigint,
        tli bigint,
        dir text,
        segsize bigint,
        current_offset integer,
        last_processed_record bigint,

        system_identifier bigint,

        already_written bigint,

        first_page_addr bigint
        );"
);

# Insert initial values
$node->safe_psql(
    'postgres', 
    "INSERT INTO writer_state (id, segno, tli, system_identifier, first_page_addr, already_written) VALUES (1, 1, 1, 0, 0, 0);"
);

# Create table wich contain WALRawReaderState struct, because we
# need to pass it through processes
$node->safe_psql(
        'postgres', 
        "CREATE TABLE raw_reader_state (
        id INTEGER PRIMARY KEY,

        fd INTEGER,
        segno bigint,
        tli bigint,
        dir text,
        segsize bigint,
        current_offset integer,
        last_processed_record bigint,

        system_identifier bigint,

        buffer text,
        buffer_fullness bigint,
        buffer_capacity bigint,

        tmp_buffer text,
        tmp_buffer_fullness bigint,

        already_read bigint,

        first_page_addr bigint
        );"
);

# Insert initial values
$node->safe_psql(
    'postgres', 
    "INSERT INTO raw_reader_state (id, segno, tli, tmp_buffer_fullness, buffer_fullness, system_identifier, first_page_addr, already_read) VALUES (1, 1, 1, 0, 0, 0, 0, 0);"
);

mkdir $node->data_dir . "/waldiff";

# Create wal/wal diff file names
my $wal_file = $node->data_dir . '/pg_wal/000000010000000000000001';
my $wal_diff_file = $node->data_dir . '/waldiff/000000010000000000000001';
ok(-f -e $wal_file, "Got a wal file");

my $read_record;
my $total_read_count = 0;
my $num_records = 1;

# Read record from wal segment and write it to wal_diff
# segment $num_records times
for (my $iter = 0; $iter < $num_records; $iter++) {
    eval {
        $read_record = $node->safe_psql(
            'postgres', 
            "SELECT read_raw_xlog_rec('$wal_file');"
        );
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $node->stop('immediate');
        BAIL_OUT("Failed to execute 'read_raw_xlog_rec' ");
    };

    my $binary_string = pack('H*', substr($read_record, 2));
    my @rec = unpack( 'H*', $binary_string );
    @rec = map { $_ } @rec;

    my @new_array;
    for (my $i = 0; $i < length(@rec[0]); $i+=2) {
        push @new_array, substr(@rec[0], $i, 2);
    }

    $total_read_count += scalar @new_array;

    eval {
        $node->safe_psql(
            'postgres', 
            "SELECT write_raw_xlog_rec('$wal_diff_file', '$read_record');"
        );
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $node->stop('immediate');
        BAIL_OUT("Failed to execute 'write_raw_xlog_rec' ");
    };
}

my $size = -s $wal_diff_file;
ok($size == $total_read_count, "Read bytes == write bytes");

# Copy all read wal and all written waldiff
my ($buffer1, $buffer2);
open(my $fh1, '<:raw', $wal_file) or die "Cannot open file '$wal_file': $!";
open(my $fh2, '<:raw', $wal_diff_file) or die "Cannot open file '$wal_diff_file': $!";
my $bytes_read1 = read($fh1, $buffer1, $total_read_count);
my $bytes_read2 = read($fh2, $buffer2, $total_read_count);
close($fh1);
close($fh2);

# During writing, we chenge crc filed of XLogRecord structure, so
# every record in waldiff will have 4 bytes, different from these
# bytes in wal record
my $max_differences = (4 * $num_records);

# Try to find positions, where wal differ waldiff
my $is_equal = 1;
my $difference_count = 0;
for (my $i = 0; $i < $total_read_count; $i++) {
    if (substr($buffer1, $i, 1) ne substr($buffer2, $i, 1)) {
        $difference_count++;
    }
}
ok($difference_count <= $max_differences, "Wal diff file is equal to wal file");

# Stop the server
$node->stop('immediate');
done_testing();